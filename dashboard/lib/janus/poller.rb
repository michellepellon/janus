# ABOUTME: Janus::Poller runs SensorPush, NWS weather, and Hue collection on a
# ABOUTME: background thread so exactly one process ever writes the DuckDB file.

require "sensorpush"
require "time"
require_relative "collector"
require_relative "weather"
require_relative "weather_collector"
require_relative "hue"
require_relative "hue_recorder"
require_relative "commander"
require_relative "schedule_runner"

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

    DEFAULT_HUE_FACTORY = proc do
      Hue::Client.new(bridge_ip: ENV.fetch("HUE_BRIDGE_IP"), app_key: ENV.fetch("HUE_APP_KEY"))
    end

    # Starts a background thread that collects every +interval+ seconds from
    # each enabled source (+sensorpush+, +weather+, and +hue+). Any error is
    # logged as a single timestamped line and the loop continues; the failing
    # source's client is rebuilt (for SensorPush, re-authenticated) on the
    # next iteration. When an +event_log+ is given, each successful collection
    # appends one audit event (source 'janus', kind 'collection') with the
    # collector's counts. Hue additionally follows the bridge's SSE feed on
    # its own thread (see HueRecorder#start_stream); that thread manages its
    # own reconnects, so it is started once and left alone. When +schedules+
    # is given, each hue cycle also runs schedule enforcement and adherence
    # (see ScheduleRunner) through a Commander wired to the bridge. Returns
    # the Thread.
    def self.start(store:, event_log: nil, schedules: nil,
                   interval: Integer(ENV.fetch("JANUS_POLL_SECONDS", "300")),
                   client_factory: DEFAULT_CLIENT_FACTORY,
                   weather_factory: DEFAULT_WEATHER_FACTORY,
                   hue_factory: DEFAULT_HUE_FACTORY,
                   sensorpush: true, weather: false, hue: false, hue_stream: true,
                   logger_io: $stderr)
      raise ArgumentError, "hue collection requires an event_log" if hue && event_log.nil?

      Thread.new do
        client = nil
        weather_client = nil
        hue_recorder = nil
        hue_stream_thread = nil
        commander = nil
        schedule_runner = nil
        loop do
          if sensorpush
            begin
              if client.nil?
                client = client_factory.call
                raise Sensorpush::Error, "SensorPush authentication failed" unless client.authenticate
              end
              result = Collector.new(client: client, store: store).run_once
              record_collection(event_log, "sensorpush", result)
            rescue StandardError => e
              client = nil
              logger_io.puts "[#{Time.now.getutc.iso8601}] poller: #{e.class}: #{e.message}"
            end
          end
          if weather
            begin
              weather_client = weather_factory.call if weather_client.nil?
              result = WeatherCollector.new(weather: weather_client, store: store).run_once
              record_collection(event_log, "weather", result)
            rescue StandardError => e
              weather_client = nil
              logger_io.puts "[#{Time.now.getutc.iso8601}] poller: weather: #{e.class}: #{e.message}"
            end
          end
          if hue
            begin
              if hue_recorder.nil?
                hue_client = hue_factory.call
                hue_recorder = HueRecorder.new(hue: hue_client, store: store, event_log: event_log)
                hue_stream_thread ||= hue_recorder.start_stream(logger_io: logger_io) if hue_stream
                # The runner keeps in-memory edge/mismatch state, so it is
                # built once (with the first bridge client) and kept across
                # hue rebuilds; its own per-device rescue contains errors.
                if schedules && schedule_runner.nil?
                  schedule_runner = ScheduleRunner.new(
                    schedules: schedules, event_log: event_log, logger_io: logger_io,
                    commander: Commander.new(hue: hue_client, event_log: event_log, source: "schedule")
                  )
                end
              end
              result = hue_recorder.run_once
              record_collection(event_log, "hue", result)
              # Resolve any pending commands against the observed record, so a
              # stale pending fails on the timeout even without a live SSE
              # confirmation. reconcile needs no bridge, only the event log.
              commander ||= Commander.new(hue: nil, event_log: event_log)
              reconciled = commander.reconcile_pending(now: Time.now.getutc)
              if reconciled[:confirmed].positive? || reconciled[:failed].positive?
                logger_io.puts "[#{Time.now.getutc.iso8601}] poller: hue commands " \
                               "confirmed=#{reconciled[:confirmed]} failed=#{reconciled[:failed]}"
              end
              # Schedule times are local wall clock, so the runner evaluates
              # in the server's zone.
              schedule_runner&.run_cycle(now: Time.now)
            rescue StandardError => e
              hue_recorder = nil
              logger_io.puts "[#{Time.now.getutc.iso8601}] poller: hue: #{e.class}: #{e.message}"
            end
          end
          sleep interval
        end
      end
    end

    # Starts polling only when at least one source is configured (SensorPush
    # credentials, an NWS station, or Hue bridge credentials) and collection
    # is not switched off; otherwise logs why and returns nil. Each source
    # collects only when its own configuration is present; an unconfigured
    # Hue bridge is noted once so the missing journal is never a mystery.
    def self.start_if_configured(store:, event_log: nil, logger_io: $stderr, **options)
      if ENV["JANUS_COLLECT"] == "off"
        logger_io.puts "[#{Time.now.getutc.iso8601}] poller: JANUS_COLLECT=off; not collecting"
        return nil
      end
      sensorpush = !ENV["SENSORPUSH_USERNAME"].to_s.empty? && !ENV["SENSORPUSH_PASSWORD"].to_s.empty?
      weather = !ENV["JANUS_OUTSIDE_STATION"].to_s.empty?
      hue = !ENV["HUE_BRIDGE_IP"].to_s.empty? && !ENV["HUE_APP_KEY"].to_s.empty?
      unless sensorpush || weather || hue
        logger_io.puts "[#{Time.now.getutc.iso8601}] poller: none of SENSORPUSH_USERNAME/SENSORPUSH_PASSWORD, " \
                       "JANUS_OUTSIDE_STATION, or HUE_BRIDGE_IP/HUE_APP_KEY is set; not collecting"
        return nil
      end
      unless hue
        logger_io.puts "[#{Time.now.getutc.iso8601}] poller: HUE_BRIDGE_IP/HUE_APP_KEY not set; skipping hue collection"
      end

      start(store: store, event_log: event_log, logger_io: logger_io,
            sensorpush: sensorpush, weather: weather, hue: hue, **options)
    end

    # One audit event per collector per cycle, so the journal shows that
    # collection ran (and how much it gathered) even when nothing changed.
    def self.record_collection(event_log, collector, counts)
      return if event_log.nil?

      event_log.record(observed: Time.now.getutc, source: "janus", entity: collector,
                       kind: "collection", payload: counts)
    end
    private_class_method :record_collection
  end
end
