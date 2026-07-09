# ABOUTME: Unit tests for Janus::HueRecorder — reconcile-driven device upserts
# ABOUTME: and change-only state events, plus the SSE stream recording path.

require_relative "../test_helper"
require "janus/store"
require "janus/event_log"
require "janus/hue_recorder"
require "json"
require "stringio"
require "time"

class HueRecorderTest < Minitest::Test
  include JanusTestHelpers

  LIGHT_UUID = "11111111-2222-3333-4444-555555555555"
  PLUG_UUID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
  LIGHT_ENTITY = "hue.light.#{LIGHT_UUID}"
  PLUG_ENTITY = "hue.light.#{PLUG_UUID}"

  # Stand-in for Janus::Hue::Client: canned lights (with queued errors) and
  # canned SSE stream IOs; each_event delegates to the real parser so the
  # stream path exercises production parsing against the injected io.
  class StubHue
    attr_reader :lights_calls, :stream_opens

    def initialize(lights: [], lights_errors: [], streams: [])
      @lights = lights
      @lights_errors = lights_errors
      @streams = streams
      @lights_calls = 0
      @stream_opens = 0
      @parser = Janus::Hue::Client.new(bridge_ip: "unused", app_key: "unused", fetcher: nil)
    end

    def lights
      @lights_calls += 1
      raise @lights_errors.shift unless @lights_errors.empty?

      @lights
    end

    def open_event_stream
      @stream_opens += 1
      raise Janus::Hue::Error, "no more canned streams" if @streams.empty?

      @streams.shift
    end

    def each_event(io:, &block)
      @parser.each_event(io: io, &block)
    end
  end

  def light(on:, id: LIGHT_UUID, name: "Porch Light", room: "Outside", kind: "light")
    { id: id, name: name, room: room, kind: kind, on: on, reachable: nil }
  end

  def with_recorder(hue, &block)
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        log = Janus::EventLog.new(store: store)
        recorder = Janus::HueRecorder.new(hue: hue, store: store, event_log: log,
                                          sleeper: ->(_seconds) {})
        block.call(recorder, store, log)
      ensure
        store.close
      end
    end
  end

  def state_events(log, entity)
    log.events_in(hours: 720, kinds: ["state"]).select { |event| event[:entity] == entity }
  end

  def test_run_once_upserts_devices_and_records_initial_state
    hue = StubHue.new(lights: [
      light(on: true),
      light(on: false, id: PLUG_UUID, name: "Fountain Outlet", room: "Patio", kind: "plug")
    ])
    with_recorder(hue) do |recorder, store, log|
      result = recorder.run_once

      assert_equal({ devices: 2, state_events: 2 }, result)
      devices = store.devices
      assert_equal [PLUG_ENTITY, LIGHT_ENTITY].sort, devices.map { |device| device[:id] }.sort
      fountain = devices.find { |device| device[:id] == PLUG_ENTITY }
      assert_equal "plug", fountain[:kind]
      assert_equal "Patio", fountain[:room]
      assert_equal "hue", fountain[:source]

      assert_equal true, log.latest_state(entity: LIGHT_ENTITY)[:on]
      assert_equal false, log.latest_state(entity: PLUG_ENTITY)[:on]
      assert_equal "hue", state_events(log, LIGHT_ENTITY).first[:source]
    end
  end

  def test_run_once_is_a_no_op_when_state_is_unchanged
    hue = StubHue.new(lights: [light(on: true)])
    with_recorder(hue) do |recorder, _store, log|
      recorder.run_once
      result = recorder.run_once

      assert_equal({ devices: 1, state_events: 0 }, result)
      assert_equal 1, state_events(log, LIGHT_ENTITY).size
    end
  end

  def test_run_once_records_a_change_in_state
    hue = StubHue.new(lights: [light(on: true)])
    with_recorder(hue) do |recorder, _store, log|
      recorder.run_once
      hue.instance_variable_set(:@lights, [light(on: false)])
      result = recorder.run_once

      assert_equal({ devices: 1, state_events: 1 }, result)
      events = state_events(log, LIGHT_ENTITY)
      assert_equal [true, false], events.map { |event| event[:payload]["on"] }
    end
  end

  def test_run_once_skips_state_for_lights_without_an_on_reading
    hue = StubHue.new(lights: [light(on: nil)])
    with_recorder(hue) do |recorder, store, log|
      result = recorder.run_once

      assert_equal({ devices: 1, state_events: 0 }, result)
      assert_equal 1, store.devices.size, "the device is still registered"
      assert_nil log.latest_state(entity: LIGHT_ENTITY)
    end
  end

  def test_run_once_retries_transient_errors_through_the_ladder
    hue = StubHue.new(lights: [light(on: true)],
                      lights_errors: [Errno::ECONNRESET.new("dropped")])
    with_recorder(hue) do |recorder, _store, log|
      result = recorder.run_once

      assert_equal({ devices: 1, state_events: 1 }, result)
      assert_equal 2, hue.lights_calls
      assert_equal true, log.latest_state(entity: LIGHT_ENTITY)[:on]
    end
  end

  def test_start_stream_records_events_from_the_sse_feed
    transcript = [
      ": hi",
      "",
      "data: " + JSON.generate([{
        "creationtime" => "2026-07-08T19:02:00Z", "type" => "update",
        "data" => [{ "id" => LIGHT_UUID, "type" => "light", "on" => { "on" => false } }]
      }]),
      "",
      "data: " + JSON.generate([{
        "creationtime" => "2026-07-08T23:14:30Z", "type" => "update",
        "data" => [{ "id" => LIGHT_UUID, "type" => "light", "on" => { "on" => true } }]
      }]),
      ""
    ].join("\n") + "\n"

    hue = StubHue.new(streams: [StringIO.new(transcript)])
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        log = Janus::EventLog.new(store: store)
        slept = Queue.new
        parked = Queue.new
        recorder = Janus::HueRecorder.new(
          hue: hue, store: store, event_log: log,
          # First backoff signals the test, then parks the stream thread so
          # the loop cannot spin while assertions run.
          sleeper: ->(seconds) { slept << seconds; parked.pop }
        )
        stderr_log = StringIO.new
        thread = recorder.start_stream(logger_io: stderr_log)
        begin
          assert_equal 1, slept.pop(timeout: 2), "reconnect backoff starts at the first rung"

          events = log.events_in(hours: 720, kinds: ["state"])
          assert_equal [false, true], events.map { |event| event[:payload]["on"] }
          assert_equal [Time.utc(2026, 7, 8, 19, 2, 0), Time.utc(2026, 7, 8, 23, 14, 30)],
                       events.map { |event| event[:observed] }
          assert_equal 1, hue.stream_opens
          assert_match(/hue stream/, stderr_log.string, "the drop is logged before reconnecting")
        ensure
          thread.kill
          thread.join
        end
      ensure
        store.close
      end
    end
  end

  def test_start_stream_deduplicates_against_previously_recorded_state
    transcript = "data: " + JSON.generate([{
      "creationtime" => "2026-07-08T19:02:00Z", "type" => "update",
      "data" => [{ "id" => LIGHT_UUID, "type" => "light", "on" => { "on" => true } }]
    }]) + "\n\n"

    hue = StubHue.new(lights: [light(on: true)], streams: [StringIO.new(transcript)])
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        log = Janus::EventLog.new(store: store)
        slept = Queue.new
        recorder = Janus::HueRecorder.new(hue: hue, store: store, event_log: log,
                                          sleeper: ->(seconds) { slept << seconds; Queue.new.pop })
        recorder.run_once # records on=true first
        thread = recorder.start_stream(logger_io: StringIO.new)
        begin
          slept.pop(timeout: 2)
          assert_equal 1, log.events_in(hours: 720, kinds: ["state"]).size,
                       "the stream must not duplicate the reconciled state"
        ensure
          thread.kill
          thread.join
        end
      ensure
        store.close
      end
    end
  end
end
