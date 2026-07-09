# ABOUTME: Unit tests for Janus::Poller — skip logic when unconfigured, the
# ABOUTME: polling loop via injected source factories, error recovery, and the
# ABOUTME: collection audit trail.

require_relative "../test_helper"
require "janus/store"
require "janus/event_log"
require "janus/poller"
require "stringio"

class PollerTest < Minitest::Test
  include JanusTestHelpers

  # Client stub whose sensors() call signals a Queue, so tests can wait on
  # poll iterations deterministically instead of sleeping.
  class SignalingClient
    def initialize(queue, authenticated: true, sensors_error: nil)
      @queue = queue
      @authenticated = authenticated
      @sensors_error = sensors_error
    end

    def authenticate
      @authenticated
    end

    def sensors
      @queue << :polled
      raise @sensors_error if @sensors_error

      []
    end
  end

  # Weather stub whose observations() call signals a Queue, mirroring
  # SignalingClient for the outside-air collection source.
  class SignalingWeather
    def initialize(queue, observations_error: nil)
      @queue = queue
      @observations_error = observations_error
    end

    def sensor_id
      "nws.KEFD"
    end

    def sensor_name
      "Outside"
    end

    def observations(since:)
      @queue << :weather
      raise @observations_error if @observations_error

      []
    end
  end

  # Hue stub whose lights() call signals a Queue, mirroring SignalingClient;
  # open_event_stream parks forever so the stream thread stays quiet.
  class SignalingHue
    attr_reader :stream_opens

    def initialize(queue)
      @queue = queue
      @stream_opens = Queue.new
    end

    def lights
      @queue << :hue
      []
    end

    def open_event_stream
      @stream_opens << :opened
      Queue.new.pop # park the stream thread; the poller loop is under test
    end
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def with_store(&block)
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      begin
        block.call(store)
      ensure
        store.close
      end
    end
  end

  def test_start_if_configured_skips_when_nothing_is_configured
    with_env("SENSORPUSH_USERNAME" => nil, "SENSORPUSH_PASSWORD" => nil,
             "JANUS_OUTSIDE_STATION" => nil, "JANUS_COLLECT" => nil,
             "HUE_BRIDGE_IP" => nil, "HUE_APP_KEY" => nil) do
      with_store do |store|
        log = StringIO.new
        result = Janus::Poller.start_if_configured(store: store, logger_io: log)
        assert_nil result
        assert_match(/SENSORPUSH_USERNAME/, log.string)
        assert_match(/JANUS_OUTSIDE_STATION/, log.string)
        assert_match(/HUE_BRIDGE_IP/, log.string)
        assert_equal 1, log.string.lines.size
      end
    end
  end

  def test_start_if_configured_notes_skipped_hue_once_when_other_sources_run
    with_env("SENSORPUSH_USERNAME" => nil, "SENSORPUSH_PASSWORD" => nil,
             "JANUS_OUTSIDE_STATION" => "KEFD", "JANUS_COLLECT" => nil,
             "HUE_BRIDGE_IP" => nil, "HUE_APP_KEY" => nil) do
      with_store do |store|
        queue = Queue.new
        log = StringIO.new
        thread = Janus::Poller.start_if_configured(
          store: store, logger_io: log, interval: 0.01,
          weather_factory: proc { SignalingWeather.new(queue) }
        )
        begin
          refute_nil thread
          queue.pop(timeout: 2)
          skip_lines = log.string.lines.grep(/skipping hue collection/)
          assert_equal 1, skip_lines.size
        ensure
          thread.kill
          thread.join
        end
      end
    end
  end

  def test_start_if_configured_runs_hue_when_bridge_credentials_set
    with_env("SENSORPUSH_USERNAME" => nil, "SENSORPUSH_PASSWORD" => nil,
             "JANUS_OUTSIDE_STATION" => nil, "JANUS_COLLECT" => nil,
             "HUE_BRIDGE_IP" => "192.168.1.50", "HUE_APP_KEY" => "key") do
      with_store do |store|
        queue = Queue.new
        hue = SignalingHue.new(queue)
        event_log = Janus::EventLog.new(store: store)
        thread = Janus::Poller.start_if_configured(
          store: store, event_log: event_log, logger_io: StringIO.new,
          interval: 0.01, hue_factory: proc { hue }, hue_stream: false
        )
        begin
          refute_nil thread
          assert_equal :hue, queue.pop(timeout: 2)
          assert_equal :hue, queue.pop(timeout: 2)
        ensure
          thread.kill
          thread.join
        end
      end
    end
  end

  def test_start_raises_when_hue_is_enabled_without_an_event_log
    with_store do |store|
      assert_raises(ArgumentError) do
        Janus::Poller.start(store: store, hue: true, logger_io: StringIO.new)
      end
    end
  end

  def test_start_records_collection_events_for_each_source
    with_store do |store|
      queue = Queue.new
      event_log = Janus::EventLog.new(store: store)
      hue = SignalingHue.new(queue)
      thread = Janus::Poller.start(
        store: store, event_log: event_log, interval: 0.01,
        client_factory: proc { SignalingClient.new(queue) },
        weather_factory: proc { SignalingWeather.new(queue) },
        hue_factory: proc { hue },
        weather: true, hue: true, hue_stream: false,
        logger_io: StringIO.new
      )
      begin
        6.times { queue.pop(timeout: 2) } # two full cycles across all sources
        events = event_log.events_in(hours: 1, kinds: ["collection"])
        assert_operator events.size, :>=, 3
        assert_equal %w[hue sensorpush weather], events.map { |event| event[:entity] }.uniq.sort
        assert(events.all? { |event| event[:source] == "janus" })
        hue_event = events.find { |event| event[:entity] == "hue" }
        assert_equal({ "devices" => 0, "state_events" => 0 }, hue_event[:payload])
      ensure
        thread.kill
        thread.join
      end
    end
  end

  def test_start_launches_the_hue_stream_thread_when_enabled
    with_store do |store|
      queue = Queue.new
      hue = SignalingHue.new(queue)
      thread = Janus::Poller.start(
        store: store, event_log: Janus::EventLog.new(store: store), interval: 0.01,
        hue_factory: proc { hue }, sensorpush: false, hue: true,
        logger_io: StringIO.new
      )
      begin
        assert_equal :opened, hue.stream_opens.pop(timeout: 2)
        assert_equal :hue, queue.pop(timeout: 2)
      ensure
        thread.kill
        thread.join
      end
    end
  end

  def test_start_if_configured_runs_weather_only_when_station_set_without_credentials
    with_env("SENSORPUSH_USERNAME" => nil, "SENSORPUSH_PASSWORD" => nil,
             "JANUS_OUTSIDE_STATION" => "KEFD", "JANUS_COLLECT" => nil,
             "HUE_BRIDGE_IP" => nil, "HUE_APP_KEY" => nil) do
      with_store do |store|
        queue = Queue.new
        client_factory_calls = 0
        client_factory = proc { client_factory_calls += 1 }
        weather_factory = proc { SignalingWeather.new(queue) }

        thread = Janus::Poller.start_if_configured(
          store: store, logger_io: StringIO.new, interval: 0.01,
          client_factory: client_factory, weather_factory: weather_factory
        )
        begin
          refute_nil thread
          assert_equal :weather, queue.pop(timeout: 2)
          assert_equal :weather, queue.pop(timeout: 2)
          assert_equal 0, client_factory_calls, "SensorPush client must not be built without credentials"
        ensure
          thread.kill
          thread.join
        end
      end
    end
  end

  def test_start_if_configured_skips_when_collection_off
    with_env("SENSORPUSH_USERNAME" => "u@example.com", "SENSORPUSH_PASSWORD" => "pw",
             "JANUS_COLLECT" => "off", "HUE_BRIDGE_IP" => nil, "HUE_APP_KEY" => nil) do
      with_store do |store|
        log = StringIO.new
        result = Janus::Poller.start_if_configured(store: store, logger_io: log)
        assert_nil result
        assert_match(/JANUS_COLLECT/, log.string)
        assert_equal 1, log.string.lines.size
      end
    end
  end

  def test_start_polls_repeatedly_via_injected_client_factory
    with_store do |store|
      queue = Queue.new
      factory_calls = 0
      factory = proc do
        factory_calls += 1
        SignalingClient.new(queue)
      end

      thread = Janus::Poller.start(store: store, interval: 0.01,
                                   client_factory: factory, logger_io: StringIO.new)
      begin
        assert_equal :polled, queue.pop(timeout: 2)
        assert_equal :polled, queue.pop(timeout: 2)
        assert_equal 1, factory_calls, "client should be reused across iterations"
      ensure
        thread.kill
        thread.join
      end
    end
  end

  def test_start_logs_error_and_reauthenticates_next_iteration
    with_store do |store|
      queue = Queue.new
      log = StringIO.new
      clients = [
        SignalingClient.new(queue, sensors_error: RuntimeError.new("boom")),
        SignalingClient.new(queue)
      ]
      factory_calls = 0
      factory = proc do
        factory_calls += 1
        clients.shift
      end

      thread = Janus::Poller.start(store: store, interval: 0.01,
                                   client_factory: factory, logger_io: log)
      begin
        assert_equal :polled, queue.pop(timeout: 2) # failing iteration
        assert_equal :polled, queue.pop(timeout: 2) # recovered iteration
        assert_equal 2, factory_calls, "a fresh client should be built after an error"
        assert_match(/boom/, log.string)
        assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, log.string)
      ensure
        thread.kill
        thread.join
      end
    end
  end

  def test_start_runs_both_sources_via_injected_factories
    with_store do |store|
      queue = Queue.new
      weather_factory_calls = 0
      weather_factory = proc do
        weather_factory_calls += 1
        SignalingWeather.new(queue)
      end

      thread = Janus::Poller.start(store: store, interval: 0.01,
                                   client_factory: proc { SignalingClient.new(queue) },
                                   weather_factory: weather_factory, weather: true,
                                   logger_io: StringIO.new)
      begin
        seen = [queue.pop(timeout: 2), queue.pop(timeout: 2)]
        assert_equal [:polled, :weather], seen
        queue.pop(timeout: 2) # a second full iteration
        queue.pop(timeout: 2)
        assert_equal 1, weather_factory_calls, "weather client should be reused across iterations"
      ensure
        thread.kill
        thread.join
      end
    end
  end

  def test_start_logs_weather_error_and_rebuilds_weather_client
    with_store do |store|
      queue = Queue.new
      log = StringIO.new
      weathers = [
        SignalingWeather.new(queue, observations_error: RuntimeError.new("nws down")),
        SignalingWeather.new(queue)
      ]
      weather_factory_calls = 0
      weather_factory = proc do
        weather_factory_calls += 1
        weathers.shift
      end

      thread = Janus::Poller.start(store: store, interval: 0.01,
                                   weather_factory: weather_factory,
                                   sensorpush: false, weather: true, logger_io: log)
      begin
        assert_equal :weather, queue.pop(timeout: 2) # failing iteration
        assert_equal :weather, queue.pop(timeout: 2) # recovered iteration
        assert_equal 2, weather_factory_calls, "a fresh weather client should be built after an error"
        assert_match(/nws down/, log.string)
        assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, log.string)
      ensure
        thread.kill
        thread.join
      end
    end
  end

  def test_start_logs_failed_authentication_and_retries
    with_store do |store|
      queue = Queue.new
      log = StringIO.new
      clients = [
        SignalingClient.new(queue, authenticated: false),
        SignalingClient.new(queue)
      ]
      factory = proc { clients.shift }

      thread = Janus::Poller.start(store: store, interval: 0.01,
                                   client_factory: factory, logger_io: log)
      begin
        assert_equal :polled, queue.pop(timeout: 2) # from the second client
        assert_match(/authentication/i, log.string)
      ensure
        thread.kill
        thread.join
      end
    end
  end
end
