# ABOUTME: Janus::App is the Sinatra web layer — health check, the dashboard
# ABOUTME: JSON API, and the static single-page frontend.

require "sinatra/base"
require "json"
require "time"
require_relative "store"
require_relative "event_log"
require_relative "commander"
require_relative "hue"
require_relative "dew_point"

module Janus
  class App < Sinatra::Base
    ALLOWED_HOURS = [24, 72, 168, 720].freeze
    DEFAULT_HOURS = 24

    # Free cooling means opening windows beats running the AC: outside air
    # must be cooler than the house AND dry enough to be worth letting in.
    # Above a dew point of about 63°F air starts to feel muggy and adds
    # latent load, so that is the comfort ceiling.
    FREE_COOLING_MAX_DEW_POINT = 63.0

    # Outside readings come from NWS pseudo-sensors named nws.<station>.
    OUTSIDE_ID_PREFIX = "nws."

    set :public_folder, File.expand_path("../../public", __dir__)
    # Assets revalidate on every load (conditional GET); without this the
    # browser's heuristic caching serves stale JS/CSS after an upgrade.
    set :static_cache_control, :no_cache

    # Returns the shared Store, opening it on first use. `set :store, ...`
    # replaces this lazy definition with a plain getter, so tests can inject
    # their own store (or point JANUS_DB_PATH elsewhere) before first use.
    def self.store
      set :store, Store.new(path: ENV.fetch("JANUS_DB_PATH", "data/janus.duckdb"))
      settings.store
    end

    # The shared EventLog over the same store, lazily opened the same way so
    # tests can inject their own before first use.
    def self.event_log
      set :event_log, EventLog.new(store: store)
      settings.event_log
    end

    # The shared Commander over the same event log, wired to a Hue client only
    # when the bridge is configured (otherwise control routes answer 409).
    # Lazily built and injectable exactly like store/event_log.
    def self.commander
      set :commander, Commander.new(hue: hue_client, event_log: event_log)
      settings.commander
    end

    # A Hue client from the environment, or nil when the bridge credentials are
    # absent — the honest "control is not configured" signal.
    def self.hue_client
      ip = ENV["HUE_BRIDGE_IP"].to_s
      key = ENV["HUE_APP_KEY"].to_s
      return nil if ip.empty? || key.empty?

      Hue::Client.new(bridge_ip: ip, app_key: key)
    end

    get "/healthz" do
      content_type "text/plain"
      "ok"
    end

    get "/api/dashboard" do
      content_type "application/json"
      hours = parse_hours(params["hours"])
      if hours.nil?
        status 400
        return JSON.generate(error: "hours must be one of #{ALLOWED_HOURS.join(", ")}")
      end

      rows = self.class.store.dashboard(hours: hours)
      JSON.generate(
        generated_at: Time.now.getutc.iso8601,
        hours: hours,
        sensors: rows.map { |row| serialize_sensor(row) },
        cooling: serialize_cooling(rows, hours),
        devices: serialize_devices(hours)
      )
    end

    # Issues a light on/off command. The 2xx here means the bridge accepted the
    # PUT (status 'pending'); the dashboard confirms it against the observed
    # state event via GET /api/commands/:id.
    post "/api/devices/:id/toggle" do
      content_type "application/json"
      on = parse_toggle_body(request)
      if on.nil?
        status 400
        return JSON.generate(error: "body must be {\"on\": true} or {\"on\": false}")
      end
      unless self.class.store.devices.any? { |device| device[:id] == params["id"] }
        status 404
        return JSON.generate(error: "unknown device")
      end

      begin
        result = self.class.commander.toggle(entity: params["id"], on: on)
        JSON.generate(command_id: result[:command_id], status: result[:status], on: result[:on])
      rescue Commander::NotConfigured
        status 409
        JSON.generate(error: "lights control is not configured")
      rescue Commander::UnknownEntity
        status 404
        JSON.generate(error: "unknown device")
      rescue Commander::TransportError => e
        status 502
        JSON.generate(error: "the bridge rejected the command", status: e.status)
      end
    end

    # A single command's status for pending -> confirmed/failed polling.
    # Reconciles first so a confirming state event that has already arrived is
    # reflected without waiting for the poller.
    get "/api/commands/:id" do
      content_type "application/json"
      unless params["id"].match?(/\A\d+\z/)
        status 404
        return JSON.generate(error: "unknown command")
      end

      self.class.commander.reconcile_pending(now: Time.now.getutc)
      cmd = self.class.event_log.command(Integer(params["id"], 10))
      if cmd.nil?
        status 404
        return JSON.generate(error: "unknown command")
      end
      JSON.generate(serialize_command(cmd))
    end

    get "/" do
      cache_control :no_cache
      send_file File.join(settings.public_folder, "index.html")
    end

    private

    # The requested on-state from a toggle body, or nil when the body is not
    # {"on": true|false} — no coercion, so a bad request fails loudly (400).
    def parse_toggle_body(request)
      parsed = JSON.parse(request.body.read)
      return nil unless parsed.is_a?(Hash)

      on = parsed["on"]
      on if on == true || on == false
    rescue JSON::ParserError
      nil
    end

    def serialize_command(cmd)
      {
        id: cmd[:id],
        entity: cmd[:entity],
        on: cmd[:on],
        status: cmd[:status],
        requested_at: cmd[:requested_at]&.iso8601,
        resolved_at: cmd[:resolved_at]&.iso8601,
        detail: cmd[:detail]
      }
    end

    def parse_hours(raw)
      return DEFAULT_HOURS if raw.nil?
      return nil unless raw.match?(/\A\d+\z/)

      hours = Integer(raw, 10)
      ALLOWED_HOURS.include?(hours) ? hours : nil
    end

    def serialize_sensor(row)
      {
        id: row[:id],
        name: row[:name],
        active: row[:active],
        battery_percentage: row[:battery_percentage],
        latest: serialize_latest(row[:latest]),
        range: serialize_range(row[:range]),
        series: row[:series].map do |point|
          { t: point[:t].iso8601, temp: round1(point[:temp]), hum: round1(point[:hum]) }
        end
      }
    end

    def serialize_latest(latest)
      return nil if latest.nil?

      {
        observed: latest[:observed].iso8601,
        temperature: round1(latest[:temperature]),
        humidity: round1(latest[:humidity])
      }
    end

    def serialize_range(range)
      return nil if range.nil?

      {
        temp_min: round1(range[:temp_min]),
        temp_max: round1(range[:temp_max]),
        hum_min: round1(range[:hum_min]),
        hum_max: round1(range[:hum_max])
      }
    end

    # The cooling strip payload: nil when there is no outside sensor or the
    # outside and indoor series never share a bucket; otherwise the latest
    # differential ("now" — itself nil when either side lacks a recent
    # reading) plus the bucketed delta series.
    def serialize_cooling(rows, hours)
      return nil if rows.none? { |row| outside?(row[:id]) }

      series = self.class.store.differential(hours: hours)
      return nil if series.empty?

      {
        now: serialize_cooling_now(rows, hours),
        series: series.map { |point| { t: point[:t].iso8601, delta: round1(point[:delta]) } }
      }
    end

    def serialize_cooling_now(rows, hours)
      outside = self.class.store.latest_outside(hours: hours)
      return nil if outside.nil? || outside[:temperature].nil?

      # House temperature is the mean of each indoor sensor's latest reading
      # within the window, reusing the per-sensor latests already fetched.
      indoor = rows.reject { |row| outside?(row[:id]) }
                   .filter_map { |row| row[:latest]&.fetch(:temperature) }
      return nil if indoor.empty?

      house = indoor.sum / indoor.size
      delta = outside[:temperature] - house
      dew_point = DewPoint.fahrenheit(temperature: outside[:temperature], humidity: outside[:humidity])
      {
        outside_temp: round1(outside[:temperature]),
        house_temp: round1(house),
        delta: round1(delta),
        dew_point: round1(dew_point),
        free_cooling: delta.negative? && !dew_point.nil? && dew_point <= FREE_COOLING_MAX_DEW_POINT
      }
    end

    # Devices with their windowed on/off journal. Always an array; empty until
    # a source (Hue today) has registered devices — the frontend hides the
    # module entirely then. Intervals are looked up for every entity at once
    # and joined by device id; a device with no state events gets on: nil and
    # no intervals. Absence of events is unknown, never "off".
    def serialize_devices(hours)
      devices = self.class.store.devices
      return [] if devices.empty?

      intervals_by_entity = self.class.event_log.state_intervals(entity_prefix: "", hours: hours)
      devices.map do |device|
        latest = self.class.event_log.latest_state(entity: device[:id])
        command = self.class.event_log.latest_command(entity: device[:id])
        {
          id: device[:id],
          name: device[:name],
          room: device[:room],
          kind: device[:kind],
          on: latest && latest[:on],
          pending: command ? command[:status] == "pending" : false,
          last_command: serialize_last_command(command),
          intervals: (intervals_by_entity[device[:id]] || []).map do |interval|
            { from: interval[:from].iso8601, to: interval[:to].iso8601, on: interval[:on] }
          end
        }
      end
    end

    # The most recent command's shape for the dashboard, so a reload reflects
    # in-flight or last control state, or nil when a device was never commanded.
    def serialize_last_command(command)
      return nil if command.nil?

      {
        on: command[:on],
        status: command[:status],
        requested_at: command[:requested_at]&.iso8601,
        resolved_at: command[:resolved_at]&.iso8601
      }
    end

    def outside?(sensor_id)
      sensor_id.start_with?(OUTSIDE_ID_PREFIX)
    end

    def round1(value)
      value&.round(1)
    end
  end
end
