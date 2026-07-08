// ABOUTME: Node tests for the pure chart/format logic in public/dash.js —
// ABOUTME: scales, gap segmentation, tick generation, formatters, and fixture shape.
"use strict";
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const dash = require("../../public/dash.js");
const {
  linScale, extentOf, medianSpacing, segmentSeries, pathFor,
  minMaxIndices, tickTimes, fmtTemp, fmtHum, fmtTimeShort, fmtTick, nearestIndex,
  withinReach,
} = dash;

const FIXTURE_PATH = path.resolve(__dirname, "../fixtures/dashboard.json");
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf8"));

const MIN = 60 * 1000;
const pts = (spec) => spec.map(([t, temp, hum]) => ({ t, temp, hum }));

test("linScale maps domain endpoints and midpoint to range", () => {
  const s = linScale([0, 10], [0, 100]);
  assert.strictEqual(s(0), 0);
  assert.strictEqual(s(10), 100);
  assert.strictEqual(s(5), 50);
});

test("linScale handles inverted ranges (SVG y grows downward)", () => {
  const s = linScale([50, 80], [96, 0]);
  assert.strictEqual(s(50), 96);
  assert.strictEqual(s(80), 0);
  assert.strictEqual(s(65), 48);
});

test("linScale with zero-span domain maps to range midpoint", () => {
  const s = linScale([70, 70], [0, 100]);
  assert.strictEqual(s(70), 50);
});

test("extentOf returns [min, max] for a key", () => {
  const p = pts([["a", 70.1, 40], ["b", 68.2, 45], ["c", 74.9, 42]]);
  assert.deepStrictEqual(extentOf(p, "temp"), [68.2, 74.9]);
  assert.deepStrictEqual(extentOf(p, "hum"), [40, 45]);
});

test("medianSpacing returns the median inter-point interval", () => {
  assert.strictEqual(medianSpacing([0, 10, 20, 30]), 10);
  assert.strictEqual(medianSpacing([0, 10, 20, 100]), 10);
  // Even count of gaps: mean of middle two.
  assert.strictEqual(medianSpacing([0, 10, 30, 60, 100]), 25);
  assert.strictEqual(medianSpacing([0]), 0);
  assert.strictEqual(medianSpacing([]), 0);
});

test("segmentSeries keeps a uniformly spaced series whole", () => {
  const p = [0, 10, 20, 30, 40].map((m) => ({ t: new Date(m * MIN).toISOString(), temp: 70, hum: 40 }));
  const segs = segmentSeries(p);
  assert.strictEqual(segs.length, 1);
  assert.strictEqual(segs[0].length, 5);
});

test("segmentSeries breaks at gaps wider than gapFactor x median spacing", () => {
  const mins = [0, 10, 20, 30, 90, 100, 110];
  const p = mins.map((m) => ({ t: new Date(m * MIN).toISOString(), temp: 70, hum: 40 }));
  const segs = segmentSeries(p);
  assert.strictEqual(segs.length, 2);
  assert.strictEqual(segs[0].length, 4);
  assert.strictEqual(segs[1].length, 3);
});

test("segmentSeries does not break at exactly gapFactor x median", () => {
  const mins = [0, 10, 20, 40, 50]; // 20-minute gap = exactly 2x median
  const p = mins.map((m) => ({ t: new Date(m * MIN).toISOString(), temp: 70, hum: 40 }));
  assert.strictEqual(segmentSeries(p).length, 1);
});

test("segmentSeries honors a custom gapFactor", () => {
  const mins = [0, 10, 20, 35, 45];
  const p = mins.map((m) => ({ t: new Date(m * MIN).toISOString(), temp: 70, hum: 40 }));
  assert.strictEqual(segmentSeries(p, 1.2).length, 2);
  assert.strictEqual(segmentSeries(p, 2).length, 1);
});

test("segmentSeries handles empty and single-point series", () => {
  assert.deepStrictEqual(segmentSeries([]), []);
  const one = [{ t: "2026-07-07T00:00:00Z", temp: 70, hum: 40 }];
  const segs = segmentSeries(one);
  assert.strictEqual(segs.length, 1);
  assert.strictEqual(segs[0].length, 1);
});

test("segmentSeries splits the fixture's real gap into two segments", () => {
  const living = fixture.sensors.find((s) => s.name === "Living Room");
  const segs = segmentSeries(living.series);
  assert.strictEqual(segs.length, 2);
  const total = segs.reduce((n, s) => n + s.length, 0);
  assert.strictEqual(total, living.series.length);
});

test("segmentSeries keeps gapless fixture sensors whole", () => {
  const bedroom = fixture.sensors.find((s) => s.name === "Bedroom");
  assert.strictEqual(segmentSeries(bedroom.series).length, 1);
});

test("pathFor builds an M/L path through scaled points", () => {
  const p = pts([["1970-01-01T00:00:00.000Z", 60, 40],
                 ["1970-01-01T00:10:00.000Z", 70, 45],
                 ["1970-01-01T00:20:00.000Z", 80, 50]]);
  const x = linScale([0, 20 * MIN], [0, 100]);
  const y = linScale([60, 80], [96, 0]);
  assert.strictEqual(pathFor(p, x, y, "temp"), "M0,96L50,48L100,0");
});

test("pathFor on a single point yields a bare moveto", () => {
  const p = pts([["1970-01-01T00:00:00.000Z", 60, 40]]);
  const x = linScale([0, 10], [0, 100]);
  const y = linScale([50, 70], [96, 0]);
  assert.strictEqual(pathFor(p, x, y, "temp"), "M0,48");
});

test("minMaxIndices finds min and max, ties going to the first occurrence", () => {
  const p = pts([["a", 71, 40], ["b", 68, 41], ["c", 75, 42], ["d", 68, 43], ["e", 75, 44]]);
  assert.deepStrictEqual(minMaxIndices(p, "temp"), { min: 1, max: 2 });
  assert.deepStrictEqual(minMaxIndices(p, "hum"), { min: 0, max: 4 });
});

test("minMaxIndices on empty series returns nulls", () => {
  assert.deepStrictEqual(minMaxIndices([], "temp"), { min: null, max: null });
});

const DAY = 24 * 3600 * 1000;
function checkTicks(hours, alignHourMod) {
  const end = Date.now();
  const start = end - hours * 3600 * 1000;
  const ticks = tickTimes(start, end, hours);
  assert.ok(ticks.length >= 3 && ticks.length <= 5, `${hours}h: got ${ticks.length} ticks`);
  for (let i = 0; i < ticks.length; i++) {
    assert.ok(ticks[i] >= start && ticks[i] <= end, `${hours}h: tick outside range`);
    if (i > 0) assert.ok(ticks[i] > ticks[i - 1], `${hours}h: ticks not ascending`);
    const d = new Date(ticks[i]);
    assert.strictEqual(d.getMinutes(), 0, `${hours}h: tick not on the hour`);
    assert.strictEqual(d.getSeconds(), 0);
    assert.strictEqual(d.getHours() % alignHourMod, 0, `${hours}h: tick hour ${d.getHours()} not aligned`);
  }
  return ticks;
}

test("tickTimes for 24h gives 3-5 round six-hour local ticks", () => {
  checkTicks(24, 6);
});

test("tickTimes for 72h gives local-midnight ticks", () => {
  const ticks = checkTicks(72, 24);
  for (const t of ticks) assert.strictEqual(new Date(t).getHours(), 0);
});

test("tickTimes for 168h gives local-midnight ticks two days apart", () => {
  const ticks = checkTicks(168, 24);
  for (let i = 1; i < ticks.length; i++) {
    const days = Math.round((ticks[i] - ticks[i - 1]) / DAY);
    assert.strictEqual(days, 2);
  }
});

test("tickTimes for 720h gives weekly local-midnight ticks", () => {
  const ticks = checkTicks(720, 24);
  for (let i = 1; i < ticks.length; i++) {
    const days = Math.round((ticks[i] - ticks[i - 1]) / DAY);
    assert.strictEqual(days, 7);
  }
});

test("fmtTemp renders one decimal with a degree sign, em-dash for missing", () => {
  assert.strictEqual(fmtTemp(71.2), "71.2°");
  assert.strictEqual(fmtTemp(70), "70.0°");
  assert.strictEqual(fmtTemp(null), "—");
  assert.strictEqual(fmtTemp(undefined), "—");
});

test("fmtHum renders a rounded percentage with rh unit, em-dash for missing", () => {
  assert.strictEqual(fmtHum(44.1), "44% rh");
  assert.strictEqual(fmtHum(65.7), "66% rh");
  assert.strictEqual(fmtHum(null), "—");
});

test("fmtTimeShort prefixes the weekday up to a week — a 24h window crosses midnight", () => {
  const d = new Date(2026, 6, 7, 14, 30); // a Tuesday, local time
  assert.strictEqual(fmtTimeShort(d, 24), "Tue 2:30 pm");
  assert.strictEqual(fmtTimeShort(d, 72), "Tue 2:30 pm");
  assert.strictEqual(fmtTimeShort(d, 168), "Tue 2:30 pm");
  // 30 days spans repeated weekdays, so the date replaces the weekday.
  assert.strictEqual(fmtTimeShort(d, 720), "Jul 7, 2:30 pm");
});

test("fmtTick labels hours for 24h, weekday for multi-day, date for 30d", () => {
  const midnight = new Date(2026, 6, 7, 0, 0, 0).getTime();
  const sixAm = new Date(2026, 6, 7, 6, 0, 0).getTime();
  const noon = new Date(2026, 6, 7, 12, 0, 0).getTime();
  const sixPm = new Date(2026, 6, 7, 18, 0, 0).getTime();
  assert.strictEqual(fmtTick(midnight, 24), "12 am");
  assert.strictEqual(fmtTick(sixAm, 24), "6 am");
  assert.strictEqual(fmtTick(noon, 24), "12 pm");
  assert.strictEqual(fmtTick(sixPm, 24), "6 pm");
  assert.match(fmtTick(midnight, 72), /^[A-Z][a-z]{2}$/);
  assert.match(fmtTick(midnight, 168), /^[A-Z][a-z]{2}$/);
  assert.match(fmtTick(midnight, 720), /^[A-Z][a-z]{2} \d{1,2}$/);
});

test("nearestIndex snaps to the closest point, clamping at the edges", () => {
  const base = Date.parse("2026-07-07T00:00:00Z");
  const p = [0, 10, 20, 30].map((m) => ({ t: new Date(base + m * MIN).toISOString(), temp: 70, hum: 40 }));
  assert.strictEqual(nearestIndex(p, base), 0);
  assert.strictEqual(nearestIndex(p, base - 60 * MIN), 0); // before first
  assert.strictEqual(nearestIndex(p, base + 99 * MIN), 3); // after last
  assert.strictEqual(nearestIndex(p, base + 12 * MIN), 1); // nearer neighbor
  assert.strictEqual(nearestIndex(p, base + 18 * MIN), 2);
  assert.strictEqual(nearestIndex(p, base + 5 * MIN), 0); // exact midpoint ties low
});

test("nearestIndex on empty series returns -1", () => {
  assert.strictEqual(nearestIndex([], 12345), -1);
});

test("withinReach accepts points within factor x median spacing of the cursor", () => {
  const base = Date.parse("2026-07-07T00:00:00Z");
  const p = [0, 10, 20, 30].map((m) => ({ t: new Date(base + m * MIN).toISOString(), temp: 70, hum: 40 }));
  assert.strictEqual(withinReach(p, 3, base + 30 * MIN, 3), true); // exactly on the point
  assert.strictEqual(withinReach(p, 3, base + 60 * MIN, 3), true); // 30 min = exactly 3x median
  assert.strictEqual(withinReach(p, 3, base + 61 * MIN, 3), false); // beyond reach
  assert.strictEqual(withinReach(p, 0, base - 31 * MIN, 3), false); // before the series
  assert.strictEqual(withinReach(p, 1, base + 12 * MIN, 3), true); // between points
});

test("withinReach is permissive for series too short to have a spacing", () => {
  const one = [{ t: "2026-07-07T00:00:00Z", temp: 70, hum: 40 }];
  assert.strictEqual(withinReach(one, 0, Date.parse("2026-07-09T00:00:00Z"), 3), true);
});

test("withinReach rejects out-of-range indices", () => {
  assert.strictEqual(withinReach([], -1, 0, 3), false);
  const one = [{ t: "2026-07-07T00:00:00Z", temp: 70, hum: 40 }];
  assert.strictEqual(withinReach(one, 1, 0, 3), false);
});

test("recordsBeginMs flags a series younger than the window", () => {
  const { recordsBeginMs } = dash;
  const end = Date.parse("2026-07-08T12:00:00Z");
  const domain = [end - 720 * 3600e3, end];
  const young = [{ t: "2026-07-05T23:28:00Z" }, { t: "2026-07-06T00:00:00Z" }];
  assert.strictEqual(recordsBeginMs(young, domain), Date.parse("2026-07-05T23:28:00Z"));
});

test("recordsBeginMs is null for full coverage, slight offsets, and empty series", () => {
  const { recordsBeginMs } = dash;
  const end = Date.parse("2026-07-08T12:00:00Z");
  const domain = [end - 24 * 3600e3, end];
  const full = [{ t: "2026-07-07T12:05:00Z" }, { t: "2026-07-08T11:55:00Z" }];
  assert.strictEqual(recordsBeginMs(full, domain), null);
  const slightlyLate = [{ t: "2026-07-07T14:00:00Z" }];
  assert.strictEqual(recordsBeginMs(slightlyLate, domain), null);
  assert.strictEqual(recordsBeginMs([], domain), null);
  assert.strictEqual(recordsBeginMs(null, domain), null);
});

test("staleSinceMs flags readings older than the threshold", () => {
  const { staleSinceMs } = dash;
  const now = Date.parse("2026-07-08T12:00:00Z");
  assert.strictEqual(
    staleSinceMs("2026-07-08T11:30:00Z", now),
    Date.parse("2026-07-08T11:30:00Z")
  );
  assert.strictEqual(staleSinceMs("2026-07-08T11:50:00Z", now), null);
  assert.strictEqual(staleSinceMs("2026-07-08T11:50:00Z", now, 5), Date.parse("2026-07-08T11:50:00Z"));
  assert.strictEqual(staleSinceMs("garbage", now), null);
});

test("staleThresholdMinutes keeps the floor for fast-cadence series", () => {
  const { staleThresholdMinutes } = dash;
  const base = Date.parse("2026-07-08T00:00:00Z");
  const p = [0, 1, 2, 3, 4].map((m) => ({ t: new Date(base + m * MIN).toISOString(), temp: 70, hum: 40 }));
  assert.strictEqual(staleThresholdMinutes(p), 15);
});

test("staleThresholdMinutes widens to 2.5x the median spacing for hourly series", () => {
  const { staleThresholdMinutes } = dash;
  const base = Date.parse("2026-07-08T00:00:00Z");
  const p = [0, 60, 120, 180].map((m) => ({ t: new Date(base + m * MIN).toISOString(), temp: 70, hum: 40 }));
  assert.strictEqual(staleThresholdMinutes(p), 150);
});

test("staleThresholdMinutes returns the floor for empty or single-point series", () => {
  const { staleThresholdMinutes } = dash;
  assert.strictEqual(staleThresholdMinutes([]), 15);
  assert.strictEqual(staleThresholdMinutes([], 30), 30);
  const one = [{ t: "2026-07-08T00:00:00Z", temp: 70, hum: 40 }];
  assert.strictEqual(staleThresholdMinutes(one), 15);
});

test("fmtDate renders month and day", () => {
  assert.strictEqual(dash.fmtDate(new Date(2026, 6, 5)), "Jul 5");
});

test("fixture matches the dashboard API contract", () => {
  assert.strictEqual(typeof fixture.generated_at, "string");
  assert.ok(!Number.isNaN(Date.parse(fixture.generated_at)));
  assert.strictEqual(fixture.hours, 24);
  assert.strictEqual(fixture.sensors.length, 3);
  const names = fixture.sensors.map((s) => s.name);
  assert.deepStrictEqual(names, ["Living Room", "Bedroom", "Crawlspace"]);
  for (const s of fixture.sensors) {
    assert.strictEqual(typeof s.id, "string");
    assert.strictEqual(typeof s.active, "boolean");
    assert.strictEqual(typeof s.battery_percentage, "number");
    for (const k of ["observed", "temperature", "humidity"]) assert.ok(k in s.latest);
    for (const k of ["temp_min", "temp_max", "hum_min", "hum_max"]) assert.strictEqual(typeof s.range[k], "number");
    assert.ok(s.series.length > 0 && s.series.length <= 144);
    let prev = -Infinity;
    for (const p of s.series) {
      const ms = Date.parse(p.t);
      assert.ok(ms > prev, `${s.name}: series not strictly ascending`);
      prev = ms;
      assert.strictEqual(typeof p.temp, "number");
      assert.strictEqual(typeof p.hum, "number");
    }
    assert.strictEqual(s.latest.observed, s.series[s.series.length - 1].t);
  }
  const bedroom = fixture.sensors[1];
  assert.strictEqual(bedroom.battery_percentage, 17.0);
  const crawl = fixture.sensors[2];
  assert.ok(crawl.range.temp_min >= 58 && crawl.range.temp_max <= 62, "crawlspace outside 58-62F");
  assert.ok(crawl.range.hum_min >= 60, "crawlspace should be humid");
});
