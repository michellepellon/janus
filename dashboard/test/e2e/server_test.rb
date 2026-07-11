# ABOUTME: End-to-end test — boots the real rackup server as a child process
# ABOUTME: against a seeded DuckDB file and exercises it over live HTTP.

require_relative "../test_helper"
require "janus/store"
require "janus/event_log"
require "janus/schedules"
require "net/http"
require "json"
require "socket"
require "time"

class ServerE2ETest < Minitest::Test
  include JanusTestHelpers

  Reading = Data.define(:observed, :temperature, :humidity)

  SERVER_BOOT_DEADLINE = 15

  def setup
    @tmpdir = Dir.mktmpdir("janus-e2e")
    seed_database
    @port = free_port
    @log_path = File.join(@tmpdir, "server.log")
    @pid = spawn(
      {
        "JANUS_DB_PATH" => db_path,
        "JANUS_COLLECT" => "off",
        "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__)
      },
      "bundle", "exec", "rackup", "-o", "127.0.0.1", "-p", @port.to_s, "config.ru",
      chdir: File.expand_path("../..", __dir__),
      [:out, :err] => [@log_path, "w"]
    )
    wait_for_boot
  end

  def teardown
    if @pid
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def test_serves_dashboard_page_assets_api_and_skips_collection
    home = get("/")
    assert_equal "200", home.code
    assert_includes home["content-type"], "text/html"
    assert_includes home.body, "dash.js"
    assert_includes home.body, "style.css"

    assert_equal "200", get("/dash.js").code
    assert_equal "200", get("/style.css").code
    assert_equal "ok", get("/healthz").body

    api = get("/api/dashboard?hours=24")
    assert_equal "200", api.code
    payload = JSON.parse(api.body)
    assert_equal 24, payload["hours"]
    assert_equal %w[Bedroom Outside Study], payload["sensors"].map { |s| s["name"] }
    study = payload["sensors"].last
    assert_in_delta 71.6, study["latest"]["temperature"], 0.05
    assert_operator study["series"].size, :>, 0
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*Z/, payload["generated_at"])

    cooling = payload.fetch("cooling")
    assert_equal %w[now series], cooling.keys.sort
    assert_equal %w[delta dew_point free_cooling house_temp outside_temp], cooling["now"].keys.sort
    assert_operator cooling["now"]["delta"], :>, 0, "seeded outside runs hotter than the house"
    assert_operator cooling["series"].size, :>, 0

    devices = payload.fetch("devices")
    assert_equal 1, devices.size
    porch = devices.first
    assert_equal "Porch Light", porch["name"]
    assert_equal "Outside", porch["room"]
    assert_equal "light", porch["kind"]
    assert_equal true, porch["on"]
    assert_equal [false, true], porch["intervals"].map { |interval| interval["on"] }
    assert_equal true, porch["pending"], "the seeded pending command shows on the device"
    assert_equal false, porch["last_command"]["on"]
    assert_equal "pending", porch["last_command"]["status"]

    schedule = porch.fetch("schedule")
    assert_equal "19:00", schedule["on_time"]
    assert_equal "23:00", schedule["off_time"]
    assert_equal Janus::Schedules::DAYS, schedule["days"]
    assert_equal true, schedule["enabled"]

    adherence = porch.fetch("adherence")
    assert_equal %w[deviations expected marks], adherence.keys.sort
    assert_equal 1, adherence["deviations"]
    assert_equal 1, adherence["marks"].size
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*Z/, adherence["marks"].first["t"])
    refute_empty adherence["expected"], "a daily 19:00-23:00 span falls inside any 24 h window"
    adherence["expected"].each do |interval|
      assert_operator Time.parse(interval["from"]), :<, Time.parse(interval["to"])
    end

    assert_equal "400", get("/api/dashboard?hours=48").code

    log = File.read(@log_path)
    assert_includes log, "JANUS_COLLECT=off; not collecting"
  end

  def test_command_status_endpoint_serves_the_pending_command
    command = get("/api/commands/1")
    assert_equal "200", command.code
    body = JSON.parse(command.body)
    assert_equal 1, body["id"]
    assert_equal "hue.light.e2e", body["entity"]
    assert_equal false, body["on"]
    assert_equal "pending", body["status"]
    assert_equal "404", get("/api/commands/9999").code
  end

  def test_schedules_api_round_trips_over_live_http
    index = get("/api/schedules")
    assert_equal "200", index.code
    rows = JSON.parse(index.body)
    assert_equal ["hue.light.e2e"], rows.map { |row| row["entity"] }

    uri = URI("http://127.0.0.1:#{@port}/api/schedules/hue.light.e2e")
    updated = Net::HTTP.start(uri.host, uri.port) do |http|
      http.put(uri.path, JSON.generate(on_time: "20:00", off_time: "23:30",
                                       days: %w[fri sat], enabled: true),
               "Content-Type" => "application/json")
    end
    assert_equal "200", updated.code
    body = JSON.parse(updated.body)
    assert_equal "20:00", body["on_time"]
    assert_equal %w[fri sat], body["days"]

    invalid = Net::HTTP.start(uri.host, uri.port) do |http|
      http.put(uri.path, JSON.generate(on_time: "20:00", off_time: "20:00",
                                       days: %w[fri], enabled: true),
               "Content-Type" => "application/json")
    end
    assert_equal "422", invalid.code
    assert_kind_of String, JSON.parse(invalid.body).dig("errors", "off_time")

    deleted = Net::HTTP.start(uri.host, uri.port) { |http| http.delete(uri.path) }
    assert_equal "204", deleted.code
    assert_equal [], JSON.parse(get("/api/schedules").body)
  end

  def test_toggle_is_unavailable_without_a_configured_bridge
    uri = URI("http://127.0.0.1:#{@port}/api/devices/hue.light.e2e/toggle")
    response = Net::HTTP.start(uri.host, uri.port) do |http|
      http.post(uri.path, JSON.generate(on: false), "Content-Type" => "application/json")
    end
    assert_equal "409", response.code, "the e2e server has no Hue env, so control is unconfigured"
    assert_match(/not configured/, JSON.parse(response.body)["error"])
  end

  private

  def db_path
    File.join(@tmpdir, "janus.duckdb")
  end

  def seed_database
    store = Janus::Store.new(path: db_path)
    now = Time.now.getutc
    store.upsert_sensor(id: "e2e-1", name: "Study", active: true, battery_percentage: 88.0)
    store.upsert_sensor(id: "e2e-2", name: "Bedroom", active: true, battery_percentage: 17.0)
    readings = (0...12).map do |i|
      Reading.new(observed: now - (i * 600), temperature: 71.6 - (i * 0.1), humidity: 45.0 + (i * 0.2))
    end
    store.insert_readings("e2e-1", readings)
    store.insert_readings("e2e-2", readings.map { |r| Reading.new(observed: r.observed, temperature: 68.0, humidity: 50.0) })
    store.upsert_sensor(id: "nws.KEFD", name: "Outside", active: true, battery_percentage: nil)
    store.insert_readings("nws.KEFD", (0...2).map do |i|
      Reading.new(observed: now - (i * 3600), temperature: 93.0 - i, humidity: 45.0)
    end)
    event_log = Janus::EventLog.new(store: store)
    store.upsert_device(id: "hue.light.e2e", name: "Porch Light", room: "Outside",
                        kind: "light", source: "hue", reachable: nil)
    event_log.record(observed: now - 7200, source: "hue", entity: "hue.light.e2e",
                     kind: "state", payload: { on: false })
    event_log.record(observed: now - 1800, source: "hue", entity: "hue.light.e2e",
                     kind: "state", payload: { on: true })
    # A recent pending command (id 1 in a fresh ledger) — the first control
    # asked for on this device, not yet confirmed.
    event_log.request(entity: "hue.light.e2e", action: { on: false },
                      source: "dashboard", requested_at: now)
    schedules = Janus::Schedules.new(store: store)
    schedules.upsert(entity: "hue.light.e2e", on_time: "19:00", off_time: "23:00",
                     days: Janus::Schedules::DAYS.dup, enabled: true)
    event_log.record(observed: now - 5400, source: "janus", entity: "hue.light.e2e",
                     kind: "deviation",
                     payload: { expected: true, observed: false, since: (now - 5700).iso8601 })
    store.close
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_boot
    deadline = Time.now + SERVER_BOOT_DEADLINE
    loop do
      return if get("/healthz").is_a?(Net::HTTPSuccess)
      raise "server did not boot within #{SERVER_BOOT_DEADLINE}s:\n#{File.read(@log_path)}" if Time.now > deadline

      sleep 0.2
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      raise "server did not boot within #{SERVER_BOOT_DEADLINE}s:\n#{File.read(@log_path)}" if Time.now > deadline

      sleep 0.2
    end
  end

  def get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}#{path}"))
  end
end
