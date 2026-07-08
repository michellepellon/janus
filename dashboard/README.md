# Janus dashboard

A Tufte-inspired house-climate dashboard. Reads temperature and humidity from
[SensorPush](https://www.sensorpush.com) sensors via the
[sensorpush gem](https://github.com/michellepellon/sensorpush.rb), stores
readings in DuckDB, and serves a plain HTML/CSS/JS page — no frameworks, no
build step, no external requests.

## Setup

```sh
bundle install
cp .env.example .env   # then fill in SENSORPUSH_USERNAME / SENSORPUSH_PASSWORD
```

## Run

```sh
bin/collect            # one-shot backfill (default 30 days; see --help)
bin/server             # dashboard at http://127.0.0.1:8367
```

The server runs its own background poller (every `JANUS_POLL_SECONDS`, default
300), so once it's up you don't need `bin/collect` — DuckDB allows one writer,
so use `bin/collect` only while the server is stopped (it says so if you get
it wrong).

## Outside

When `JANUS_OUTSIDE_STATION` is set (e.g. `KEFD`), an "Outside" pseudo-sensor
is collected from that [NWS](https://www.weather.gov/documentation/services-web-api)
observation station alongside the SensorPush sensors. Stations report roughly
hourly (plus specials) and the NWS keeps 7 days of history, so backfill covers
a week at most. Unset the variable to disable it; `JANUS_NWS_USER_AGENT`
customizes the User-Agent the NWS API requires.

## Layout

- `lib/janus/store.rb` — DuckDB schema and queries (idempotent inserts,
  time-bucketed dashboard windows)
- `lib/janus/collector.rb` — incremental SensorPush collection with paging and
  transient-network retry
- `lib/janus/weather.rb` — NWS station observations shaped like SensorPush samples
- `lib/janus/weather_collector.rb` — the Outside pseudo-sensor collection
- `lib/janus/poller.rb` — background collection thread inside the server
- `lib/janus/app.rb` — Sinatra: `/`, `/healthz`, `/api/dashboard?hours=24|72|168|720`
- `public/` — the page: `index.html`, `style.css`, `dash.js` (plain SVG charts)
- `data/janus.duckdb` — readings (gitignored; override with `JANUS_DB_PATH`)

## Tests

```sh
bundle exec rake            # unit + integration
bundle exec rake e2e        # boots the real server against a seeded DB
bundle exec rake frontend   # node --test for the chart logic
bundle exec rake all        # everything
```
