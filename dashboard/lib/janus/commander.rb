# ABOUTME: Janus::Commander issues light on/off commands and reconciles them —
# ABOUTME: a command is confirmed by an observed state event, never by the 2xx PUT.

require "time"
require_relative "hue"
require_relative "event_log"

module Janus
  class Commander
    # Control was asked for while the Hue bridge is unconfigured — the app maps
    # this to 409 rather than pretending the command was accepted.
    class NotConfigured < StandardError; end

    # The entity id does not name a controllable Hue light.
    class UnknownEntity < StandardError; end

    # The bridge rejected the PUT. Carries the bridge's HTTP status (for the
    # app to echo) and the id of the command already resolved failed.
    class TransportError < StandardError
      attr_reader :status, :command_id

      def initialize(message, status: nil, command_id: nil)
        @status = status
        @command_id = command_id
        super(message)
      end
    end

    # Default seconds a command may stay pending before an unconfirmed one is
    # resolved failed. A command confirms the instant a matching state event
    # arrives; this only bounds the wait when none ever does.
    DEFAULT_TIMEOUT_SECONDS = 30

    def initialize(hue:, event_log:, source: "dashboard")
      @hue = hue
      @event_log = event_log
      @source = source
    end

    # Whether control is available at all (a configured bridge). The app reads
    # this to decide 409 before touching the ledger.
    def configured?
      !@hue.nil?
    end

    # Records a pending command, sends the on/off PUT, and — on transport
    # success — leaves the command pending, stamped "accepted": the bridge's
    # acceptance is not the change taking effect. Confirmation arrives later as
    # an observed state event (see reconcile_pending). Returns
    # { command_id:, status:, on: }. Raises NotConfigured, UnknownEntity, or
    # TransportError (the last after resolving the command failed).
    def toggle(entity:, on:)
      raise NotConfigured, "lights control is not configured" unless configured?

      rid = rid_for(entity)
      raise UnknownEntity, "#{entity} is not a controllable light" if rid.nil? || rid.empty?

      id = @event_log.request(entity: entity, action: { on: on }, source: @source)
      begin
        @hue.set_light(rid, on: on)
      rescue Hue::Error => e
        @event_log.resolve(id, status: "failed", detail: transport_detail(e))
        raise TransportError.new(e.message, status: e.status, command_id: id)
      end
      @event_log.stamp(id, detail: "accepted")
      { command_id: id, status: "pending", on: on }
    end

    # Resolves open commands against the observed record: a pending command with
    # a matching state event at or after its request confirms; one past
    # +timeout_seconds+ with none fails "no confirmation". Everything else stays
    # pending. Cheap when nothing is open. Returns { confirmed:, failed: }.
    def reconcile_pending(now: Time.now.getutc, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
      confirmed = 0
      failed = 0
      @event_log.pending_commands.each do |cmd|
        observed = @event_log.confirming_state(entity: cmd[:entity], on: cmd[:on], since: cmd[:requested_at])
        if observed
          @event_log.resolve(cmd[:id], status: "confirmed", detail: "observed at #{observed.iso8601}")
          confirmed += 1
        elsif now - cmd[:requested_at] > timeout_seconds
          @event_log.resolve(cmd[:id], status: "failed", detail: "no confirmation")
          failed += 1
        end
      end
      { confirmed: confirmed, failed: failed }
    end

    private

    # The bare light uuid from a "hue.light.<uuid>" entity id, or nil when the
    # entity is not a Hue light.
    def rid_for(entity)
      return nil unless entity.to_s.start_with?(Hue::ENTITY_PREFIX)

      entity[Hue::ENTITY_PREFIX.length..]
    end

    def transport_detail(error)
      [error.status, error.message].compact.join(": ")
    end
  end
end
