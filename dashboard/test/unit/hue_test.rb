# ABOUTME: Unit tests for Janus::Hue — pairing (link button, success, errors),
# ABOUTME: discovery, the light/device/room join, control, and the SSE parser.

require_relative "../test_helper"
require "janus/hue"
require "json"
require "stringio"
require "time"

class HueTest < Minitest::Test
  include JanusTestHelpers

  BRIDGE_IP = "192.168.1.50"
  APP_KEY = "test-app-key"

  # Fetcher stub: records every (method, uri, headers, body) call and serves
  # canned [status, body] responses keyed by path, or a fixed response.
  class StubFetcher
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(method, uri, headers, body = nil)
      @calls << [method, uri, headers, body]
      response = @responses.is_a?(Hash) ? @responses.fetch(uri.path) : @responses
      response.is_a?(Array) && response.first.is_a?(Integer) ? response : [200, JSON.generate(response)]
    end
  end

  LINK_BUTTON_BODY = JSON.generate(
    [{ "error" => { "type" => 101, "address" => "", "description" => "link button not pressed" } }]
  )
  PAIR_SUCCESS_BODY = JSON.generate(
    [{ "success" => { "username" => "fresh-app-key", "clientkey" => "0123ABCD" } }]
  )

  # -- pairing ---------------------------------------------------------------

  def test_pair_raises_link_button_not_pressed_on_error_101
    fetcher = StubFetcher.new([200, LINK_BUTTON_BODY])
    error = assert_raises(Janus::Hue::LinkButtonNotPressed) do
      Janus::Hue.pair(ip: BRIDGE_IP, fetcher: fetcher)
    end
    assert_match(/link button/, error.message)

    method, uri, _headers, body = fetcher.calls.first
    assert_equal :post, method
    assert_equal "https://#{BRIDGE_IP}/api", uri.to_s
    assert_equal({ "devicetype" => "janus#dashboard", "generateclientkey" => true }, JSON.parse(body))
  end

  def test_pair_returns_app_key_after_button_press
    fetcher = StubFetcher.new([200, PAIR_SUCCESS_BODY])
    assert_equal "fresh-app-key", Janus::Hue.pair(ip: BRIDGE_IP, fetcher: fetcher)
  end

  def test_pair_raises_hue_error_on_other_clip_errors
    body = JSON.generate([{ "error" => { "type" => 7, "description" => "invalid value" } }])
    error = assert_raises(Janus::Hue::Error) do
      Janus::Hue.pair(ip: BRIDGE_IP, fetcher: StubFetcher.new([200, body]))
    end
    assert_match(/invalid value/, error.message)
  end

  def test_pair_raises_with_status_on_non_2xx
    error = assert_raises(Janus::Hue::Error) do
      Janus::Hue.pair(ip: BRIDGE_IP, fetcher: StubFetcher.new([503, "sad bridge"]))
    end
    assert_equal 503, error.status
  end

  def test_wait_for_pairing_polls_until_the_button_is_pressed
    responses = [[200, LINK_BUTTON_BODY], [200, LINK_BUTTON_BODY], [200, PAIR_SUCCESS_BODY]]
    calls = 0
    fetcher = proc do |_method, _uri, _headers, _body|
      calls += 1
      responses.shift
    end
    naps = []
    waits = 0
    fake_now = Time.utc(2026, 7, 8, 12, 0, 0)

    key = Janus::Hue.wait_for_pairing(
      ip: BRIDGE_IP, fetcher: fetcher, interval: 2, timeout: 90,
      sleeper: ->(seconds) { naps << seconds; fake_now += seconds },
      clock: -> { fake_now }, on_wait: -> { waits += 1 }
    )

    assert_equal "fresh-app-key", key
    assert_equal 3, calls
    assert_equal [2, 2], naps
    assert_equal 2, waits
  end

  def test_wait_for_pairing_gives_up_at_the_deadline
    fetcher = proc { |*| [200, LINK_BUTTON_BODY] }
    fake_now = Time.utc(2026, 7, 8, 12, 0, 0)
    polls = 0

    assert_raises(Janus::Hue::LinkButtonNotPressed) do
      Janus::Hue.wait_for_pairing(
        ip: BRIDGE_IP, fetcher: proc { |*args| polls += 1; fetcher.call(*args) },
        interval: 2, timeout: 90,
        sleeper: ->(seconds) { fake_now += seconds }, clock: -> { fake_now }
      )
    end
    assert_equal 46, polls, "one poll per 2 s across 90 s, endpoints inclusive"
  end

  # -- discovery -------------------------------------------------------------

  def test_discover_returns_the_first_bridge_ip
    fetcher = StubFetcher.new([200, JSON.generate([{ "id" => "abc", "internalipaddress" => "10.0.0.7" }])])
    assert_equal "10.0.0.7", Janus::Hue.discover(fetcher: fetcher)
    method, uri, = fetcher.calls.first
    assert_equal :get, method
    assert_equal "https://discovery.meethue.com/", uri.to_s
  end

  def test_discover_returns_nil_when_no_bridge_is_registered
    assert_nil Janus::Hue.discover(fetcher: StubFetcher.new([200, "[]"]))
  end

  def test_discover_raises_with_status_on_non_2xx
    error = assert_raises(Janus::Hue::Error) do
      Janus::Hue.discover(fetcher: StubFetcher.new([429, "slow down"]))
    end
    assert_equal 429, error.status
  end

  # -- resources -------------------------------------------------------------

  LIGHT_UUID = "11111111-2222-3333-4444-555555555555"
  PLUG_UUID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
  LIGHT_DEVICE = "d1111111-0000-0000-0000-000000000001"
  PLUG_DEVICE = "d2222222-0000-0000-0000-000000000002"

  def resources
    {
      "/clip/v2/resource/light" => {
        "errors" => [],
        "data" => [
          {
            "id" => LIGHT_UUID, "type" => "light",
            "owner" => { "rid" => LIGHT_DEVICE, "rtype" => "device" },
            "metadata" => { "name" => "Porch Light", "archetype" => "classic_bulb" },
            "on" => { "on" => true },
            "dimming" => { "brightness" => 63.0 }
          },
          {
            "id" => PLUG_UUID, "type" => "light",
            "owner" => { "rid" => PLUG_DEVICE, "rtype" => "device" },
            "metadata" => { "name" => "Fountain Outlet", "archetype" => "plug" },
            "on" => { "on" => false }
          }
        ]
      },
      "/clip/v2/resource/device" => {
        "errors" => [],
        "data" => [
          {
            "id" => LIGHT_DEVICE, "type" => "device",
            "metadata" => { "name" => "Porch Light" },
            "product_data" => { "product_name" => "Hue white lamp" },
            "services" => [{ "rid" => LIGHT_UUID, "rtype" => "light" }]
          },
          {
            "id" => PLUG_DEVICE, "type" => "device",
            "metadata" => { "name" => "Fountain Outlet" },
            "product_data" => { "product_name" => "Hue smart plug" },
            "services" => [{ "rid" => PLUG_UUID, "rtype" => "light" }]
          }
        ]
      },
      "/clip/v2/resource/room" => {
        "errors" => [],
        "data" => [
          {
            "id" => "r1", "type" => "room",
            "metadata" => { "name" => "Outside", "archetype" => "other" },
            "children" => [{ "rid" => LIGHT_DEVICE, "rtype" => "device" }]
          },
          {
            "id" => "r2", "type" => "room",
            "metadata" => { "name" => "Patio", "archetype" => "other" },
            "children" => [{ "rid" => PLUG_DEVICE, "rtype" => "device" }]
          }
        ]
      }
    }
  end

  def client(fetcher)
    Janus::Hue::Client.new(bridge_ip: BRIDGE_IP, app_key: APP_KEY, fetcher: fetcher)
  end

  def test_lights_joins_light_device_and_room_resources
    fetcher = StubFetcher.new(resources)
    lights = client(fetcher).lights

    assert_equal 2, lights.size
    porch = lights.find { |light| light[:id] == LIGHT_UUID }
    assert_equal(
      { id: LIGHT_UUID, name: "Porch Light", room: "Outside",
        kind: "light", on: true, reachable: nil },
      porch
    )
    fountain = lights.find { |light| light[:id] == PLUG_UUID }
    assert_equal "plug", fountain[:kind], "the plug archetype marks a smart outlet"
    assert_equal "Patio", fountain[:room]
    assert_equal false, fountain[:on]

    fetcher.calls.each do |(method, uri, headers, _body)|
      assert_equal :get, method
      assert_equal APP_KEY, headers["hue-application-key"]
      assert_match %r{\Ahttps://#{BRIDGE_IP}/clip/v2/resource/}, uri.to_s
    end
  end

  def test_lights_leaves_room_nil_for_unhoused_devices
    data = resources
    data["/clip/v2/resource/room"]["data"] = []
    lights = client(StubFetcher.new(data)).lights
    assert lights.all? { |light| light[:room].nil? }
  end

  def test_lights_raises_with_status_on_non_2xx
    fetcher = StubFetcher.new([500, "boom"])
    error = assert_raises(Janus::Hue::Error) { client(fetcher).lights }
    assert_equal 500, error.status
  end

  def test_lights_raises_on_clip_level_errors
    body = JSON.generate("errors" => [{ "description" => "oh no" }], "data" => [])
    error = assert_raises(Janus::Hue::Error) { client(StubFetcher.new([200, body])).lights }
    assert_match(/oh no/, error.message)
  end

  def test_set_light_puts_the_on_state
    fetcher = StubFetcher.new([200, JSON.generate("errors" => [], "data" => [])])
    client(fetcher).set_light(LIGHT_UUID, on: true)

    method, uri, headers, body = fetcher.calls.first
    assert_equal :put, method
    assert_equal "https://#{BRIDGE_IP}/clip/v2/resource/light/#{LIGHT_UUID}", uri.to_s
    assert_equal APP_KEY, headers["hue-application-key"]
    assert_equal({ "on" => { "on" => true } }, JSON.parse(body))
  end

  def test_set_light_raises_with_status_on_non_2xx
    error = assert_raises(Janus::Hue::Error) do
      client(StubFetcher.new([404, "no such light"])).set_light("nope", on: false)
    end
    assert_equal 404, error.status
  end

  # -- SSE parser ------------------------------------------------------------

  def sse_frame(creationtime, items)
    "data: " + JSON.generate([{ "creationtime" => creationtime, "id" => "evt-1",
                                "type" => "update", "data" => items }])
  end

  def test_each_event_yields_light_on_off_updates_from_a_transcript
    transcript = [
      ": hi", # keepalive comment
      "",
      "id: 1",
      sse_frame("2026-07-08T19:02:00Z", [
        { "id" => LIGHT_UUID, "type" => "light", "on" => { "on" => false },
          "owner" => { "rid" => LIGHT_DEVICE, "rtype" => "device" } }
      ]),
      "",
      ": keepalive",
      "",
      "id: 2",
      sse_frame("2026-07-08T23:14:30Z", [
        { "id" => "grouped-1", "type" => "grouped_light", "on" => { "on" => true } },
        { "id" => PLUG_UUID, "type" => "light", "on" => { "on" => true } },
        { "id" => LIGHT_UUID, "type" => "light", "dimming" => { "brightness" => 20.0 } }
      ]),
      ""
    ].join("\n") + "\n"

    events = []
    client(nil).each_event(io: StringIO.new(transcript)) { |event| events << event }

    assert_equal [
      { entity: "hue.light.#{LIGHT_UUID}", on: false, observed: Time.utc(2026, 7, 8, 19, 2, 0) },
      { entity: "hue.light.#{PLUG_UUID}", on: true, observed: Time.utc(2026, 7, 8, 23, 14, 30) }
    ], events
    assert events.all? { |event| event[:observed].utc? }
  end

  def test_each_event_dispatches_a_final_frame_without_trailing_blank_line
    transcript = sse_frame("2026-07-08T19:02:00Z", [
      { "id" => LIGHT_UUID, "type" => "light", "on" => { "on" => true } }
    ]) + "\n"
    events = []
    client(nil).each_event(io: StringIO.new(transcript)) { |event| events << event }
    assert_equal 1, events.size
  end

  def test_each_event_skips_non_update_frames_and_malformed_json
    transcript = [
      "data: not json at all",
      "",
      "data: " + JSON.generate([{ "creationtime" => "2026-07-08T19:00:00Z",
                                  "type" => "delete", "data" => [] }]),
      "",
      sse_frame("2026-07-08T19:05:00Z", [
        { "id" => LIGHT_UUID, "type" => "light", "on" => { "on" => true } }
      ]),
      ""
    ].join("\n") + "\n"

    events = []
    client(nil).each_event(io: StringIO.new(transcript)) { |event| events << event }
    assert_equal 1, events.size
    assert_equal true, events.first[:on]
  end

  def test_entity_id_prefixes_the_uuid
    assert_equal "hue.light.#{LIGHT_UUID}", Janus::Hue.entity_id(LIGHT_UUID)
  end

  # -- chunked transfer decoding ---------------------------------------------

  def chunked(*chunks)
    chunks.map { |chunk| "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n" }.join + "0\r\n\r\n"
  end

  def test_chunked_io_reassembles_lines_split_across_chunks
    body = chunked("data: [1,\n", " 2]\n\nda", "ta: [3]\n\n")
    lines = []
    Janus::Hue::ChunkedIO.new(StringIO.new(body)).each_line { |line| lines << line }
    assert_equal ["data: [1,\n", " 2]\n", "\n", "data: [3]\n", "\n"], lines
  end

  def test_chunked_io_yields_a_trailing_partial_line_at_stream_end
    body = "5\r\nhello\r\n0\r\n\r\n"
    lines = []
    Janus::Hue::ChunkedIO.new(StringIO.new(body)).each_line { |line| lines << line }
    assert_equal ["hello"], lines
  end
end
