# ABOUTME: Janus::Weather::Client reads recent observations for one NWS station
# ABOUTME: and presents them as sensorpush-shaped samples (UTC time, °F, % rh).

require "json"
require "net/http"
require "time"
require "uri"

module Janus
  module Weather
    # Carries the HTTP status so the retry ladder can tell rate limiting and
    # server errors (transient) apart from client errors (fatal).
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        @status = status
        super(message)
      end
    end

    # One station observation, duck-typed like a sensorpush sample so
    # Janus::Store#insert_readings accepts it unchanged.
    Observation = Data.define(:observed, :temperature, :humidity)

    class Client
      API_BASE = "https://api.weather.gov"

      # The NWS API keeps at most 7 days of observations at ~19 per day, so a
      # single request at this limit always covers the full history.
      OBSERVATIONS_LIMIT = 500

      # The NWS rejects requests without an identifying User-Agent, so one is
      # always sent; +fetcher+ is a callable (uri, headers) -> [status, body],
      # injectable so tests never touch the network.
      def initialize(station:, user_agent: ENV.fetch("JANUS_NWS_USER_AGENT", "janus-dashboard"),
                     fetcher: nil)
        @station = station
        @user_agent = user_agent
        @fetcher = fetcher || method(:http_fetch)
      end

      def sensor_id
        "nws.#{@station}"
      end

      def sensor_name
        "Outside"
      end

      # Returns observations at or after +since+, oldest first (the API sends
      # newest first). Observations missing a temperature (sensor outage) are
      # skipped; a missing humidity is kept as nil. Raises Janus::Weather::Error
      # on any non-2xx response.
      def observations(since:)
        uri = URI("#{API_BASE}/stations/#{@station}/observations")
        uri.query = URI.encode_www_form(start: since.getutc.iso8601, limit: OBSERVATIONS_LIMIT)
        status, body = @fetcher.call(uri, { "User-Agent" => @user_agent })
        unless (200..299).cover?(status)
          raise Error.new("NWS observations for #{@station} returned HTTP #{status}", status: status)
        end

        parse(body)
      end

      private

      def parse(body)
        features = JSON.parse(body).fetch("features", [])
        features.filter_map do |feature|
          properties = feature.fetch("properties")
          celsius = properties.dig("temperature", "value")
          next if celsius.nil?

          humidity = properties.dig("relativeHumidity", "value")
          Observation.new(
            observed: Time.iso8601(properties.fetch("timestamp")).getutc,
            temperature: (celsius * 9.0 / 5) + 32,
            humidity: humidity&.to_f
          )
        end.sort_by(&:observed)
      end

      def http_fetch(uri, headers)
        response = Net::HTTP.get_response(uri, headers)
        [Integer(response.code, 10), response.body]
      end
    end
  end
end
