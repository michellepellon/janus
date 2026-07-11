# ABOUTME: Unit tests for Janus::ScheduleRunner — edge-triggered enforcement
# ABOUTME: with override respect, and grace-buffered adherence deviation events.

require_relative "../test_helper"
require "janus/store"
require "janus/event_log"
require "janus/schedules"
require "janus/schedule_runner"
require "janus/commander"
require "stringio"

class ScheduleRunnerTest < Minitest::Test
  include JanusTestHelpers

  ENTITY = "hue.light.a"

  # Records toggles; optionally raises to model a rejecting bridge.
  class StubCommander
    attr_reader :calls

    def initialize(error: nil)
      @calls = []
      @error = error
    end

    def toggle(entity:, on:)
      raise @error if @error

      @calls << [entity, on]
      { command_id: @calls.size, status: "pending", on: on }
    end
  end

  def with_runner(commander: StubCommander.new, grace_seconds: 300, log: StringIO.new)
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        event_log = Janus::EventLog.new(store: store)
        schedules = Janus::Schedules.new(store: store)
        runner = Janus::ScheduleRunner.new(schedules: schedules, event_log: event_log,
                                           commander: commander, logger_io: log,
                                           grace_seconds: grace_seconds)
        yield(runner, schedules, event_log, commander, log)
      ensure
        store.close
      end
    end
  end

  # A daily 19:00-23:00 schedule; 2026-07-06 is a Monday.
  def seed_schedule(schedules, on_time: "19:00", off_time: "23:00", enabled: true)
    schedules.upsert(entity: ENTITY, on_time: on_time, off_time: off_time,
                     days: Janus::Schedules::DAYS.dup, enabled: enabled)
  end

  def record_state(event_log, on, observed)
    event_log.record(observed: observed, source: "hue", entity: ENTITY,
                     kind: "state", payload: { on: on })
  end

  def local(*ymd_hm)
    Time.local(*ymd_hm)
  end

  # ---- enforcement ----

  def test_an_edge_between_checks_fires_one_command
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 18, 58))
      assert_empty commander.calls, "no edge has passed yet"
      runner.run_cycle(now: local(2026, 7, 6, 19, 3))
      assert_equal [[ENTITY, true]], commander.calls, "the 19:00 on edge fires once"
      runner.run_cycle(now: local(2026, 7, 6, 19, 8))
      assert_equal 1, commander.calls.size, "no re-fire between edges"
    end
  end

  def test_manual_override_is_respected_between_edges
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules)
      record_state(event_log, true, local(2026, 7, 6, 19, 0))
      runner.run_cycle(now: local(2026, 7, 6, 19, 30))
      # Michelle turns it off mid-window; no edge passes, so the runner
      # must not fight her.
      record_state(event_log, false, local(2026, 7, 6, 20, 0))
      runner.run_cycle(now: local(2026, 7, 6, 20, 5))
      runner.run_cycle(now: local(2026, 7, 6, 22, 55))
      assert_empty commander.calls
      # The next edge (23:00 off) finds it already off and skips.
      runner.run_cycle(now: local(2026, 7, 6, 23, 2))
      assert_empty commander.calls, "already in the target state: skip the command"
    end
  end

  def test_first_cycle_refires_the_most_recent_edge_idempotently
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules)
      # Restart mid-window: light already on -> the re-fired on edge skips.
      record_state(event_log, true, local(2026, 7, 6, 19, 0))
      runner.run_cycle(now: local(2026, 7, 6, 20, 0))
      assert_empty commander.calls
    end
  end

  def test_first_cycle_refires_the_most_recent_edge_when_state_differs
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules)
      # Restart mid-window with the light off: the on edge reasserts.
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 20, 0))
      assert_equal [[ENTITY, true]], commander.calls
    end
  end

  def test_multiple_missed_edges_converge_on_the_final_state
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 18, 0))
      # A long stall spans both the on and off edges; the device must end
      # in the final edge's state.
      runner.run_cycle(now: local(2026, 7, 6, 23, 30))
      assert_equal [ENTITY, false], commander.calls.last
    end
  end

  def test_unknown_observed_state_still_enforces_the_edge
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules)
      runner.run_cycle(now: local(2026, 7, 6, 18, 58))
      runner.run_cycle(now: local(2026, 7, 6, 19, 3))
      assert_equal [[ENTITY, true]], commander.calls,
                   "no recorded state is unknown, not \"already there\""
    end
  end

  def test_disabled_schedules_are_never_enforced
    with_runner do |runner, schedules, event_log, commander|
      seed_schedule(schedules, enabled: false)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 18, 58))
      runner.run_cycle(now: local(2026, 7, 6, 19, 3))
      assert_empty commander.calls
    end
  end

  def test_a_failing_command_logs_one_line_and_the_cycle_continues
    error = Janus::Commander::TransportError.new("bridge said no", status: 503)
    with_runner(commander: StubCommander.new(error: error)) do |runner, schedules, event_log, _, log|
      seed_schedule(schedules)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 18, 58))
      runner.run_cycle(now: local(2026, 7, 6, 19, 3))
      lines = log.string.lines.grep(/schedule/)
      assert_equal 1, lines.size
      assert_match(/bridge said no/, lines.first)
    end
  end

  # ---- adherence ----

  def test_deviation_records_one_event_after_the_grace_period
    with_runner do |runner, schedules, event_log|
      seed_schedule(schedules)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      # Expected on from 19:00 but observed off; the runner itself commands
      # via a stub, so the record never changes: a real deviation.
      runner.run_cycle(now: local(2026, 7, 6, 19, 2))
      assert_empty deviations(event_log), "inside the grace period"
      runner.run_cycle(now: local(2026, 7, 6, 19, 5))
      assert_empty deviations(event_log), "grace has not fully elapsed"
      runner.run_cycle(now: local(2026, 7, 6, 19, 8))
      events = deviations(event_log)
      assert_equal 1, events.size
      event = events.first
      assert_equal "janus", event[:source]
      assert_equal ENTITY, event[:entity]
      assert_equal true, event[:payload]["expected"]
      assert_equal false, event[:payload]["observed"]
      assert_equal local(2026, 7, 6, 19, 2).getutc.iso8601, event[:payload]["since"]
      runner.run_cycle(now: local(2026, 7, 6, 20, 0))
      assert_equal 1, deviations(event_log).size, "one event per episode"
    end
  end

  def test_realignment_ends_the_episode_silently_and_arms_the_next
    with_runner do |runner, schedules, event_log|
      seed_schedule(schedules)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 19, 2))
      runner.run_cycle(now: local(2026, 7, 6, 19, 8))
      assert_equal 1, deviations(event_log).size
      # She turns it on: states re-align; no realignment event is written.
      record_state(event_log, true, local(2026, 7, 6, 19, 10))
      runner.run_cycle(now: local(2026, 7, 6, 19, 12))
      assert_equal 1, deviations(event_log).size
      # A fresh mismatch later is a new episode with its own event.
      record_state(event_log, false, local(2026, 7, 6, 20, 0))
      runner.run_cycle(now: local(2026, 7, 6, 20, 1))
      runner.run_cycle(now: local(2026, 7, 6, 20, 7))
      assert_equal 2, deviations(event_log).size
    end
  end

  def test_a_mismatch_shorter_than_grace_records_nothing
    with_runner do |runner, schedules, event_log|
      seed_schedule(schedules)
      record_state(event_log, false, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 19, 2))
      record_state(event_log, true, local(2026, 7, 6, 19, 4))
      runner.run_cycle(now: local(2026, 7, 6, 19, 6))
      runner.run_cycle(now: local(2026, 7, 6, 19, 30))
      assert_empty deviations(event_log)
    end
  end

  def test_unknown_state_is_never_a_deviation
    with_runner do |runner, schedules, event_log|
      seed_schedule(schedules)
      runner.run_cycle(now: local(2026, 7, 6, 19, 2))
      runner.run_cycle(now: local(2026, 7, 6, 19, 30))
      assert_empty deviations(event_log), "absence of record is unknown, not off"
    end
  end

  def test_expected_off_and_observed_on_is_also_a_deviation
    with_runner do |runner, schedules, event_log|
      seed_schedule(schedules)
      record_state(event_log, true, local(2026, 7, 6, 12, 0))
      runner.run_cycle(now: local(2026, 7, 6, 14, 0))
      runner.run_cycle(now: local(2026, 7, 6, 14, 6))
      events = deviations(event_log)
      assert_equal 1, events.size
      assert_equal false, events.first[:payload]["expected"]
      assert_equal true, events.first[:payload]["observed"]
    end
  end

  private

  def deviations(event_log)
    event_log.events_in(hours: 24 * 365, kinds: ["deviation"],
                        now: local(2026, 7, 7, 0, 0).getutc)
  end
end
