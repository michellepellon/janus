# ABOUTME: Unit tests for Janus::EventLog — append-only journal, command
# ABOUTME: ledger, and the windowed state-interval and event queries.

require_relative "../test_helper"
require "janus/store"
require "janus/event_log"
require "time"

class EventLogTest < Minitest::Test
  include JanusTestHelpers

  NOW = Time.utc(2026, 7, 8, 12, 0, 0)

  def with_log(&block)
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        block.call(Janus::EventLog.new(store: store), store)
      ensure
        store.close
      end
    end
  end

  def record_state(log, entity, on, observed)
    log.record(observed: observed, source: "hue", entity: entity, kind: "state",
               payload: { on: on })
  end

  def test_record_appends_and_events_in_returns_parsed_ascending_events
    with_log do |log|
      log.record(observed: NOW - 120, source: "janus", entity: "sensorpush",
                 kind: "collection", payload: { sensors: 3, readings: 12 })
      log.record(observed: NOW - 60, source: "hue", entity: "hue.light.abc",
                 kind: "state", payload: { on: true })

      events = log.events_in(hours: 24, now: NOW)
      assert_equal 2, events.size
      first, second = events
      assert_operator first[:id], :<, second[:id]
      assert_equal NOW - 120, first[:observed]
      assert_predicate first[:observed], :utc?
      assert_equal "janus", first[:source]
      assert_equal "sensorpush", first[:entity]
      assert_equal "collection", first[:kind]
      assert_equal({ "sensors" => 3, "readings" => 12 }, first[:payload])
      assert_equal({ "on" => true }, second[:payload])
    end
  end

  def test_events_in_filters_by_kinds_and_window
    with_log do |log|
      log.record(observed: NOW - (25 * 3600), source: "hue", entity: "hue.light.a",
                 kind: "state", payload: { on: true })
      log.record(observed: NOW - 60, source: "hue", entity: "hue.light.a",
                 kind: "state", payload: { on: false })
      log.record(observed: NOW - 30, source: "janus", entity: "hue",
                 kind: "collection", payload: { devices: 1 })

      assert_equal 2, log.events_in(hours: 24, now: NOW).size
      states = log.events_in(hours: 24, kinds: ["state"], now: NOW)
      assert_equal 1, states.size
      assert_equal "state", states.first[:kind]
    end
  end

  def test_event_log_exposes_no_update_or_delete_for_events
    with_log do |log|
      mutators = log.public_methods(false).grep(/update|delete|destroy|truncate/)
      assert_empty mutators, "events must be append-only"
    end
  end

  def test_command_request_and_resolve_round_trip
    with_log do |log, store|
      id = log.request(entity: "hue.light.abc", action: { on: { on: true } },
                       source: "dashboard", requested_at: NOW)
      assert_kind_of Integer, id

      row = store.with_connection do |conn|
        conn.query("SELECT entity, CAST(action AS VARCHAR), source, status, resolved_at FROM commands WHERE id = ?", id).first
      end
      assert_equal "hue.light.abc", row[0]
      assert_equal({ "on" => { "on" => true } }, JSON.parse(row[1]))
      assert_equal "dashboard", row[2]
      assert_equal "pending", row[3]
      assert_nil row[4]

      log.resolve(id, status: "confirmed", detail: "acked")
      status, resolved_at, detail = store.with_connection do |conn|
        conn.query("SELECT status, resolved_at, detail FROM commands WHERE id = ?", id).first
      end
      assert_equal "confirmed", status
      refute_nil resolved_at
      assert_equal "acked", detail
    end
  end

  def test_resolve_rejects_unknown_status
    with_log do |log|
      id = log.request(entity: "hue.light.abc", action: {}, source: "dashboard")
      assert_raises(ArgumentError) { log.resolve(id, status: "maybe") }
    end
  end

  def test_state_intervals_empty_without_state_events
    with_log do |log|
      log.record(observed: NOW - 60, source: "janus", entity: "hue",
                 kind: "collection", payload: { devices: 0 })
      assert_equal({}, log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW))
    end
  end

  def test_state_intervals_unclosed_interval_closes_at_now
    with_log do |log|
      record_state(log, "hue.light.a", true, NOW - 3600)

      intervals = log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW)
      assert_equal(
        { "hue.light.a" => [{ from: NOW - 3600, to: NOW, on: true }] },
        intervals
      )
    end
  end

  def test_state_intervals_alternating_states_produce_closed_intervals
    with_log do |log|
      record_state(log, "hue.light.a", true, NOW - 7200)
      record_state(log, "hue.light.a", false, NOW - 3600)
      record_state(log, "hue.light.a", true, NOW - 600)

      intervals = log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW)
      assert_equal [
        { from: NOW - 7200, to: NOW - 3600, on: true },
        { from: NOW - 3600, to: NOW - 600, on: false },
        { from: NOW - 600, to: NOW, on: true }
      ], intervals.fetch("hue.light.a")
    end
  end

  def test_state_intervals_clips_carried_in_state_to_window_start
    with_log do |log|
      record_state(log, "hue.light.a", true, NOW - (30 * 3600)) # before window
      record_state(log, "hue.light.a", false, NOW - 3600)

      intervals = log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW)
      assert_equal [
        { from: NOW - (24 * 3600), to: NOW - 3600, on: true },
        { from: NOW - 3600, to: NOW, on: false }
      ], intervals.fetch("hue.light.a")
    end
  end

  def test_state_intervals_merges_repeated_identical_states
    with_log do |log|
      record_state(log, "hue.light.a", true, NOW - 7200)
      record_state(log, "hue.light.a", true, NOW - 3600) # re-recorded, no change
      record_state(log, "hue.light.a", false, NOW - 600)

      intervals = log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW)
      assert_equal [
        { from: NOW - 7200, to: NOW - 600, on: true },
        { from: NOW - 600, to: NOW, on: false }
      ], intervals.fetch("hue.light.a")
    end
  end

  def test_state_intervals_separates_entities_and_honors_prefix
    with_log do |log|
      record_state(log, "hue.light.a", true, NOW - 3600)
      record_state(log, "hue.light.b", false, NOW - 1800)
      record_state(log, "other.thing", true, NOW - 900)

      intervals = log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW)
      assert_equal %w[hue.light.a hue.light.b], intervals.keys.sort
      assert_equal [{ from: NOW - 1800, to: NOW, on: false }], intervals["hue.light.b"]
    end
  end

  def test_state_intervals_ignores_state_events_without_payload_on
    with_log do |log|
      log.record(observed: NOW - 3600, source: "hue", entity: "hue.light.a",
                 kind: "state", payload: { brightness: 40 })
      assert_equal({}, log.state_intervals(entity_prefix: "hue.", hours: 24, now: NOW))
    end
  end

  def test_latest_state_returns_most_recent_on_state_or_nil
    with_log do |log|
      assert_nil log.latest_state(entity: "hue.light.a")

      record_state(log, "hue.light.a", true, NOW - 7200)
      record_state(log, "hue.light.a", false, NOW - 600)
      latest = log.latest_state(entity: "hue.light.a")
      assert_equal false, latest[:on]
      assert_equal NOW - 600, latest[:observed]
      assert_predicate latest[:observed], :utc?
    end
  end

  def test_schema_is_idempotent_across_reopens
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      log = Janus::EventLog.new(store: store)
      record_state(log, "hue.light.a", true, NOW - 60)
      store.close

      reopened = Janus::Store.new(path: path)
      relog = Janus::EventLog.new(store: reopened)
      assert_equal 1, relog.events_in(hours: 24, now: NOW).size
      # The sequence must survive the reopen without recycling ids.
      record_state(relog, "hue.light.a", false, NOW - 30)
      ids = relog.events_in(hours: 24, now: NOW).map { |event| event[:id] }
      assert_equal ids.uniq, ids
      reopened.close
    end
  end
end
