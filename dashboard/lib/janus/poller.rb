# ABOUTME: Janus::Poller runs SensorPush and NWS weather collection on a
# ABOUTME: background thread so exactly one process ever writes the DuckDB file.

require "sensorpush"
require "time"
require_relative "collector"
require_relative "weather"
require_relative "weather_collector"

module Janus
  class Poller
    DEFAULT_CLIENT_FACTORY = proc do
      Sensorpush.new(
        username: ENV["SENSORPUSH_USERNAME"],
        password: ENV["SENSORPUSH_PASSWORD"]
      )
    end

    DEFAULT_WEATHER_FACTORY = proc do
      Weather::Client.new(station: ENV.fetch("JANUS_OUTSIDE_STATION"))
    end

    # Starts a background thread that collects every +interval+ seconds from
    # each enabled source (+sensorpush+ and +weather+). Any error is logged as
    # a single timestamped line and the loop continues; the failing source's
    # client is rebuilt (for SensorPush, re-authenticated) on the next
    # iteration. Returns the Thread.
    def self.start(store:, interval: Integer(ENV.fetch("JANUS_POLL_SECONDS", "300")),
                   client_factory: DEFAULT_CLIENT_FACTORY,
                   weather_factory: DEFAULT_WEATHER_FACTORY,
                   sensorpush: true, weather: false, logger_io: $stderr)
      Thread.new do
        client = nil
        weather_client = nil
        loop do
          if sensorpush
            begin
              if client.nil?
                client = client_factory.call
                raise Sensorpush::Error, "SensorPush authentication failed" unless client.authenticate
              end
              Collector.new(client: client, store: store).run_once
            rescue StandardError => e
              client = nil
              logger_io.puts "[#{Time.now.getutc.iso8601}] poller: #{e.class}: #{e.message}"
            end
          end
          if weather
            begin
              weather_client = weather_factory.call if weather_client.nil?
              WeatherCollector.new(weather: weather_client, store: store).run_once
            rescue StandardError => e
              weather_client = nil
              logger_io.puts "[#{Time.now.getutc.iso8601}] poller: weather: #{e.class}: #{e.message}"
            end
          end
          sleep interval
        end
      end
    end

    # Starts polling only when at least one source is configured (SensorPush
    # credentials or an NWS station) and collection is not switched off;
    # otherwise logs why and returns nil. Each source collects only when its
    # own configuration is present.
    def self.start_if_configured(store:, logger_io: $stderr, **options)
      if ENV["JANUS_COLLECT"] == "off"
        logger_io.puts "[#{Time.now.getutc.iso8601}] poller: JANUS_COLLECT=off; not collecting"
        return nil
      end
      sensorpush = !ENV["SENSORPUSH_USERNAME"].to_s.empty? && !ENV["SENSORPUSH_PASSWORD"].to_s.empty?
      weather = !ENV["JANUS_OUTSIDE_STATION"].to_s.empty?
      unless sensorpush || weather
        logger_io.puts "[#{Time.now.getutc.iso8601}] poller: neither SENSORPUSH_USERNAME/SENSORPUSH_PASSWORD nor JANUS_OUTSIDE_STATION is set; not collecting"
        return nil
      end

      start(store: store, logger_io: logger_io, sensorpush: sensorpush, weather: weather, **options)
    end
  end
end
