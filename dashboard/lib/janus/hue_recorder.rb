# ABOUTME: Janus::HueRecorder reconciles bridge light state into the devices
# ABOUTME: registry and event log, and records live SSE updates as they arrive.

require "time"
require_relative "hue"
require_relative "retries"

module Janus
  class HueRecorder
    include Retries

    SOURCE = "hue"

    def initialize(hue:, store:, event_log:, sleeper: ->(seconds) { sleep(seconds) })
      @hue = hue
      @store = store
      @event_log = event_log
      @sleeper = sleeper
    end

    # Fetches every light, upserts the devices registry, and records a state
    # event for any light whose on-state differs from the last recorded state
    # (or that has none). Returns { devices:, state_events: }.
    def run_once
      lights = with_retries { @hue.lights }
      state_events = 0
      lights.each do |light|
        entity = Hue.entity_id(light[:id])
        @store.upsert_device(
          id: entity, name: light[:name], room: light[:room],
          kind: light[:kind], source: SOURCE, reachable: light[:reachable]
        )
        state_events += 1 if record_state(entity, light[:on], Time.now.getutc)
      end
      { devices: lights.size, state_events: state_events }
    end

    # Follows the bridge's SSE feed on a daemon thread, recording state
    # events as they arrive; the periodic run_once reconcile repairs anything
    # missed. Drops reconnect through the Retries backoff ladder, holding at
    # its top rung while the bridge stays away. Returns the Thread.
    def start_stream(logger_io: $stderr)
      Thread.new do
        attempt = 0
        loop do
          io = nil
          begin
            io = @hue.open_event_stream
            attempt = 0
            @hue.each_event(io: io) do |event|
              record_state(event[:entity], event[:on], event[:observed])
            end
            raise Hue::Error, "event stream ended"
          rescue StandardError => e
            logger_io.puts "[#{Time.now.getutc.iso8601}] hue stream: #{e.class}: #{e.message}"
            @sleeper.call(Retries::BACKOFF_SECONDS[[attempt, Retries::BACKOFF_SECONDS.size - 1].min])
            attempt += 1
          ensure
            io.close if io.respond_to?(:close) && !io.closed?
          end
        end
      end
    end

    private

    # Records a state event only when it differs from the last recorded state,
    # so the journal is a change history rather than a polling echo. Returns
    # whether an event was written.
    def record_state(entity, on, observed)
      return false if on.nil?

      last = @event_log.latest_state(entity: entity)
      return false if last && last[:on] == on

      @event_log.record(observed: observed, source: SOURCE, entity: entity,
                        kind: "state", payload: { on: on })
      true
    end
  end
end
