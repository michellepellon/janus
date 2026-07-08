# ABOUTME: Janus::App is the Sinatra web layer — health check, the dashboard
# ABOUTME: JSON API, and the static single-page frontend.

require "sinatra/base"
require "json"
require "time"
require_relative "store"

module Janus
  class App < Sinatra::Base
    ALLOWED_HOURS = [24, 72, 168, 720].freeze
    DEFAULT_HOURS = 24

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

      sensors = self.class.store.dashboard(hours: hours).map { |row| serialize_sensor(row) }
      JSON.generate(
        generated_at: Time.now.getutc.iso8601,
        hours: hours,
        sensors: sensors
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

    def round1(value)
      value&.round(1)
    end
  end
end
