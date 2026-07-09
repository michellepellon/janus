# ABOUTME: End-to-end test — boots the real rackup server as a child process
# ABOUTME: against a seeded DuckDB file and exercises it over live HTTP.

require_relative "../test_helper"
require "janus/store"
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

    assert_equal "400", get("/api/dashboard?hours=48").code

    log = File.read(@log_path)
    assert_includes log, "JANUS_COLLECT=off; not collecting"
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
