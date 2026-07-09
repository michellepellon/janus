# ABOUTME: Janus::EventLog owns the append-only events journal and the command
# ABOUTME: ledger inside the store's DuckDB file, plus windowed state queries.

require "json"
require "time"
require_relative "db_time"

module Janus
  class EventLog
    include DbTime

    # The only terminal states a command can resolve to.
    RESOLVED_STATUSES = %w[confirmed failed].freeze

    def initialize(store:)
      @store = store
      ensure_schema
    end

    # Appends one observation to the journal. Events are never updated or
    # deleted — corrections are recorded as later events; no method on this
    # class mutates a written row.
    def record(observed:, source:, entity:, kind:, payload: {})
      @store.with_connection do |conn|
        conn.query(<<~SQL, normalize_time(observed), source, entity, kind, JSON.generate(payload))
          INSERT INTO events (observed, source, entity, kind, payload)
          VALUES (?, ?, ?, ?, ?)
        SQL
      end
      nil
    end

    # Opens a command in the ledger (status 'pending') and returns its id.
    def request(entity:, action:, source:, requested_at: Time.now.getutc)
      @store.with_connection do |conn|
        row = conn.query(<<~SQL, entity, JSON.generate(action), source, normalize_time(requested_at)).first
          INSERT INTO commands (entity, action, source, requested_at)
          VALUES (?, ?, ?, ?)
          RETURNING id
        SQL
        row.first
      end
    end

    # Closes a command as confirmed or failed, stamping resolved_at.
    def resolve(id, status:, detail: nil)
      unless RESOLVED_STATUSES.include?(status)
        raise ArgumentError, "status must be one of #{RESOLVED_STATUSES.join(", ")}"
      end

      @store.with_connection do |conn|
        conn.query(<<~SQL, status, Time.now.getutc, detail, id)
          UPDATE commands SET status = ?, resolved_at = ?, detail = ? WHERE id = ?
        SQL
      end
      nil
    end

    # The most recent recorded on/off state for one entity: {on:, observed:},
    # or nil when no state event carries a payload.on boolean.
    def latest_state(entity:)
      @store.with_connection do |conn|
        row = conn.query(<<~SQL, entity).first
          SELECT observed, CAST(payload->>'$.on' AS BOOLEAN)
          FROM events
          WHERE kind = 'state' AND entity = ?
            AND json_extract(payload, '$.on') IS NOT NULL
          ORDER BY observed DESC, id DESC
          LIMIT 1
        SQL
        return nil if row.nil?

        { observed: as_utc(row[0]), on: row[1] }
      end
    end

    # Per-entity on/off intervals over the trailing +hours+ ending at +now+,
    # derived from kind='state' events carrying a payload.on boolean:
    # { entity => ascending [{from:, to:, on:}] }. A state persisting from
    # before the window is clipped to the window start; the interval holding
    # at +now+ closes at now. Entities with no state events are absent —
    # absence of events is unknown, never "off".
    def state_intervals(entity_prefix:, hours:, now: Time.now.getutc)
      now = now.getutc
      window_start = now - (hours * 3600)
      pattern = "#{entity_prefix}%"

      @store.with_connection do |conn|
        # State carried into the window: the latest event at or before its start.
        carried = conn.query(<<~SQL, pattern, normalize_time(window_start)).to_a
          SELECT entity, state_on FROM (
            SELECT entity, CAST(payload->>'$.on' AS BOOLEAN) AS state_on,
                   row_number() OVER (PARTITION BY entity ORDER BY observed DESC, id DESC) AS rn
            FROM events
            WHERE kind = 'state' AND entity LIKE ?
              AND json_extract(payload, '$.on') IS NOT NULL
              AND observed <= ?
          ) WHERE rn = 1
        SQL
        rows = conn.query(<<~SQL, pattern, normalize_time(window_start), normalize_time(now)).to_a
          SELECT entity, observed, CAST(payload->>'$.on' AS BOOLEAN)
          FROM events
          WHERE kind = 'state' AND entity LIKE ?
            AND json_extract(payload, '$.on') IS NOT NULL
            AND observed > ? AND observed <= ?
          ORDER BY entity, observed, id
        SQL
        build_intervals(carried, rows, window_start, now)
      end
    end

    # Events observed in the trailing +hours+ ending at +now+, ascending, with
    # parsed payloads; +kinds+ narrows to the given kind names.
    def events_in(hours:, kinds: nil, now: Time.now.getutc)
      now = now.getutc
      window_start = now - (hours * 3600)
      sql = <<~SQL
        SELECT id, observed, source, entity, kind, CAST(payload AS VARCHAR)
        FROM events
        WHERE observed > ? AND observed <= ?
      SQL
      params = [normalize_time(window_start), normalize_time(now)]
      if kinds
        sql += "  AND kind IN (#{(["?"] * kinds.size).join(", ")})\n"
        params.concat(kinds)
      end
      sql += "ORDER BY observed, id"

      @store.with_connection do |conn|
        conn.query(sql, *params).to_a.map do |(id, observed, source, entity, kind, payload)|
          {
            id: id, observed: as_utc(observed), source: source,
            entity: entity, kind: kind, payload: JSON.parse(payload)
          }
        end
      end
    end

    private

    # Folds per-entity (time, on) change points into closed intervals.
    # Consecutive events with the same state extend the open interval, so the
    # journal tolerates re-recorded states without producing zero-information
    # boundaries.
    def build_intervals(carried, rows, window_start, now)
      changes = Hash.new { |hash, key| hash[key] = [] }
      carried.each { |(entity, on)| changes[entity] << [window_start, on] }
      rows.each { |(entity, observed, on)| changes[entity] << [as_utc(observed), on] }

      changes.transform_values do |points|
        intervals = []
        points.each do |(at, on)|
          next if intervals.any? && intervals.last[:on] == on

          intervals.last[:to] = at if intervals.any?
          intervals << { from: at, to: nil, on: on }
        end
        intervals.last[:to] = now
        intervals
      end
    end

    def ensure_schema
      @store.with_connection do |conn|
        conn.query("CREATE SEQUENCE IF NOT EXISTS events_id_seq")
        conn.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS events (
            id BIGINT DEFAULT nextval('events_id_seq'),
            observed TIMESTAMP NOT NULL,
            source TEXT NOT NULL,
            entity TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload JSON
          )
        SQL
        conn.query("CREATE SEQUENCE IF NOT EXISTS commands_id_seq")
        conn.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS commands (
            id BIGINT DEFAULT nextval('commands_id_seq'),
            entity TEXT,
            action JSON,
            source TEXT,
            requested_at TIMESTAMP,
            status TEXT DEFAULT 'pending',
            resolved_at TIMESTAMP,
            detail TEXT
          )
        SQL
      end
    end
  end
end
