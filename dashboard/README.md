# Janus dashboard

A Tufte-inspired house dashboard. Reads temperature and humidity from
[SensorPush](https://www.sensorpush.com) sensors via the
[sensorpush gem](https://github.com/michellepellon/sensorpush.rb), records
light and smart-outlet state from a Philips Hue bridge, stores everything in
DuckDB, and serves a plain HTML/CSS/JS page — no frameworks, no build step,
no external requests.

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

## Lights & outlets

Philips Hue lights and smart plugs appear in a "lights & outlets" module:
an on/off switch per device over the recorded state — current state plus an
on/off timeline. Tapping a switch issues a command that stays *pending* until
the bridge's own event stream reports the change: a 2xx from the bridge means
"accepted", the observed state event means "done", so the switch settles only
on confirmation and snaps back if none arrives. The strip stays the record;
the switch is the intent. Control needs a paired bridge; without one the
module is read-only and the toggle endpoints answer honestly. To pair:

1. Power on the Hue bridge and make sure it's on your network.
2. Run `bin/hue-pair` (it finds the bridge, or pass `--ip`).
3. Press the bridge's round link button when prompted.
4. Restart `bin/server`.

Pairing appends `HUE_BRIDGE_IP` and `HUE_APP_KEY` to `.env`; unset them to
disable Hue collection. The server then reconciles device state every poll
and follows the bridge's event stream for changes in between, storing
append-only state events in the `events` table. The module stays hidden
until at least one device is recorded.

## Schedules

Each device can carry one schedule: an on time, an off time, and a set of
weekdays. Times are **local wall clock in the server's zone** — "on at
19:00" means 19:00 on the wall wherever the server runs, across DST
changes. Spans may cross midnight (on 21:00, off 02:00); an overnight span
belongs to the day of its on time.

Enforcement is **edge-triggered**: the poller commands a device only when a
schedule edge has passed since its previous check, so flipping a light by
hand mid-window sticks — Janus does not fight you — until the next edge
reasserts the schedule. Alongside it, adherence is watched continuously:
when the recorded state disagrees with the schedule for more than five
minutes, one `deviation` event enters the journal for that episode, so
"the porch light was off Tuesday evening when it shouldn't have been" is
queryable history. Each device row shows the expected-on track under its
recorded strip, deviation tick marks, and a schedule editor.

The API: `GET /api/schedules`, `PUT /api/schedules/:entity` (422 with
per-field errors on bad input), `DELETE /api/schedules/:entity`; the
dashboard payload carries each device's `schedule` and `adherence`.

## Layout

- `lib/janus/store.rb` — DuckDB schema and queries (idempotent inserts,
  time-bucketed dashboard windows, devices registry)
- `lib/janus/event_log.rb` — append-only events journal, command ledger, and
  windowed on/off interval queries
- `lib/janus/commander.rb` — issues light on/off commands and reconciles them,
  confirming against observed state events rather than the transport's 2xx
- `lib/janus/schedules.rb` — per-device schedules (local wall-clock times)
  and the pure span/edge/interval math
- `lib/janus/schedule_runner.rb` — edge-triggered enforcement and
  grace-buffered adherence deviations, run from the poller
- `lib/janus/collector.rb` — incremental SensorPush collection with paging and
  transient-network retry
- `lib/janus/weather.rb` — NWS station observations shaped like SensorPush samples
- `lib/janus/weather_collector.rb` — the Outside pseudo-sensor collection
- `lib/janus/hue.rb` — Philips Hue CLIP v2 client: pairing, lights, SSE events
- `lib/janus/hue_recorder.rb` — reconciles and streams light state into the log
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
