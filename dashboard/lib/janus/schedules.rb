# ABOUTME: Janus::Schedules owns per-device on/off schedules (one per entity)
# ABOUTME: plus the pure local-time math for spans, enforcement edges, intervals.

require "date"
require_relative "db_time"

module Janus
  # Schedule times are LOCAL wall clock in the server's zone — "on at 19:00"
  # means 19:00 on the wall wherever the server runs, across DST changes.
  # A span may cross midnight (on 21:00, off 02:00); the day a span belongs
  # to is the day of its on_time.
  class Schedules
    include DbTime

    # Raised by upsert when input is invalid; +errors+ maps field name to a
    # human-readable message, so the API can answer 422 with field errors.
    class ValidationError < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.map { |field, message| "#{field}: #{message}" }.join("; "))
      end
    end

    # Canonical week order; days round-trip through storage in this order.
    DAYS = %w[mon tue wed thu fri sat sun].freeze
    TIME_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/

    def initialize(store:)
      @store = store
      ensure_schema
    end

    # Creates or replaces the one schedule for +entity+. Days are
    # deduplicated into canonical order. Returns the stored row; raises
    # ValidationError (never writing) when any field is invalid.
    def upsert(entity:, on_time:, off_time:, days:, enabled:)
      errors = validate(on_time: on_time, off_time: off_time, days: days, enabled: enabled)
      raise ValidationError, errors unless errors.empty?

      day_string = DAYS.select { |day| days.include?(day) }.join(",")
      now = Time.now.getutc
      @store.with_connection do |conn|
        conn.query(<<~SQL, entity, on_time, off_time, day_string, enabled, now, now)
          INSERT INTO schedules (entity, on_time, off_time, days, enabled, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (entity) DO UPDATE SET
            on_time = excluded.on_time,
            off_time = excluded.off_time,
            days = excluded.days,
            enabled = excluded.enabled,
            updated_at = excluded.updated_at
        SQL
      end
      fetch(entity)
    end

    # The schedule for one entity, or nil: { entity:, on_time:, off_time:,
    # days: [...], enabled:, created_at:, updated_at: }.
    def fetch(entity)
      @store.with_connection do |conn|
        row = conn.query("#{SELECT_SQL} WHERE entity = ?", entity).first
        row && shape(row)
      end
    end

    # Every schedule, ordered by entity.
    def all
      @store.with_connection do |conn|
        conn.query("#{SELECT_SQL} ORDER BY entity").to_a.map { |row| shape(row) }
      end
    end

    # Removes the schedule for +entity+; returns whether one existed.
    def delete(entity)
      @store.with_connection do |conn|
        conn.query("DELETE FROM schedules WHERE entity = ?", entity).rows_changed.positive?
      end
    end

    # ---- pure schedule math (local wall-clock; mirrored in dash.js) ----

    class << self
      # Whether the schedule expects the device on at +local_time+. Same-day
      # spans cover [on_time, off_time) on each scheduled day; an overnight
      # span (on_time > off_time) belongs to the day of its on_time and runs
      # into the next day's small hours.
      def expected_on?(schedule, local_time)
        return false unless schedule[:enabled]

        minutes = (local_time.hour * 60) + local_time.min
        on_min = to_minutes(schedule[:on_time])
        off_min = to_minutes(schedule[:off_time])
        today = day_included?(schedule, local_time.to_date)
        if on_min < off_min
          today && minutes >= on_min && minutes < off_min
        else
          (today && minutes >= on_min) ||
            (day_included?(schedule, local_time.to_date - 1) && minutes < off_min)
        end
      end

      # Ordered on/off edges the schedule crosses in (from_local, to_local]:
      # [{at:, on:}]. Exactly-at-from is excluded (already evaluated last
      # check); exactly-at-to is included. Disabled schedules have no edges.
      def edges_between(schedule, from_local, to_local)
        each_span(schedule, from_local, to_local).flat_map do |(span_on, span_off)|
          [{ at: span_on, on: true }, { at: span_off, on: false }]
        end.select { |edge| edge[:at] > from_local && edge[:at] <= to_local }
           .sort_by { |edge| edge[:at] }
      end

      # Expected-on intervals clipped to [from_local, to_local]:
      # ascending [{from:, to:}]. Disabled schedules expect nothing.
      def expected_intervals(schedule, from_local, to_local)
        each_span(schedule, from_local, to_local).filter_map do |(span_on, span_off)|
          from = [span_on, from_local].max
          to = [span_off, to_local].min
          { from: from, to: to } if to > from
        end.sort_by { |interval| interval[:from] }
      end

      private

      # Every (on Time, off Time) span whose day-of-on_time falls between the
      # day before from_local (an overnight span can reach into the window)
      # and the day of to_local. Local wall-clock Times via Time.local.
      def each_span(schedule, from_local, to_local)
        return [] unless schedule[:enabled]

        overnight = to_minutes(schedule[:on_time]) > to_minutes(schedule[:off_time])
        ((from_local.to_date - 1)..to_local.to_date).filter_map do |date|
          next unless day_included?(schedule, date)

          [at_local(date, schedule[:on_time]),
           at_local(overnight ? date + 1 : date, schedule[:off_time])]
        end
      end

      def day_included?(schedule, date)
        schedule[:days].include?(DAYS[(date.wday + 6) % 7])
      end

      def to_minutes(hhmm)
        (hhmm[0, 2].to_i * 60) + hhmm[3, 2].to_i
      end

      def at_local(date, hhmm)
        Time.local(date.year, date.month, date.day, hhmm[0, 2].to_i, hhmm[3, 2].to_i)
      end
    end

    SELECT_SQL = "SELECT entity, on_time, off_time, days, enabled, created_at, updated_at FROM schedules"

    private

    def validate(on_time:, off_time:, days:, enabled:)
      errors = {}
      errors["on_time"] = "must be HH:MM (24-hour)" unless on_time.is_a?(String) && on_time.match?(TIME_FORMAT)
      errors["off_time"] = "must be HH:MM (24-hour)" unless off_time.is_a?(String) && off_time.match?(TIME_FORMAT)
      if !days.is_a?(Array) || days.empty? || days.any? { |day| !DAYS.include?(day) }
        errors["days"] = "must be a non-empty subset of #{DAYS.join(", ")}"
      end
      errors["enabled"] = "must be true or false" unless enabled == true || enabled == false
      if !errors.key?("off_time") && !errors.key?("on_time") && on_time == off_time
        errors["off_time"] = "must differ from on_time"
      end
      errors
    end

    def shape(row)
      {
        entity: row[0], on_time: row[1], off_time: row[2],
        days: row[3].split(","), enabled: row[4],
        created_at: as_utc(row[5]), updated_at: as_utc(row[6])
      }
    end

    def ensure_schema
      @store.with_connection do |conn|
        conn.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS schedules (
            entity TEXT PRIMARY KEY,
            on_time TEXT NOT NULL,
            off_time TEXT NOT NULL,
            days TEXT NOT NULL,
            enabled BOOLEAN NOT NULL,
            created_at TIMESTAMP,
            updated_at TIMESTAMP
          )
        SQL
      end
    end
  end
end
