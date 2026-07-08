# ABOUTME: Unit tests for Janus::Weather::Client — GeoJSON parsing to ascending
# ABOUTME: Fahrenheit samples, request shape, headers, and HTTP error handling.

require_relative "../test_helper"
require "janus/weather"
require "json"
require "time"

class WeatherTest < Minitest::Test
  include JanusTestHelpers

  # Fetcher stub: records every (uri, headers) call and returns the canned
  # [status, body] response.
  class StubFetcher
    attr_reader :calls

    def initialize(status:, body:)
      @status = status
      @body = body
      @calls = []
    end

    def call(uri, headers)
      @calls << [uri, headers]
      [@status, @body]
    end
  end

  # Canned NWS GeoJSON: one feature per observation hash, newest-first as the
  # live API returns them.
  def geojson(observations)
    features = observations.map do |obs|
      {
        "properties" => {
          "timestamp" => obs.fetch(:timestamp),
          "temperature" => {
            "unitCode" => "wmoUnit:degC", "value" => obs.fetch(:temp_c), "qualityControl" => "V"
          },
          "relativeHumidity" => { "value" => obs.fetch(:humidity) }
        }
      }
    end
    JSON.generate("features" => features)
  end

  def client(fetcher, station: "KEFD", **options)
    Janus::Weather::Client.new(station: station, fetcher: fetcher, **options)
  end

  def test_parses_newest_first_geojson_into_ascending_fahrenheit_samples
    fetcher = StubFetcher.new(status: 200, body: geojson([
      { timestamp: "2026-07-08T20:54:00+00:00", temp_c: 30.0, humidity: 52.8 },
      { timestamp: "2026-07-08T19:54:00+00:00", temp_c: 25.0, humidity: 60.1 }
    ]))

    samples = client(fetcher).observations(since: Time.utc(2026, 7, 8))

    assert_equal 2, samples.size
    assert_equal Time.utc(2026, 7, 8, 19, 54), samples.first.observed
    assert_equal Time.utc(2026, 7, 8, 20, 54), samples.last.observed
    assert_in_delta 77.0, samples.first.temperature
    assert_in_delta 86.0, samples.last.temperature
    assert_in_delta 60.1, samples.first.humidity
    assert_in_delta 52.8, samples.last.humidity
    assert_kind_of Float, samples.first.temperature
  end

  def test_converts_offset_timestamps_to_utc
    fetcher = StubFetcher.new(status: 200, body: geojson([
      { timestamp: "2026-07-08T15:54:00-05:00", temp_c: 20.0, humidity: 50.0 }
    ]))

    samples = client(fetcher).observations(since: Time.utc(2026, 7, 8))

    assert_equal Time.utc(2026, 7, 8, 20, 54), samples.first.observed
    assert_predicate samples.first.observed, :utc?
  end

  def test_celsius_to_fahrenheit_conversion_is_exact
    fetcher = StubFetcher.new(status: 200, body: geojson([
      { timestamp: "2026-07-08T20:54:00+00:00", temp_c: 100, humidity: 50.0 },
      { timestamp: "2026-07-08T19:54:00+00:00", temp_c: 0, humidity: 50.0 },
      { timestamp: "2026-07-08T18:54:00+00:00", temp_c: -40, humidity: 50.0 },
      { timestamp: "2026-07-08T17:54:00+00:00", temp_c: 37.5, humidity: 50.0 }
    ]))

    samples = client(fetcher).observations(since: Time.utc(2026, 7, 8))

    assert_equal [99.5, -40.0, 32.0, 212.0], samples.map(&:temperature)
  end

  def test_skips_observations_with_null_temperature
    fetcher = StubFetcher.new(status: 200, body: geojson([
      { timestamp: "2026-07-08T20:54:00+00:00", temp_c: nil, humidity: 52.8 },
      { timestamp: "2026-07-08T19:54:00+00:00", temp_c: 25.0, humidity: 60.1 }
    ]))

    samples = client(fetcher).observations(since: Time.utc(2026, 7, 8))

    assert_equal 1, samples.size
    assert_equal Time.utc(2026, 7, 8, 19, 54), samples.first.observed
  end

  def test_keeps_null_humidity_as_nil
    fetcher = StubFetcher.new(status: 200, body: geojson([
      { timestamp: "2026-07-08T20:54:00+00:00", temp_c: 25.0, humidity: nil }
    ]))

    samples = client(fetcher).observations(since: Time.utc(2026, 7, 8))

    assert_equal 1, samples.size
    assert_nil samples.first.humidity
  end

  def test_requests_station_observations_with_since_and_limit
    fetcher = StubFetcher.new(status: 200, body: geojson([]))
    since = Time.utc(2026, 7, 1, 12, 0, 0)

    client(fetcher).observations(since: since)

    uri, _headers = fetcher.calls.first
    assert_match %r{\Ahttps://api\.weather\.gov/stations/KEFD/observations\?}, uri.to_s
    params = URI.decode_www_form(uri.query).to_h
    assert_equal "2026-07-01T12:00:00Z", params["start"]
    assert_equal "500", params["limit"]
  end

  def test_sends_user_agent_header
    fetcher = StubFetcher.new(status: 200, body: geojson([]))

    client(fetcher, user_agent: "janus-test-agent").observations(since: Time.utc(2026, 7, 8))

    _uri, headers = fetcher.calls.first
    assert_equal "janus-test-agent", headers["User-Agent"]
  end

  def test_user_agent_defaults_when_env_unset
    fetcher = StubFetcher.new(status: 200, body: geojson([]))
    saved = ENV["JANUS_NWS_USER_AGENT"]
    ENV.delete("JANUS_NWS_USER_AGENT")
    begin
      client(fetcher).observations(since: Time.utc(2026, 7, 8))
    ensure
      ENV["JANUS_NWS_USER_AGENT"] = saved
    end

    _uri, headers = fetcher.calls.first
    assert_equal "janus-dashboard", headers["User-Agent"]
  end

  def test_raises_with_status_context_on_non_2xx
    fetcher = StubFetcher.new(status: 503, body: "upstream sad")

    error = assert_raises(Janus::Weather::Error) do
      client(fetcher).observations(since: Time.utc(2026, 7, 8))
    end
    assert_match(/503/, error.message)
    assert_match(/KEFD/, error.message)
  end

  def test_sensor_identity
    weather = client(StubFetcher.new(status: 200, body: geojson([])))
    assert_equal "nws.KEFD", weather.sensor_id
    assert_equal "Outside", weather.sensor_name
  end
end
