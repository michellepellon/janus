# ABOUTME: Unit tests for Janus::Collector — sensor upserts, backfill vs
# ABOUTME: incremental sample windows, paging, counts, and error context.

require_relative "../test_helper"
require "janus/store"
require "janus/collector"
require "time"
require "sensorpush"

class CollectorTest < Minitest::Test
  include JanusTestHelpers

  StubSensor = Data.define(:id, :name, :active, :battery_voltage)
  StubSample = Data.define(:observed, :temperature, :humidity)

  # Minimal in-memory stand-in for Sensorpush::Client. Records every samples()
  # call; serves batches from a queue (one array per expected call).
  class StubClient
    attr_reader :samples_calls

    def initialize(sensors:, batches: {})
      @sensor_list = sensors
      @batches = batches
      @samples_calls = []
    end

    def sensors
      @sensor_list
    end

    def samples(id, options = {})
      @samples_calls << [id, options]
      queue = @batches.fetch(id, [])
      queue.empty? ? [] : queue.shift
    end
  end

  def stub_sensor(id: "s1", name: "Attic", active: true, battery_voltage: 3.0)
    StubSensor.new(id: id, name: name, active: active, battery_voltage: battery_voltage)
  end

  def stub_samples(times, temp: 20.0, hum: 40.0)
    times.map { |t| StubSample.new(observed: t, temperature: temp, humidity: hum) }
  end

  def test_upserts_sensors_and_maps_battery_voltage_to_percentage
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      client = StubClient.new(sensors: [
        stub_sensor(id: "s1", name: "Attic", battery_voltage: 3.0),
        stub_sensor(id: "s2", name: "Bedroom", active: false, battery_voltage: 2.6)
      ])

      result = Janus::Collector.new(client: client, store: store).run_once

      assert_equal 2, result[:sensors]
      rows = store.dashboard(hours: 24)
      attic = rows.find { |r| r[:id] == "s1" }
      bedroom = rows.find { |r| r[:id] == "s2" }
      assert_in_delta 100.0, attic[:battery_percentage]
      assert_in_delta 50.0, bedroom[:battery_percentage]
      assert_equal false, bedroom[:active]
      store.close
    end
  end

  def test_backfill_window_when_store_empty
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      client = StubClient.new(sensors: [stub_sensor])

      Janus::Collector.new(client: client, store: store, backfill_days: 7).run_once

      assert_equal 1, client.samples_calls.size
      _id, options = client.samples_calls.first
      start = Time.iso8601(options[:start_time])
      assert_in_delta Time.now.utc - (7 * 86_400), start, 60
      refute options.key?(:end_time), "endTime is ignored by the API and must not be sent"
      store.close
    end
  end

  def test_incremental_window_from_latest_observed
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      latest = Time.utc(2026, 7, 6, 9, 0, 0)
      store.insert_readings("s1", stub_samples([latest]))
      client = StubClient.new(sensors: [stub_sensor])

      Janus::Collector.new(client: client, store: store).run_once

      _id, options = client.samples_calls.first
      assert_equal latest.iso8601, options[:start_time]
      store.close
    end
  end

  def test_inserts_samples_and_returns_counts
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      samples = stub_samples([Time.utc(2026, 7, 7, 10, 0), Time.utc(2026, 7, 7, 10, 5)])
      client = StubClient.new(sensors: [stub_sensor], batches: { "s1" => [samples] })

      result = Janus::Collector.new(client: client, store: store).run_once

      assert_equal({ sensors: 1, readings: 2 }, result)
      assert_equal Time.utc(2026, 7, 7, 10, 5), store.latest_observed("s1")
      store.close
    end
  end

  # The live API anchors at startTime and returns the OLDEST samples at or
  # after it (newest-first within the batch); paging must advance forward.
  def test_pages_forward_until_batch_smaller_than_limit
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      first_page = stub_samples([
        Time.utc(2026, 7, 7, 10, 30),
        Time.utc(2026, 7, 7, 10, 20),
        Time.utc(2026, 7, 7, 10, 10)
      ])
      second_page = stub_samples([Time.utc(2026, 7, 7, 10, 40)])
      client = StubClient.new(sensors: [stub_sensor], batches: { "s1" => [first_page, second_page] })

      result = Janus::Collector.new(
        client: client, store: store, page_limit: 3, sleeper: ->(_s) {}
      ).run_once

      assert_equal 4, result[:readings]
      assert_equal 2, client.samples_calls.size
      _id, second_options = client.samples_calls.last
      assert_equal Time.utc(2026, 7, 7, 10, 30, 1).iso8601, second_options[:start_time]
      refute second_options.key?(:end_time)
      assert_equal 3, second_options[:limit]
      assert_equal Time.utc(2026, 7, 7, 10, 40), store.latest_observed("s1")
      store.close
    end
  end

  # A full page that makes no forward progress must terminate the loop rather
  # than re-request the same window forever.
  def test_stops_when_a_full_page_makes_no_forward_progress
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      same_page = stub_samples([
        Time.utc(2026, 7, 7, 10, 40),
        Time.utc(2026, 7, 7, 10, 30)
      ])
      client = StubClient.new(
        sensors: [stub_sensor],
        batches: { "s1" => [same_page, same_page, same_page] }
      )
      store.insert_readings("s1", stub_samples([Time.utc(2026, 7, 7, 10, 20)]))

      result = Janus::Collector.new(
        client: client, store: store, page_limit: 2, sleeper: ->(_s) {}
      ).run_once

      assert_operator client.samples_calls.size, :<=, 2
      assert_equal 2, result[:readings]
      store.close
    end
  end

  def test_retries_transient_network_errors_with_backoff
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      samples = stub_samples([Time.utc(2026, 7, 7, 10, 0)])
      client = StubClient.new(sensors: [stub_sensor], batches: { "s1" => [samples] })
      failures = [Errno::ECONNRESET, EOFError]
      client.define_singleton_method(:samples) do |id, options = {}|
        raise failures.shift, "connection dropped" unless failures.empty?

        @samples_calls << [id, options]
        queue = @batches.fetch(id, [])
        queue.empty? ? [] : queue.shift
      end
      naps = []

      result = Janus::Collector.new(
        client: client, store: store, sleeper: ->(s) { naps << s }
      ).run_once

      assert_equal({ sensors: 1, readings: 1 }, result)
      assert_equal 1, client.samples_calls.size
      assert_equal 2, naps.size
      assert_operator naps.last, :>=, naps.first
      store.close
    end
  end

  def test_retries_rate_limited_api_errors
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      samples = stub_samples([Time.utc(2026, 7, 7, 10, 0)])
      client = StubClient.new(sensors: [stub_sensor], batches: { "s1" => [samples] })
      throttled = [Sensorpush::APIError.new("Too many requests", status: 429)]
      client.define_singleton_method(:samples) do |id, options = {}|
        raise throttled.shift unless throttled.empty?

        @samples_calls << [id, options]
        queue = @batches.fetch(id, [])
        queue.empty? ? [] : queue.shift
      end
      naps = []

      result = Janus::Collector.new(
        client: client, store: store, sleeper: ->(s) { naps << s }
      ).run_once

      assert_equal({ sensors: 1, readings: 1 }, result)
      assert_equal 1, naps.size
      store.close
    end
  end

  def test_does_not_retry_client_side_api_errors
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      client = StubClient.new(sensors: [stub_sensor])
      attempts = 0
      client.define_singleton_method(:samples) do |_id, _options = {}|
        attempts += 1
        raise Sensorpush::APIError.new("Bad request", status: 400)
      end

      assert_raises(Sensorpush::APIError) do
        Janus::Collector.new(client: client, store: store, sleeper: ->(_s) {}).run_once
      end
      assert_equal 1, attempts
      store.close
    end
  end

  def test_gives_up_after_exhausting_retries_and_keeps_sensor_context
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      client = StubClient.new(sensors: [stub_sensor(id: "s9", name: "Garage")])
      attempts = 0
      client.define_singleton_method(:samples) do |_id, _options = {}|
        attempts += 1
        raise Net::ReadTimeout
      end

      error = assert_raises(Net::ReadTimeout) do
        Janus::Collector.new(client: client, store: store, sleeper: ->(_s) {}).run_once
      end
      assert_equal 4, attempts
      assert_match(/s9/, error.message)
      assert_match(/Garage/, error.message)
      store.close
    end
  end

  def test_raises_client_errors_with_sensor_context
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      client = StubClient.new(sensors: [stub_sensor(id: "s9", name: "Garage")])
      def client.samples(_id, _options = {})
        raise Sensorpush::Error, "boom"
      end

      error = assert_raises(Sensorpush::Error) do
        Janus::Collector.new(client: client, store: store).run_once
      end
      assert_match(/s9/, error.message)
      assert_match(/Garage/, error.message)
      assert_match(/boom/, error.message)
      store.close
    end
  end
end
