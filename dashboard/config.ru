# ABOUTME: Rack entry point — boots the Sinatra app and, when a source is
# ABOUTME: configured, the background collection poller (single-writer process).

require "dotenv/load"
require_relative "lib/janus/app"
require_relative "lib/janus/poller"

Janus::Poller.start_if_configured(store: Janus::App.store, event_log: Janus::App.event_log)

run Janus::App
