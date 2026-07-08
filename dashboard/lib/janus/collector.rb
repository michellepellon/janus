# ABOUTME: Janus::Collector pulls sensors and samples from a SensorPush client
# ABOUTME: into a Janus::Store, paging incrementally from the last stored reading.

require "time"
require_relative "retries"

module Janus
  class Collector
    include Retries

    # Samples requested per API call; the sensorpush gem imposes no cap, so
    # this bounds response size while keeping round-trips low.
    PAGE_LIMIT = 1000

    # Seconds slept between successive page requests. The API documents a
    # once-per-minute budget but tolerates short bursts; pausing between pages
    # keeps long backfills from tripping its throttle (which surfaces as
    # dropped connections, handled by the retry ladder above).
    PAGE_PAUSE_SECONDS = 2

    # SensorPush sensors report battery voltage from a 3V lithium coin cell.
    # The dashboard shows a percentage, mapped linearly over the usable range.
    BATTERY_FULL_VOLTS = 3.0
    BATTERY_EMPTY_VOLTS = 2.2

    def initialize(client:, store:, backfill_days: 30, page_limit: PAGE_LIMIT,
                   sleeper: ->(seconds) { sleep(seconds) })
      @client = client
      @store = store
      @backfill_days = backfill_days
      @page_limit = page_limit
      @sleeper = sleeper
    end

    # Upserts every sensor and collects its samples since the last stored
    # reading. Returns { sensors: <count seen>, readings: <rows inserted> }.
    # Client errors are re-raised with the offending sensor identified.
    def run_once
      sensors = with_retries { @client.sensors }
      readings = 0
      sensors.each do |sensor|
        @store.upsert_sensor(
          id: sensor.id,
          name: sensor.name,
          active: sensor.active,
          battery_percentage: battery_percentage(sensor)
        )
        begin
          readings += collect_samples(sensor)
        rescue StandardError => e
          raise e.class, "sensor #{sensor.id} (#{sensor.name}): #{e.message}", e.backtrace
        end
      end
      { sensors: sensors.size, readings: readings }
    end

    private

    # Fetches everything from the last stored reading forward. The API anchors
    # at startTime and returns the OLDEST samples at or after it (its endTime
    # parameter is not honored), so paging advances start_time past the newest
    # sample of each full batch until a short batch marks the present.
    def collect_samples(sensor)
      from = @store.latest_observed(sensor.id) || (Time.now.getutc - (@backfill_days * 86_400))
      inserted = 0
      loop do
        batch = with_retries do
          @client.samples(sensor.id, limit: @page_limit, start_time: from.iso8601)
        end
        break if batch.empty?

        inserted += @store.insert_readings(sensor.id, batch)
        break if batch.size < @page_limit

        newest = batch.map { |sample| sample.observed.to_time.getutc }.max
        break if newest <= from

        from = newest + 1
        @sleeper.call(PAGE_PAUSE_SECONDS)
      end
      inserted
    end

    def battery_percentage(sensor)
      volts = sensor.battery_voltage
      return nil if volts.nil?

      fraction = (volts - BATTERY_EMPTY_VOLTS) / (BATTERY_FULL_VOLTS - BATTERY_EMPTY_VOLTS)
      (fraction * 100.0).clamp(0.0, 100.0)
    end
  end
end
