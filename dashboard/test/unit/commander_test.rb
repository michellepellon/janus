# ABOUTME: Unit tests for Janus::Commander — the toggle command path (pending on
# ABOUTME: transport success, failed on error, guards) and the confirmation reconcile.

require_relative "../test_helper"
require "janus/store"
require "janus/event_log"
require "janus/hue"
require "janus/commander"
require "time"

class CommanderTest < Minitest::Test
  include JanusTestHelpers

  NOW = Time.utc(2026, 7, 8, 12, 0, 0)
  LIGHT_UUID = "11111111-2222-3333-4444-555555555555"
  LIGHT_ENTITY = "hue.light.#{LIGHT_UUID}"

  # Stand-in for Janus::Hue::Client#set_light: records (id, on) calls and can be
  # primed to raise a Hue::Error, mirroring a bridge that rejects the PUT.
  class StubHue
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def set_light(id, on:)
      @calls << [id, on]
      raise @error if @error

      nil
    end
  end

  def with_commander(hue: StubHue.new, source: "dashboard")
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        log = Janus::EventLog.new(store: store)
        block_given? ? yield(Janus::Commander.new(hue: hue, event_log: log, source: source), log, hue) : nil
      ensure
        store.close
      end
    end
  end

  def record_state(log, entity, on, observed)
    log.record(observed: observed, source: "hue", entity: entity, kind: "state", payload: { on: on })
  end

  def test_toggle_leaves_the_command_pending_on_transport_success
    with_commander do |commander, log, hue|
      result = commander.toggle(entity: LIGHT_ENTITY, on: true)

      assert_equal [[LIGHT_UUID, true]], hue.calls, "the bare uuid is sent to the bridge"
      assert_equal "pending", result[:status]
      assert_equal true, result[:on]
      cmd = log.command(result[:command_id])
      assert_equal "pending", cmd[:status], "a 2xx PUT is accepted, not confirmed"
      assert_equal LIGHT_ENTITY, cmd[:entity]
      assert_equal true, cmd[:on]
      assert_match(/accepted/, cmd[:detail])
      assert_nil cmd[:resolved_at]
    end
  end

  def test_toggle_resolves_failed_and_raises_on_a_bridge_error
    hue = StubHue.new(error: Janus::Hue::Error.new("no such light", status: 502))
    with_commander(hue: hue) do |commander, log, _hue|
      error = assert_raises(Janus::Commander::TransportError) do
        commander.toggle(entity: LIGHT_ENTITY, on: false)
      end
      assert_equal 502, error.status
      refute_nil error.command_id

      cmd = log.command(error.command_id)
      assert_equal "failed", cmd[:status]
      assert_match(/no such light/, cmd[:detail])
    end
  end

  def test_toggle_raises_not_configured_without_recording_when_hue_is_absent
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        log = Janus::EventLog.new(store: store)
        commander = Janus::Commander.new(hue: nil, event_log: log)
        assert_raises(Janus::Commander::NotConfigured) do
          commander.toggle(entity: LIGHT_ENTITY, on: true)
        end
        assert_empty log.pending_commands, "no ledger entry for an unconfigured toggle"
      ensure
        store.close
      end
    end
  end

  def test_toggle_raises_unknown_entity_without_recording
    with_commander do |commander, log, hue|
      assert_raises(Janus::Commander::UnknownEntity) do
        commander.toggle(entity: "nws.KEFD", on: true)
      end
      assert_empty hue.calls
      assert_empty log.pending_commands
    end
  end

  def test_reconcile_confirms_a_pending_command_with_a_matching_state_event
    with_commander do |commander, log, _hue|
      id = log.request(entity: LIGHT_ENTITY, action: { on: true },
                       source: "dashboard", requested_at: NOW - 10)
      record_state(log, LIGHT_ENTITY, true, NOW - 5)

      result = commander.reconcile_pending(now: NOW, timeout_seconds: 30)
      assert_equal({ confirmed: 1, failed: 0 }, result)
      assert_equal "confirmed", log.command(id)[:status]
      assert_empty log.pending_commands
    end
  end

  def test_reconcile_fails_a_pending_command_past_the_timeout_without_confirmation
    with_commander do |commander, log, _hue|
      id = log.request(entity: LIGHT_ENTITY, action: { on: true },
                       source: "dashboard", requested_at: NOW - 45)

      result = commander.reconcile_pending(now: NOW, timeout_seconds: 30)
      assert_equal({ confirmed: 0, failed: 1 }, result)
      cmd = log.command(id)
      assert_equal "failed", cmd[:status]
      assert_match(/no confirmation/, cmd[:detail])
    end
  end

  def test_reconcile_leaves_a_recent_unconfirmed_command_pending
    with_commander do |commander, log, _hue|
      id = log.request(entity: LIGHT_ENTITY, action: { on: true },
                       source: "dashboard", requested_at: NOW - 5)

      result = commander.reconcile_pending(now: NOW, timeout_seconds: 30)
      assert_equal({ confirmed: 0, failed: 0 }, result)
      assert_equal "pending", log.command(id)[:status]
    end
  end

  def test_reconcile_does_not_confirm_from_a_stale_state_that_predates_the_request
    with_commander do |commander, log, _hue|
      record_state(log, LIGHT_ENTITY, true, NOW - 3600) # the light was already on
      id = log.request(entity: LIGHT_ENTITY, action: { on: true },
                       source: "dashboard", requested_at: NOW - 45)

      result = commander.reconcile_pending(now: NOW, timeout_seconds: 30)
      assert_equal({ confirmed: 0, failed: 1 }, result)
      assert_equal "failed", log.command(id)[:status]
    end
  end
end
