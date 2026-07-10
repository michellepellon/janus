# ABOUTME: Rack-test integration tests for Janus::App — health check and the
# ABOUTME: /api/dashboard JSON contract (hours validation, shape, timestamps).

require_relative "../test_helper"
require "janus/app"
require "janus/event_log"
require "janus/commander"
require "janus/hue"
require "rack/test"
require "json"
require "time"

class AppTest < Minitest::Test
  include JanusTestHelpers
  include Rack::Test::Methods

  Reading = Data.define(:observed, :temperature, :humidity)
  ISO8601_Z = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  # Records set_light calls; optionally raises a Hue::Error to model a bridge
  # that rejects the PUT.
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

  def app
    Janus::App
  end

  def setup
    @tmpdir = Dir.mktmpdir("janus-app-test")
    @store = Janus::Store.new(path: File.join(@tmpdir, "janus.duckdb"))
    @event_log = Janus::EventLog.new(store: @store)
    seed_store(@store)
    Janus::App.set :store, @store
    Janus::App.set :event_log, @event_log
    set_commander(hue: StubHue.new)
  end

  def teardown
    Janus::App.set :store, nil
    Janus::App.set :event_log, nil
    Janus::App.set :commander, nil
    @store.close
    FileUtils.remove_entry(@tmpdir)
  end

  # Injects a commander over the shared event log; hue: nil models an
  # unconfigured bridge.
  def set_commander(hue:)
    @hue = hue
    Janus::App.set :commander, Janus::Commander.new(hue: hue, event_log: @event_log)
  end

  def seed_device(id: "hue.light.abc")
    @store.upsert_device(id: id, name: "Porch Light", room: "Outside",
                         kind: "light", source: "hue", reachable: nil)
    id
  end

  def seed_store(store)
    store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
    store.upsert_sensor(id: "s2", name: "Bedroom", active: true, battery_percentage: 80.0)
    now = Time.now.utc
    store.insert_readings("s1", [
      Reading.new(observed: now - 3600, temperature: 20.04, humidity: 40.06),
      Reading.new(observed: now - 300, temperature: 21.34, humidity: 45.67)
    ])
  end

  def test_static_assets_require_revalidation
    get "/dash.js"
    assert_equal 200, last_response.status
    assert_includes last_response.headers.fetch("cache-control", ""), "no-cache"

    get "/"
    assert_includes last_response.headers.fetch("cache-control", ""), "no-cache"
  end

  def test_healthz
    get "/healthz"
    assert_equal 200, last_response.status
    assert_match %r{\Atext/plain}, last_response.content_type
    assert_equal "ok", last_response.body
  end

  def test_dashboard_defaults_to_24_hours
    get "/api/dashboard"
    assert_equal 200, last_response.status
    assert_match %r{\Aapplication/json}, last_response.content_type
    body = JSON.parse(last_response.body)
    assert_equal 24, body["hours"]
  end

  def test_dashboard_accepts_each_allowed_hours_value
    [24, 72, 168, 720].each do |hours|
      get "/api/dashboard", hours: hours.to_s
      assert_equal 200, last_response.status, "hours=#{hours} should be accepted"
      assert_equal hours, JSON.parse(last_response.body)["hours"]
    end
  end

  def test_dashboard_rejects_disallowed_hours
    ["48", "0", "-24", "abc", "24.5", ""].each do |hours|
      get "/api/dashboard", hours: hours
      assert_equal 400, last_response.status, "hours=#{hours.inspect} should be rejected"
      assert_match %r{\Aapplication/json}, last_response.content_type
      body = JSON.parse(last_response.body)
      assert_kind_of String, body["error"]
      refute_empty body["error"]
    end
  end

  def test_dashboard_json_contract
    get "/api/dashboard"
    body = JSON.parse(last_response.body)

    assert_equal %w[cooling devices generated_at hours sensors], body.keys.sort
    assert_match ISO8601_Z, body["generated_at"]
    assert_equal 24, body["hours"]

    assert_equal 2, body["sensors"].size
    attic, bedroom = body["sensors"]
    assert_equal %w[active battery_percentage id latest name range series], attic.keys.sort

    assert_equal "s1", attic["id"]
    assert_equal "Attic", attic["name"]
    assert_equal true, attic["active"]
    assert_in_delta 90.0, attic["battery_percentage"]

    assert_equal %w[humidity observed temperature], attic["latest"].keys.sort
    assert_match ISO8601_Z, attic["latest"]["observed"]
    assert_equal 21.3, attic["latest"]["temperature"]
    assert_equal 45.7, attic["latest"]["humidity"]

    assert_equal %w[hum_max hum_min temp_max temp_min], attic["range"].keys.sort
    assert_equal 20.0, attic["range"]["temp_min"]
    assert_equal 21.3, attic["range"]["temp_max"]
    assert_equal 40.1, attic["range"]["hum_min"]
    assert_equal 45.7, attic["range"]["hum_max"]

    assert_equal 2, attic["series"].size
    attic["series"].each do |point|
      assert_equal %w[hum t temp], point.keys.sort
      assert_match ISO8601_Z, point["t"]
    end
    assert_equal 21.3, attic["series"].last["temp"]
    assert_equal attic["series"].map { |p| p["t"] }.sort, attic["series"].map { |p| p["t"] }

    assert_equal "Bedroom", bedroom["name"]
    assert_nil bedroom["latest"]
    assert_nil bedroom["range"]
    assert_equal [], bedroom["series"]
  end

  def test_cooling_is_null_without_an_outside_sensor
    get "/api/dashboard"
    body = JSON.parse(last_response.body)
    assert body.key?("cooling")
    assert_nil body["cooling"]
  end

  def test_cooling_reports_positive_differential_as_not_free_cooling
    seed_outside(temperature: 95.0, humidity: 53.0) # hotter than the house
    get "/api/dashboard"
    cooling = JSON.parse(last_response.body).fetch("cooling")

    now = cooling.fetch("now")
    assert_equal 95.0, now["outside_temp"]
    # House temp is the mean of each indoor sensor's latest reading; only s1
    # has readings, so it is s1's latest.
    assert_equal 21.3, now["house_temp"]
    assert_in_delta 73.7, now["delta"]
    assert_in_delta 75.2, now["dew_point"], 0.3
    assert_equal false, now["free_cooling"]

    series = cooling.fetch("series")
    refute_empty series
    assert_equal series.map { |p| p["t"] }.sort, series.map { |p| p["t"] }
    series.each do |point|
      assert_equal %w[delta t], point.keys.sort
      assert_match ISO8601_Z, point["t"]
      assert_equal point["delta"].round(1), point["delta"]
    end
  end

  def test_cooling_flags_free_cooling_when_cooler_and_dew_point_comfortable
    seed_outside(temperature: 15.0, humidity: 50.0) # cooler, dew point ~ -3F
    get "/api/dashboard"
    now = JSON.parse(last_response.body).dig("cooling", "now")
    assert_operator now["delta"], :<, 0
    assert_operator now["dew_point"], :<=, 63.0
    assert_equal true, now["free_cooling"]
  end

  def test_cooling_denies_free_cooling_when_cooler_but_muggy
    # Raise the house mean via s2 so outside air warm enough to be muggy
    # (dew point cannot exceed air temperature) still reads as cooler.
    @store.insert_readings("s2", [
      Reading.new(observed: Time.now.utc - 300, temperature: 130.0, humidity: 40.0)
    ])
    seed_outside(temperature: 70.0, humidity: 90.0) # cooler than the mean, dew point ~ 66.9F
    get "/api/dashboard"
    now = JSON.parse(last_response.body).dig("cooling", "now")
    assert_operator now["delta"], :<, 0
    assert_operator now["dew_point"], :>, 63.0
    assert_equal false, now["free_cooling"]
  end

  def test_devices_default_to_an_empty_array
    get "/api/dashboard"
    assert_equal [], JSON.parse(last_response.body).fetch("devices")
  end

  def test_devices_carry_state_and_windowed_intervals
    now = Time.now.utc
    @store.upsert_device(id: "hue.light.abc", name: "Porch Light", room: "Outside",
                         kind: "light", source: "hue", reachable: nil)
    @event_log.record(observed: now - 7200, source: "hue", entity: "hue.light.abc",
                      kind: "state", payload: { on: true })
    @event_log.record(observed: now - 600, source: "hue", entity: "hue.light.abc",
                      kind: "state", payload: { on: false })

    get "/api/dashboard"
    devices = JSON.parse(last_response.body).fetch("devices")
    assert_equal 1, devices.size
    device = devices.first
    assert_equal %w[id intervals kind last_command name on pending room], device.keys.sort
    assert_equal false, device["pending"], "no command means not pending"
    assert_nil device["last_command"]
    assert_equal "hue.light.abc", device["id"]
    assert_equal "Porch Light", device["name"]
    assert_equal "Outside", device["room"]
    assert_equal "light", device["kind"]
    assert_equal false, device["on"]

    intervals = device["intervals"]
    assert_equal 2, intervals.size
    intervals.each do |interval|
      assert_equal %w[from on to], interval.keys.sort
      assert_match ISO8601_Z, interval["from"]
      assert_match ISO8601_Z, interval["to"]
    end
    assert_equal [true, false], intervals.map { |interval| interval["on"] }
    assert_equal intervals[0]["to"], intervals[1]["from"], "intervals abut at the state change"
  end

  def test_device_without_state_events_reads_as_unknown_not_off
    @store.upsert_device(id: "hue.light.new", name: "Lamp", room: "Living Room",
                         kind: "light", source: "hue", reachable: nil)
    get "/api/dashboard"
    device = JSON.parse(last_response.body).fetch("devices").first
    assert_nil device["on"]
    assert_equal [], device["intervals"]
  end

  def test_dashboard_device_reflects_pending_and_last_command
    id = seed_device
    now = Time.now.utc
    @event_log.request(entity: id, action: { on: true }, source: "dashboard", requested_at: now)

    get "/api/dashboard"
    device = JSON.parse(last_response.body).fetch("devices").first
    assert_equal true, device["pending"]
    last = device.fetch("last_command")
    assert_equal true, last["on"]
    assert_equal "pending", last["status"]
    assert_match ISO8601_Z, last["requested_at"]
    assert_nil last["resolved_at"]
  end

  def test_toggle_records_a_pending_command_and_calls_the_bridge
    id = seed_device
    post "/api/devices/#{id}/toggle", JSON.generate(on: true), "CONTENT_TYPE" => "application/json"

    assert_equal 200, last_response.status
    assert_match %r{\Aapplication/json}, last_response.content_type
    body = JSON.parse(last_response.body)
    assert_equal "pending", body["status"]
    assert_equal true, body["on"]
    assert_kind_of Integer, body["command_id"]
    assert_equal [["abc", true]], @hue.calls

    cmd = @event_log.command(body["command_id"])
    assert_equal "pending", cmd[:status]
  end

  def test_toggle_rejects_a_malformed_body
    id = seed_device
    ["{}", JSON.generate(on: "yes"), "not json", ""].each do |raw|
      post "/api/devices/#{id}/toggle", raw, "CONTENT_TYPE" => "application/json"
      assert_equal 400, last_response.status, "body #{raw.inspect} should be rejected"
      assert_kind_of String, JSON.parse(last_response.body)["error"]
    end
    assert_empty @hue.calls, "a malformed toggle never reaches the bridge"
  end

  def test_toggle_unknown_device_is_404
    post "/api/devices/hue.light.nope/toggle", JSON.generate(on: true),
         "CONTENT_TYPE" => "application/json"
    assert_equal 404, last_response.status
    assert_empty @hue.calls
  end

  def test_toggle_is_409_when_control_is_unconfigured
    id = seed_device
    set_commander(hue: nil)
    post "/api/devices/#{id}/toggle", JSON.generate(on: true), "CONTENT_TYPE" => "application/json"

    assert_equal 409, last_response.status
    assert_match(/not configured/, JSON.parse(last_response.body)["error"])
  end

  def test_toggle_is_502_and_echoes_status_when_the_bridge_errors
    id = seed_device
    set_commander(hue: StubHue.new(error: Janus::Hue::Error.new("bad light", status: 503)))
    post "/api/devices/#{id}/toggle", JSON.generate(on: false), "CONTENT_TYPE" => "application/json"

    assert_equal 502, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 503, body["status"]
    refute_empty body["error"]
  end

  def test_dashboard_lists_no_toggles_but_still_serves_when_unconfigured
    seed_device
    set_commander(hue: nil)
    get "/api/dashboard"
    assert_equal 200, last_response.status
    assert_equal 1, JSON.parse(last_response.body).fetch("devices").size
  end

  def test_command_endpoint_returns_the_command_fields
    id = seed_device
    now = Time.now.utc
    cid = @event_log.request(entity: id, action: { on: true }, source: "dashboard",
                             requested_at: now - 5)

    get "/api/commands/#{cid}"
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal %w[detail entity id on requested_at resolved_at status].sort, body.keys.sort
    assert_equal cid, body["id"]
    assert_equal id, body["entity"]
    assert_equal true, body["on"]
    assert_equal "pending", body["status"]
    assert_match ISO8601_Z, body["requested_at"]
    assert_nil body["resolved_at"]
  end

  def test_command_endpoint_confirms_opportunistically_from_a_state_event
    id = seed_device
    now = Time.now.utc
    cid = @event_log.request(entity: id, action: { on: true }, source: "dashboard",
                             requested_at: now - 5)
    @event_log.record(observed: now - 2, source: "hue", entity: id, kind: "state",
                      payload: { on: true })

    get "/api/commands/#{cid}"
    body = JSON.parse(last_response.body)
    assert_equal "confirmed", body["status"], "serving status reconciles pending commands"
    assert_match ISO8601_Z, body["resolved_at"]
  end

  def test_command_endpoint_404_for_unknown_id
    get "/api/commands/999999"
    assert_equal 404, last_response.status
    get "/api/commands/not-a-number"
    assert_equal 404, last_response.status
  end

  private

  # Adds the Outside pseudo-sensor with readings aligned to s1's, so the
  # differential series has overlapping buckets and a fresh "now".
  def seed_outside(temperature:, humidity:)
    @store.upsert_sensor(id: "nws.KEFD", name: "Outside", active: true, battery_percentage: nil)
    now = Time.now.utc
    @store.insert_readings("nws.KEFD", [
      Reading.new(observed: now - 3600, temperature: temperature - 1.0, humidity: humidity),
      Reading.new(observed: now - 300, temperature: temperature, humidity: humidity)
    ])
  end
end
