# ABOUTME: Unit tests for Janus::WeatherCollector — pseudo-sensor upserts,
# ABOUTME: backfill vs incremental windows, counts, and transient-error retry.

require_relative "../test_helper"
require "janus/store"
require "janus/weather_collector"
require "time"

class WeatherCollectorTest < Minitest::Test
  include JanusTestHelpers

  StubSample = Data.define(:observed, :temperature, :humidity)

  # Minimal stand-in for Janus::Weather::Client. Records every observations()
  # call; raises queued errors before serving the canned samples.
  class StubWeather
    attr_reader :since_calls

    def initialize(observations: [], errors: [])
      @observations = observations
      @errors = errors
      @since_calls = []
    end

    def sensor_id
      "nws.KEFD"
    end

    def sensor_name
      "Outside"
    end

    def observations(since:)
      @since_calls << since
      raise @errors.shift unless @errors.empty?

      @observations
    end
  end

  def stub_samples(times, temp: 86.0, hum: 52.8)
    times.map { |t| StubSample.new(observed: t, temperature: temp, humidity: hum) }
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

  def test_backfill_window_when_store_empty
    with_store do |store|
      weather = StubWeather.new

      Janus::WeatherCollector.new(weather: weather, store: store, backfill_days: 7).run_once

      assert_equal 1, weather.since_calls.size
      assert_in_delta Time.now.utc - (7 * 86_400), weather.since_calls.first, 60
    end
  end

  def test_incremental_window_from_latest_observed
    with_store do |store|
      latest = Time.utc(2026, 7, 7, 9, 0, 0)
      store.insert_readings("nws.KEFD", stub_samples([latest]))
      weather = StubWeather.new

      Janus::WeatherCollector.new(weather: weather, store: store).run_once

      assert_equal [latest], weather.since_calls
    end
  end

  def test_upserts_pseudo_sensor_with_nil_battery
    with_store do |store|
      weather = StubWeather.new

      Janus::WeatherCollector.new(weather: weather, store: store).run_once

      row = store.dashboard(hours: 24).find { |r| r[:id] == "nws.KEFD" }
      refute_nil row
      assert_equal "Outside", row[:name]
      assert_equal true, row[:active]
      assert_nil row[:battery_percentage]
    end
  end

  def test_inserts_observations_and_returns_counts
    with_store do |store|
      samples = stub_samples([Time.utc(2026, 7, 8, 10, 54), Time.utc(2026, 7, 8, 11, 54)])
      weather = StubWeather.new(observations: samples)

      result = Janus::WeatherCollector.new(weather: weather, store: store).run_once

      assert_equal({ readings: 2 }, result)
      assert_equal Time.utc(2026, 7, 8, 11, 54), store.latest_observed("nws.KEFD")
    end
  end

  def test_retries_transient_network_errors_with_backoff
    with_store do |store|
      samples = stub_samples([Time.utc(2026, 7, 8, 10, 54)])
      weather = StubWeather.new(observations: samples, errors: [Errno::ECONNRESET.new("dropped")])
      naps = []

      result = Janus::WeatherCollector.new(
        weather: weather, store: store, sleeper: ->(s) { naps << s }
      ).run_once

      assert_equal({ readings: 1 }, result)
      assert_equal 2, weather.since_calls.size
      assert_equal 1, naps.size
    end
  end
end
