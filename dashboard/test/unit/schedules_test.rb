# ABOUTME: Unit tests for Janus::Schedules — CRUD with validation over the
# ABOUTME: store, and the pure local-time schedule math (spans, edges, intervals).

require_relative "../test_helper"
require "janus/store"
require "janus/schedules"

class SchedulesTest < Minitest::Test
  include JanusTestHelpers

  # 2026-07-06 is a Monday; the table tests below lean on that.
  MONDAY = [2026, 7, 6].freeze

  def with_schedules(&block)
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        block.call(Janus::Schedules.new(store: store))
      ensure
        store.close
      end
    end
  end

  def sched(on_time: "19:00", off_time: "23:00", days: %w[mon tue wed thu fri sat sun], enabled: true)
    { on_time: on_time, off_time: off_time, days: days, enabled: enabled }
  end

  def local(*ymd_hm)
    Time.local(*ymd_hm)
  end

  # ---- CRUD ----

  def test_upsert_and_fetch_round_trip
    with_schedules do |schedules|
      row = schedules.upsert(entity: "hue.light.a", on_time: "19:00", off_time: "23:00",
                             days: %w[mon wed fri], enabled: true)
      assert_equal "hue.light.a", row[:entity]
      assert_equal "19:00", row[:on_time]
      assert_equal "23:00", row[:off_time]
      assert_equal %w[mon wed fri], row[:days]
      assert_equal true, row[:enabled]
      refute_nil row[:created_at]
      refute_nil row[:updated_at]

      fetched = schedules.fetch("hue.light.a")
      assert_equal row[:on_time], fetched[:on_time]
      assert_equal row[:days], fetched[:days]
    end
  end

  def test_fetch_returns_nil_for_unknown_entity
    with_schedules do |schedules|
      assert_nil schedules.fetch("hue.light.none")
    end
  end

  def test_upsert_updates_in_place_and_preserves_created_at
    with_schedules do |schedules|
      first = schedules.upsert(entity: "hue.light.a", **sched)
      updated = schedules.upsert(entity: "hue.light.a", **sched(on_time: "20:00", enabled: false))
      assert_equal "20:00", updated[:on_time]
      assert_equal false, updated[:enabled]
      assert_equal first[:created_at], updated[:created_at]
      assert_equal 1, schedules.all.size
    end
  end

  def test_all_is_ordered_by_entity
    with_schedules do |schedules|
      schedules.upsert(entity: "hue.light.b", **sched)
      schedules.upsert(entity: "hue.light.a", **sched)
      assert_equal %w[hue.light.a hue.light.b], schedules.all.map { |row| row[:entity] }
    end
  end

  def test_delete_removes_and_reports
    with_schedules do |schedules|
      schedules.upsert(entity: "hue.light.a", **sched)
      assert_equal true, schedules.delete("hue.light.a")
      assert_nil schedules.fetch("hue.light.a")
      assert_equal false, schedules.delete("hue.light.a")
    end
  end

  def test_days_are_deduplicated_into_canonical_order
    with_schedules do |schedules|
      row = schedules.upsert(entity: "hue.light.a", **sched(days: %w[fri mon fri sun]))
      assert_equal %w[mon fri sun], row[:days]
    end
  end

  # ---- validation ----

  def test_upsert_rejects_bad_times
    with_schedules do |schedules|
      ["9:00", "24:00", "19:60", "aa:bb", "", nil, "19:00:00"].each do |bad|
        error = assert_raises(Janus::Schedules::ValidationError, "on_time #{bad.inspect}") do
          schedules.upsert(entity: "hue.light.a", **sched(on_time: bad))
        end
        assert_kind_of String, error.errors["on_time"]

        error = assert_raises(Janus::Schedules::ValidationError, "off_time #{bad.inspect}") do
          schedules.upsert(entity: "hue.light.a", **sched(off_time: bad))
        end
        assert_kind_of String, error.errors["off_time"]
      end
      assert_empty schedules.all
    end
  end

  def test_upsert_rejects_bad_days
    with_schedules do |schedules|
      [[], nil, %w[mon funday], %w[Monday], "mon"].each do |bad|
        error = assert_raises(Janus::Schedules::ValidationError, "days #{bad.inspect}") do
          schedules.upsert(entity: "hue.light.a", **sched(days: bad))
        end
        assert_kind_of String, error.errors["days"]
      end
    end
  end

  def test_upsert_rejects_equal_on_and_off_times
    with_schedules do |schedules|
      error = assert_raises(Janus::Schedules::ValidationError) do
        schedules.upsert(entity: "hue.light.a", **sched(on_time: "19:00", off_time: "19:00"))
      end
      assert_kind_of String, error.errors["off_time"]
    end
  end

  def test_upsert_rejects_non_boolean_enabled
    with_schedules do |schedules|
      ["yes", nil, 1].each do |bad|
        error = assert_raises(Janus::Schedules::ValidationError, "enabled #{bad.inspect}") do
          schedules.upsert(entity: "hue.light.a", **sched(enabled: bad))
        end
        assert_kind_of String, error.errors["enabled"]
      end
    end
  end

  def test_validation_error_carries_every_failing_field
    with_schedules do |schedules|
      error = assert_raises(Janus::Schedules::ValidationError) do
        schedules.upsert(entity: "hue.light.a", on_time: "x", off_time: "y", days: [], enabled: nil)
      end
      assert_equal %w[days enabled off_time on_time], error.errors.keys.sort
    end
  end

  # ---- expected_on? (table-driven) ----

  def test_expected_on_same_day_span
    schedule = sched(on_time: "19:00", off_time: "23:00", days: %w[mon])
    [
      [[*MONDAY, 18, 59], false, "before on_time"],
      [[*MONDAY, 19, 0], true, "at on_time (inclusive)"],
      [[*MONDAY, 21, 30], true, "inside the span"],
      [[*MONDAY, 23, 0], false, "at off_time (exclusive)"],
      [[*MONDAY, 23, 30], false, "after off_time"],
      [[2026, 7, 7, 21, 30], false, "day not included (Tuesday)"],
    ].each do |(hm, want, why)|
      assert_equal want, Janus::Schedules.expected_on?(schedule, local(*hm)), why
    end
  end

  def test_expected_on_overnight_span
    # Monday 21:00 -> Tuesday 02:00; only Monday is in days, so the span
    # belongs to Monday even after midnight.
    schedule = sched(on_time: "21:00", off_time: "02:00", days: %w[mon])
    [
      [[*MONDAY, 20, 59], false, "Monday before on_time"],
      [[*MONDAY, 21, 0], true, "Monday at on_time"],
      [[*MONDAY, 23, 59], true, "Monday late evening"],
      [[2026, 7, 7, 1, 59], true, "Tuesday small hours belong to Monday's span"],
      [[2026, 7, 7, 2, 0], false, "Tuesday at off_time (exclusive)"],
      [[2026, 7, 7, 21, 30], false, "Tuesday evening: Tuesday not in days"],
      [[*MONDAY, 1, 30], false, "Monday small hours: Sunday not in days"],
    ].each do |(hm, want, why)|
      assert_equal want, Janus::Schedules.expected_on?(schedule, local(*hm)), why
    end
  end

  def test_expected_on_is_false_when_disabled
    schedule = sched(days: %w[mon], enabled: false)
    refute Janus::Schedules.expected_on?(schedule, local(*MONDAY, 21, 0))
  end

  # ---- edges_between ----

  def test_edges_between_returns_the_on_edge_in_range
    schedule = sched(days: %w[mon])
    edges = Janus::Schedules.edges_between(schedule, local(*MONDAY, 18, 0), local(*MONDAY, 20, 0))
    assert_equal [{ at: local(*MONDAY, 19, 0), on: true }], edges
  end

  def test_edges_between_excludes_from_and_includes_to
    schedule = sched(days: %w[mon])
    edges = Janus::Schedules.edges_between(schedule, local(*MONDAY, 19, 0), local(*MONDAY, 23, 0))
    assert_equal [{ at: local(*MONDAY, 23, 0), on: false }], edges,
                 "an edge exactly at from is excluded; exactly at to is included"
  end

  def test_edges_between_spans_multiple_days_in_order
    schedule = sched(days: %w[mon tue])
    edges = Janus::Schedules.edges_between(schedule, local(*MONDAY, 12, 0), local(2026, 7, 8, 12, 0))
    assert_equal [
      { at: local(*MONDAY, 19, 0), on: true },
      { at: local(*MONDAY, 23, 0), on: false },
      { at: local(2026, 7, 7, 19, 0), on: true },
      { at: local(2026, 7, 7, 23, 0), on: false },
    ], edges
  end

  def test_edges_between_overnight_off_edge_falls_on_the_next_day
    schedule = sched(on_time: "21:00", off_time: "02:00", days: %w[mon])
    edges = Janus::Schedules.edges_between(schedule, local(*MONDAY, 20, 0), local(2026, 7, 7, 3, 0))
    assert_equal [
      { at: local(*MONDAY, 21, 0), on: true },
      { at: local(2026, 7, 7, 2, 0), on: false },
    ], edges
  end

  def test_edges_between_skips_days_not_in_the_schedule_and_disabled
    schedule = sched(days: %w[tue])
    assert_empty Janus::Schedules.edges_between(schedule, local(*MONDAY, 0, 0), local(*MONDAY, 23, 59))
    off = sched(days: %w[mon], enabled: false)
    assert_empty Janus::Schedules.edges_between(off, local(*MONDAY, 0, 0), local(*MONDAY, 23, 59))
  end

  # ---- expected_intervals ----

  def test_expected_intervals_clips_to_the_window
    schedule = sched(days: %w[mon])
    intervals = Janus::Schedules.expected_intervals(schedule, local(*MONDAY, 20, 0), local(*MONDAY, 22, 0))
    assert_equal [{ from: local(*MONDAY, 20, 0), to: local(*MONDAY, 22, 0) }], intervals
  end

  def test_expected_intervals_covers_multiple_days
    schedule = sched(days: %w[mon tue])
    intervals = Janus::Schedules.expected_intervals(schedule, local(*MONDAY, 0, 0), local(2026, 7, 8, 0, 0))
    assert_equal [
      { from: local(*MONDAY, 19, 0), to: local(*MONDAY, 23, 0) },
      { from: local(2026, 7, 7, 19, 0), to: local(2026, 7, 7, 23, 0) },
    ], intervals
  end

  def test_expected_intervals_overnight_span_reaches_into_the_window
    # Window opens Tuesday 01:00; Monday's overnight span is still on.
    schedule = sched(on_time: "21:00", off_time: "02:00", days: %w[mon])
    intervals = Janus::Schedules.expected_intervals(schedule, local(2026, 7, 7, 1, 0), local(2026, 7, 7, 12, 0))
    assert_equal [{ from: local(2026, 7, 7, 1, 0), to: local(2026, 7, 7, 2, 0) }], intervals
  end

  def test_expected_intervals_empty_when_disabled_or_outside_days
    disabled = sched(days: %w[mon], enabled: false)
    assert_empty Janus::Schedules.expected_intervals(disabled, local(*MONDAY, 0, 0), local(2026, 7, 7, 0, 0))
    tuesday_only = sched(days: %w[tue])
    assert_empty Janus::Schedules.expected_intervals(tuesday_only, local(*MONDAY, 0, 0), local(*MONDAY, 23, 0))
  end

  # DST note: times are local wall clock, so on a spring-forward day a span
  # simply follows the clock (the skipped hour never exists on the wall).
  # 2026-03-08 is the US spring-forward Sunday; whatever the server zone,
  # the intervals must stay well-ordered.
  def test_expected_intervals_stay_ordered_across_a_dst_boundary
    schedule = sched(on_time: "21:00", off_time: "02:00", days: %w[sat sun])
    intervals = Janus::Schedules.expected_intervals(
      schedule, local(2026, 3, 7, 12, 0), local(2026, 3, 9, 12, 0)
    )
    refute_empty intervals
    intervals.each { |iv| assert_operator iv[:from], :<, iv[:to] }
    assert_equal intervals.map { |iv| iv[:from] }.sort, intervals.map { |iv| iv[:from] }
  end
end
