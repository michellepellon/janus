# ABOUTME: Janus::Hue talks CLIP v2 to a Philips Hue bridge — pairing, the
# ABOUTME: light/device/room join, light control, and the SSE event parser.

require "json"
require "net/http"
require "openssl"
require "socket"
require "time"
require "uri"

module Janus
  module Hue
    # Carries the HTTP status so the retry ladder can tell rate limiting and
    # server errors (transient) apart from client errors (fatal).
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        @status = status
        super(message)
      end
    end

    # Pairing was attempted before the bridge's physical link button was
    # pressed (CLIP error type 101).
    class LinkButtonNotPressed < Error; end

    # The devicetype the bridge records against the issued app key.
    DEVICE_TYPE = "janus#dashboard"

    # CLIP error type meaning the link button has not been pressed yet.
    LINK_BUTTON_ERROR_TYPE = 101

    # Device entity ids as stored in devices/events: hue.light.<uuid>.
    ENTITY_PREFIX = "hue.light."

    # Signify's cloud broker that reports bridges on the local network.
    DISCOVERY_URI = URI("https://discovery.meethue.com/")

    module_function

    def entity_id(uuid)
      "#{ENTITY_PREFIX}#{uuid}"
    end

    # Requests an application key from the bridge. Succeeds only after the
    # physical link button has been pressed; before that the bridge answers
    # CLIP error 101, raised as LinkButtonNotPressed. Returns the app key.
    def pair(ip:, fetcher: Http.method(:bridge_request))
      body = JSON.generate(devicetype: DEVICE_TYPE, generateclientkey: true)
      status, response = fetcher.call(:post, URI("https://#{ip}/api"), {}, body)
      unless (200..299).cover?(status)
        raise Error.new("hue pairing returned HTTP #{status}", status: status)
      end

      entry = JSON.parse(response).first || {}
      if (error = entry["error"])
        raise LinkButtonNotPressed, error["description"] if error["type"] == LINK_BUTTON_ERROR_TYPE

        raise Error, "hue pairing failed: #{error["description"]}"
      end
      entry.fetch("success").fetch("username")
    end

    # Polls pair() every +interval+ seconds until the link button is pressed
    # or +timeout+ seconds elapse (raising the final LinkButtonNotPressed).
    # +on_wait+ runs after each unanswered poll so callers can show progress.
    def wait_for_pairing(ip:, fetcher: Http.method(:bridge_request), interval: 2, timeout: 90,
                         sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now },
                         on_wait: proc {})
      deadline = clock.call + timeout
      begin
        pair(ip: ip, fetcher: fetcher)
      rescue LinkButtonNotPressed
        raise if clock.call + interval > deadline

        on_wait.call
        sleeper.call(interval)
        retry
      end
    end

    # The first bridge IP reported by Signify's discovery endpoint, or nil
    # when none is registered on this network.
    def discover(fetcher: Http.method(:request))
      status, body = fetcher.call(:get, DISCOVERY_URI, {})
      unless (200..299).cover?(status)
        raise Error.new("hue discovery returned HTTP #{status}", status: status)
      end

      JSON.parse(body).first&.fetch("internalipaddress", nil)
    end

    # Default HTTPS transport, shaped (method, uri, headers, body) ->
    # [status, body] and injectable so tests never touch the network.
    module Http
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      module_function

      # Certificate-verified request, for the public discovery endpoint.
      def request(method, uri, headers, body = nil)
        perform(method, uri, headers, body, OpenSSL::SSL::VERIFY_PEER)
      end

      # Bridge request. The bridge serves a Signify-signed certificate that
      # stock roots reject, so verification is disabled: the connection is
      # LAN-local, and pinning the bridge's certificate is future hardening.
      def bridge_request(method, uri, headers, body = nil)
        perform(method, uri, headers, body, OpenSSL::SSL::VERIFY_NONE)
      end

      def perform(method, uri, headers, body, verify_mode)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = verify_mode
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        response = http.send_request(method.to_s.upcase, uri.request_uri, body, headers)
        [Integer(response.code, 10), response.body]
      end
      private_class_method :perform
    end

    # Yields de-chunked lines from an HTTP/1.1 chunked response body. The
    # bridge streams its SSE feed with Transfer-Encoding: chunked, so chunk
    # size lines and chunk-boundary CRLFs must be stripped before the SSE
    # parser sees the payload (a bare boundary CRLF would read as an SSE
    # dispatch). Partial lines are carried across chunk boundaries.
    class ChunkedIO
      def initialize(io)
        @io = io
      end

      def close
        @io.close
      end

      def closed?
        @io.closed?
      end

      def each_line
        pending = +""
        loop do
          size_line = @io.readline
          size = Integer(size_line.strip, 16)
          break if size.zero?

          pending << @io.read(size)
          @io.read(2) # the CRLF closing the chunk
          while (newline = pending.index("\n"))
            yield pending.slice!(0..newline)
          end
        end
        yield pending unless pending.empty?
      rescue EOFError
        yield pending unless pending.empty?
      end
    end

    class Client
      RESOURCE_PATH = "/clip/v2/resource"
      EVENT_STREAM_PATH = "/eventstream/clip/v2"

      def initialize(bridge_ip:, app_key:, fetcher: Http.method(:bridge_request))
        @bridge_ip = bridge_ip
        @app_key = app_key
        @fetcher = fetcher
      end

      # Every light service joined with its owning device and containing room:
      # [{id:, name:, room:, kind:, on:, reachable:}]. kind is "plug" for the
      # smart-outlet archetype, otherwise "light". reachable is nil — CLIP v2
      # reports reachability on the zigbee_connectivity resource, which this
      # client does not fetch yet.
      def lights
        devices = resource("device").to_h { |device| [device["id"], device] }
        room_names = room_names_by_device(resource("room"))

        resource("light").map do |light|
          owner_id = light.dig("owner", "rid")
          device = devices[owner_id]
          {
            id: light.fetch("id"),
            name: light.dig("metadata", "name") || device&.dig("metadata", "name"),
            room: room_names[owner_id],
            kind: light.dig("metadata", "archetype") == "plug" ? "plug" : "light",
            on: light.dig("on", "on"),
            reachable: nil
          }
        end
      end

      # Turns one light or plug on or off. A 2xx means the bridge accepted the
      # request, not that the change has taken effect — the commander confirms
      # against the observed state event, not this return.
      def set_light(id, on:)
        status, body = @fetcher.call(
          :put, uri("#{RESOURCE_PATH}/light/#{id}"), headers, JSON.generate(on: { on: on })
        )
        check!(status, body, "light #{id}")
        nil
      end

      # Parses a CLIP v2 server-sent-events stream from +io+ (any object with
      # each_line), yielding {entity:, on:, observed:} for every light on/off
      # update. Keepalive comments, non-update frames, and non-light data are
      # tolerated and skipped.
      def each_event(io:, &block)
        data_lines = []
        io.each_line do |line|
          line = line.chomp
          if line.empty?
            dispatch_event(data_lines.join("\n"), &block) unless data_lines.empty?
            data_lines = []
          elsif line.start_with?("data:")
            data_lines << line.sub(/\Adata: ?/, "")
          end
          # "id:", "event:", and ": keepalive" comment lines carry no payload.
        end
        dispatch_event(data_lines.join("\n"), &block) unless data_lines.empty?
        nil
      end

      # Opens the bridge's SSE feed and returns a line-yielding IO for
      # each_event. Real socket work lives here (and only here); everything
      # above it is exercised against canned transcripts.
      def open_event_stream
        socket = connect_tls
        socket.write(
          "GET #{EVENT_STREAM_PATH} HTTP/1.1\r\n" \
          "Host: #{@bridge_ip}\r\n" \
          "hue-application-key: #{@app_key}\r\n" \
          "Accept: text/event-stream\r\n" \
          "Connection: keep-alive\r\n\r\n"
        )
        status_line = socket.readline
        status = Integer(status_line.split(" ")[1], 10)
        chunked = false
        loop do
          line = socket.readline.chomp
          break if line.empty?

          chunked = true if line.match?(/\Atransfer-encoding:\s*chunked\z/i)
        end
        unless status == 200
          socket.close
          raise Error.new("hue event stream returned HTTP #{status}", status: status)
        end

        chunked ? ChunkedIO.new(socket) : socket
      end

      private

      def resource(type)
        status, body = @fetcher.call(:get, uri("#{RESOURCE_PATH}/#{type}"), headers)
        check!(status, body, type)
        payload = JSON.parse(body)
        errors = payload.fetch("errors", [])
        unless errors.empty?
          raise Error, "hue #{type} returned errors: #{errors.map { |e| e["description"] }.join("; ")}"
        end

        payload.fetch("data", [])
      end

      # Room name keyed by the device id of each child.
      def room_names_by_device(rooms)
        rooms.each_with_object({}) do |room, names|
          room.fetch("children", []).each do |child|
            names[child["rid"]] = room.dig("metadata", "name") if child["rtype"] == "device"
          end
        end
      end

      def dispatch_event(data, &block)
        frames = JSON.parse(data)
        return unless frames.is_a?(Array)

        frames.each do |frame|
          next unless frame["type"] == "update"

          observed = Time.iso8601(frame.fetch("creationtime")).getutc
          frame.fetch("data", []).each do |item|
            on = item.dig("on", "on")
            next unless item["type"] == "light" && !on.nil?

            block.call(entity: Hue.entity_id(item.fetch("id")), on: on, observed: observed)
          end
        end
      rescue JSON::ParserError, KeyError, ArgumentError
        # A malformed frame must not kill the stream; the next reconcile
        # cycle repairs any state it carried.
      end

      def connect_tls
        tcp = TCPSocket.new(@bridge_ip, 443)
        context = OpenSSL::SSL::SSLContext.new
        # LAN-local bridge with a Signify-signed certificate; see Http above.
        context.verify_mode = OpenSSL::SSL::VERIFY_NONE
        socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
        socket.sync_close = true
        socket.connect
        socket
      end

      def uri(path)
        URI("https://#{@bridge_ip}#{path}")
      end

      def headers
        { "hue-application-key" => @app_key }
      end

      def check!(status, body, context)
        return if (200..299).cover?(status)

        raise Error.new("hue #{context} returned HTTP #{status}: #{body.to_s[0, 200]}", status: status)
      end
    end
  end
end
