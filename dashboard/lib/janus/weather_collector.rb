# ABOUTME: Janus::WeatherCollector stores NWS station observations in a
# ABOUTME: Janus::Store as a pseudo-sensor, incrementally from the last reading.

require "time"
require_relative "retries"

module Janus
  class WeatherCollector
    include Retries

    # The NWS keeps 7 days of observations, so a longer backfill buys nothing.
    def initialize(weather:, store:, backfill_days: 7, sleeper: ->(seconds) { sleep(seconds) })
      @weather = weather
      @store = store
      @backfill_days = backfill_days
      @sleeper = sleeper
    end

    # Upserts the pseudo-sensor and collects observations since the last
    # stored reading. Returns { readings: <rows inserted> }.
    def run_once
      @store.upsert_sensor(
        id: @weather.sensor_id,
        name: @weather.sensor_name,
        active: true,
        battery_percentage: nil
      )
      since = @store.latest_observed(@weather.sensor_id) ||
              (Time.now.getutc - (@backfill_days * 86_400))
      observations = with_retries { @weather.observations(since: since) }
      { readings: @store.insert_readings(@weather.sensor_id, observations) }
    end
  end
end
