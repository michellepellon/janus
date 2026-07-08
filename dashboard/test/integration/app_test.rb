# ABOUTME: Rack-test integration tests for Janus::App — health check and the
# ABOUTME: /api/dashboard JSON contract (hours validation, shape, timestamps).

require_relative "../test_helper"
require "janus/app"
require "rack/test"
require "json"
require "time"

class AppTest < Minitest::Test
  include JanusTestHelpers
  include Rack::Test::Methods

  Reading = Data.define(:observed, :temperature, :humidity)
  ISO8601_Z = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def app
    Janus::App
  end

  def setup
    @tmpdir = Dir.mktmpdir("janus-app-test")
    @store = Janus::Store.new(path: File.join(@tmpdir, "janus.duckdb"))
    seed_store(@store)
    Janus::App.set :store, @store
  end

  def teardown
    Janus::App.set :store, nil
    @store.close
    FileUtils.remove_entry(@tmpdir)
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

    assert_equal %w[generated_at hours sensors], body.keys.sort
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
end
