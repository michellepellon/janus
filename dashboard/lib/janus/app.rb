# ABOUTME: Janus::App is the Sinatra web layer — health check, the dashboard
# ABOUTME: JSON API, and the static single-page frontend.

require "sinatra/base"
require "json"
require "time"
require_relative "store"
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
        cooling: serialize_cooling(rows, hours)
      )
    end

    get "/" do
      cache_control :no_cache
      send_file File.join(settings.public_folder, "index.html")
    end

    private

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

    def outside?(sensor_id)
      sensor_id.start_with?(OUTSIDE_ID_PREFIX)
    end

    def round1(value)
      value&.round(1)
    end
  end
end
