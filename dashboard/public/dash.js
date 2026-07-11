// ABOUTME: Renders the Janus dashboard: fetches /api/dashboard and draws Tufte-style
// ABOUTME: SVG sparklines and device on/off strips with crosshair, tooltips, and tables.
"use strict";

// ---------------------------------------------------------------------------
// Pure logic (no DOM) — exported for node tests at the bottom of this file.
// ---------------------------------------------------------------------------

var DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var DAY_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
var MONTH_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var MONTH_LONG = ["January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"];

function pointMs(p) {
  return p.tMs !== undefined ? p.tMs : Date.parse(p.t);
}

// Linear scale from domain [d0,d1] to range [r0,r1]; also exposes .invert.
function linScale(domain, range) {
  var d0 = domain[0], d1 = domain[1], r0 = range[0], r1 = range[1];
  var span = d1 - d0;
  var scale = function (v) {
    if (span === 0) return (r0 + r1) / 2;
    return r0 + ((v - d0) / span) * (r1 - r0);
  };
  scale.invert = function (r) {
    if (r1 - r0 === 0) return d0;
    return d0 + ((r - r0) / (r1 - r0)) * span;
  };
  return scale;
}

function extentOf(points, key) {
  var min = Infinity, max = -Infinity;
  for (var i = 0; i < points.length; i++) {
    var v = points[i][key];
    if (v < min) min = v;
    if (v > max) max = v;
  }
  return [min, max];
}

// Median interval between successive timestamps (ms). Fewer than 2 times -> 0.
function medianSpacing(times) {
  if (times.length < 2) return 0;
  var diffs = [];
  for (var i = 1; i < times.length; i++) diffs.push(times[i] - times[i - 1]);
  diffs.sort(function (a, b) { return a - b; });
  var mid = diffs.length >> 1;
  return diffs.length % 2 ? diffs[mid] : (diffs[mid - 1] + diffs[mid]) / 2;
}

// Split a series into contiguous segments, breaking where the interval is
// strictly greater than gapFactor x the median spacing (no interpolation
// across missing buckets).
function segmentSeries(points, gapFactor) {
  if (gapFactor === undefined) gapFactor = 2;
  if (points.length === 0) return [];
  var times = points.map(pointMs);
  var med = medianSpacing(times);
  var segs = [];
  var cur = [points[0]];
  for (var i = 1; i < points.length; i++) {
    if (med > 0 && times[i] - times[i - 1] > gapFactor * med) {
      segs.push(cur);
      cur = [];
    }
    cur.push(points[i]);
  }
  segs.push(cur);
  return segs;
}

// SVG path ("M x,y L x,y ...") for one contiguous segment.
function pathFor(segment, xScale, yScale, key) {
  var d = "";
  for (var i = 0; i < segment.length; i++) {
    var p = segment[i];
    var x = +xScale(pointMs(p)).toFixed(2);
    var y = +yScale(p[key]).toFixed(2);
    d += (i === 0 ? "M" : "L") + x + "," + y;
  }
  return d;
}

// Indices of the minimum and maximum values; ties go to the first occurrence.
function minMaxIndices(points, key) {
  if (points.length === 0) return { min: null, max: null };
  var min = 0, max = 0;
  for (var i = 1; i < points.length; i++) {
    if (points[i][key] < points[min][key]) min = i;
    if (points[i][key] > points[max][key]) max = i;
  }
  return { min: min, max: max };
}

// Sparse, round local-time ticks: every 6 h for a day, midnights for 3 d,
// alternate midnights for 7 d, weekly midnights for 30 d.
function tickTimes(startMs, endMs, hours) {
  var stepH, alignH;
  if (hours <= 24) { stepH = 6; alignH = 6; }
  else if (hours <= 72) { stepH = 24; alignH = 24; }
  else if (hours <= 168) { stepH = 48; alignH = 24; }
  else { stepH = 168; alignH = 24; }
  var d = new Date(startMs);
  d.setMinutes(0, 0, 0);
  while (d.getTime() < startMs || d.getHours() % alignH !== 0) {
    d.setHours(d.getHours() + 1);
  }
  var ticks = [];
  while (d.getTime() <= endMs) {
    ticks.push(d.getTime());
    d.setHours(d.getHours() + stepH);
  }
  return ticks;
}

function fmtClock(d) {
  var h = d.getHours();
  var h12 = ((h + 11) % 12) + 1;
  var mm = String(d.getMinutes()).padStart(2, "0");
  return h12 + ":" + mm + " " + (h < 12 ? "am" : "pm");
}

function fmtTemp(v) {
  if (v === null || v === undefined) return "—";
  return v.toFixed(1) + "°";
}

function fmtHum(v) {
  if (v === null || v === undefined) return "—";
  return Math.round(v) + "% rh";
}

// Compact timestamp for tooltips and tables: weekday-prefixed below a week
// (even a 24 h window crosses midnight, so bare clocks would repeat),
// date-prefixed from a full week up (a 168 h window already holds two of the
// same weekday; a month repeats them freely).
function fmtTimeShort(date, hours) {
  var clock = fmtClock(date);
  if (hours < 168) return DAY_SHORT[date.getDay()] + " " + clock;
  return MONTH_SHORT[date.getMonth()] + " " + date.getDate() + ", " + clock;
}

// Axis-tick label: hour of day for a day, weekday for multi-day, date for a month.
function fmtTick(ms, hours) {
  var d = new Date(ms);
  if (hours <= 24) {
    var h = d.getHours();
    if (h === 0) return "12 am";
    if (h === 12) return "12 pm";
    return h < 12 ? h + " am" : (h - 12) + " pm";
  }
  if (hours <= 168) return DAY_SHORT[d.getDay()];
  return MONTH_SHORT[d.getMonth()] + " " + d.getDate();
}

// Time of the first sample when a series starts materially after the window
// opens (the sensor is younger than the range), else null. The 10% grace
// absorbs bucket alignment at the window edge.
function recordsBeginMs(points, xDomain) {
  if (!points || points.length === 0) return null;
  var firstMs = pointMs(points[0]);
  return firstMs - xDomain[0] > (xDomain[1] - xDomain[0]) * 0.1 ? firstMs : null;
}

// Stale threshold adapted to a series' cadence: at least floorMinutes, widened
// to 2.5x the series' median spacing so a slow-cadence source (an hourly
// weather station) is not flagged by a rule tuned to minute-cadence sensors.
function staleThresholdMinutes(points, floorMinutes) {
  var floor = floorMinutes === undefined ? 15 : floorMinutes;
  var med = medianSpacing((points || []).map(pointMs)) / 60000;
  return Math.max(floor, 2.5 * med);
}

// Time of the latest reading when it lags now beyond the threshold (a sensor
// that has stopped reporting), else null.
function staleSinceMs(latestIso, nowMs, thresholdMinutes) {
  var t = Date.parse(latestIso);
  if (isNaN(t)) return null;
  var minutes = thresholdMinutes === undefined ? 15 : thresholdMinutes;
  return nowMs - t > minutes * 60000 ? t : null;
}

// Month-and-day date, e.g. "Jul 5".
function fmtDate(d) {
  return MONTH_SHORT[d.getMonth()] + " " + d.getDate();
}

// True when the point at index sits within factor x the series' median
// spacing of xMs — i.e. the cursor is genuinely near data, not reaching
// across a gap to a distant point. Series too short to have a spacing are
// always in reach; out-of-range indices never are.
function withinReach(points, index, xMs, factor) {
  if (index < 0 || index >= points.length) return false;
  var med = medianSpacing(points.map(pointMs));
  if (med === 0) return true;
  return Math.abs(pointMs(points[index]) - xMs) <= factor * med;
}

// Signed temperature differential, always with an explicit sign and one
// decimal, using a true minus sign: "+8.1°" / "−3.2°".
function fmtDelta(v) {
  var abs = Math.abs(v).toFixed(1);
  return (v < 0 ? "−" : "+") + abs + "°";
}

// Split a delta series into sign-consistent runs for the diverging wash:
// returns [{sign: 1|-1, points: [...]}], inserting an interpolated
// {tMs, delta: 0} point at each zero crossing so adjacent runs meet exactly
// on the baseline. Zero deltas extend the current run; a leading run of
// zeros takes the sign of the first nonzero value.
function splitAtZero(points) {
  var segs = [];
  var cur = [];
  var sign = 0;
  for (var i = 0; i < points.length; i++) {
    var p = points[i];
    var s = p.delta > 0 ? 1 : p.delta < 0 ? -1 : 0;
    if (s !== 0 && sign === 0) sign = s;
    if (s !== 0 && s !== sign && cur.length > 0) {
      var prev = points[i - 1];
      var t0 = pointMs(prev), t1 = pointMs(p);
      var frac = prev.delta / (prev.delta - p.delta);
      var zero = { tMs: t0 + (t1 - t0) * frac, delta: 0 };
      cur.push(zero);
      segs.push({ sign: sign, points: cur });
      cur = [zero];
      sign = s;
    }
    cur.push(p);
  }
  if (cur.length > 0) segs.push({ sign: sign || 1, points: cur });
  return segs;
}

// Dew point rendered as a whole degree for the cooling sentence.
function fmtDewPoint(v) {
  return Math.round(v) + "°";
}

// The cooling strip's one-line verdict, as parts ({text, value: true} parts
// render in ink). Three states: outside warmer (sealed), cooler and dry
// (free cooling), cooler but muggy (not worth it). Null when there is no
// current differential.
function coolingSentence(now) {
  if (now === null || now === undefined) return null;
  var mag = { text: Math.abs(now.delta).toFixed(1) + "°", value: true };
  if (now.dew_point === null || now.dew_point === undefined) {
    if (now.delta >= 0) {
      return [{ text: "Outside is " }, mag,
        { text: " warmer than the house — keep it sealed" }];
    }
    return [{ text: "Outside is " }, mag,
      { text: " cooler, but the dew point is unknown — keep it sealed" }];
  }
  var dew = { text: fmtDewPoint(now.dew_point), value: true };
  if (now.delta >= 0) {
    return [{ text: "Outside is " }, mag,
      { text: " warmer than the house · dew point " }, dew,
      { text: " — keep it sealed" }];
  }
  if (now.free_cooling) {
    return [{ text: "Outside is " }, mag,
      { text: " cooler · dew point " }, dew,
      { text: " — free cooling available" }];
  }
  return [{ text: "Outside is " }, mag,
    { text: " cooler, but dew point " }, dew,
    { text: " — not worth opening up" }];
}

function intervalMs(iv) {
  return [
    iv.fromMs !== undefined ? iv.fromMs : Date.parse(iv.from),
    iv.toMs !== undefined ? iv.toMs : Date.parse(iv.to),
  ];
}

// Clip state intervals to the x-domain for drawing: ascending
// [{fromMs, toMs, on}], dropping intervals entirely outside the domain and
// any clipped to zero width. Only known state produces a segment.
function intervalSegments(intervals, xDomain) {
  var out = [];
  for (var i = 0; i < (intervals || []).length; i++) {
    var ms = intervalMs(intervals[i]);
    var a = Math.max(ms[0], xDomain[0]);
    var b = Math.min(ms[1], xDomain[1]);
    if (b <= a) continue;
    out.push({ fromMs: a, toMs: b, on: intervals[i].on });
  }
  return out;
}

// Stretches of the domain covered by no interval — periods with no recorded
// state. Rendered as a neutral wash because unknown is not "off".
function unknownRanges(segments, xDomain) {
  var out = [];
  var cursor = xDomain[0];
  for (var i = 0; i < segments.length; i++) {
    if (segments[i].fromMs > cursor) out.push({ fromMs: cursor, toMs: segments[i].fromMs });
    if (segments[i].toMs > cursor) cursor = segments[i].toMs;
  }
  if (cursor < xDomain[1]) out.push({ fromMs: cursor, toMs: xDomain[1] });
  return out;
}

// State recorded at tMs: {on, sinceMs, clipped} where sinceMs is when that
// state began — or, when clipped, the window edge the server truncated it to
// (the state is older than the window shows) — or null when no state is
// recorded there. On a shared boundary the later interval wins — the state
// changed at that instant.
function stateAtTime(intervals, tMs) {
  var list = intervals || [];
  for (var i = 0; i < list.length; i++) {
    var ms = intervalMs(list[i]);
    var last = i === list.length - 1;
    if (tMs >= ms[0] && (tMs < ms[1] || (last && tMs <= ms[1]))) {
      return { on: list[i].on, sinceMs: ms[0], clipped: list[i].clipped === true };
    }
  }
  return null;
}

// Tooltip time line for a state: a clipped start says "since before" the
// window edge rather than presenting the edge as when the state began.
function sinceLabel(st, hours) {
  var prefix = st.clipped ? "since before " : "since ";
  return prefix + fmtTimeShort(new Date(st.sinceMs), hours);
}

// How long the state has held, for the row's state line: a clipped start
// makes the duration a floor, so the figure carries a "+".
function heldForLabel(st, endMs) {
  return "for " + fmtDuration(endMs - st.sinceMs) + (st.clipped ? "+" : "");
}

// Compact duration from the two largest units: "3 h 40 m", "2 d 5 h",
// "45 m"; sub-minute clamps to "0 m".
function fmtDuration(ms) {
  var minutes = Math.floor(ms / 60000);
  var days = Math.floor(minutes / 1440);
  var hours = Math.floor((minutes % 1440) / 60);
  var mins = minutes % 60;
  if (days > 0) return days + " d" + (hours > 0 ? " " + hours + " h" : "");
  if (hours > 0) return hours + " h" + (mins > 0 ? " " + mins + " m" : "");
  return mins + " m";
}

var THEME_MODES = ["auto", "light", "dark"];

// Next theme mode, ordered against the resolved scheme (what "auto" currently
// looks like) so no step flashes the opposite palette: from auto the first
// step pins the appearance already on screen, the next is the deliberate
// opposite, then back to auto. Unknown mode counts as auto; unknown scheme
// as light.
function nextTheme(current, resolvedScheme) {
  var pinned = resolvedScheme === "dark" ? "dark" : "light";
  var order = ["auto", pinned, pinned === "dark" ? "light" : "dark"];
  var i = order.indexOf(current);
  if (i === -1) i = 0;
  return order[(i + 1) % order.length];
}

// Lifecycle of the range presets: a click may show its preset as selected
// while the fetch is in flight, but the committed range — the one the charts
// actually display and the URL carries — only advances when that fetch lands.
// State: { committed, requested }, requested null when nothing is in flight.
function rangeReducer(state, action) {
  switch (action.type) {
    case "request":
      return { committed: state.committed, requested: action.hours };
    case "loaded":
      if (!rangeAccepts(state, action.hours)) return state;
      return { committed: action.hours, requested: null };
    case "failed":
      // Only the in-flight request's failure reverts; a stale failure from a
      // range no longer asked for must not clear a newer request.
      if (state.requested !== null && action.hours !== state.requested) return state;
      return { committed: state.committed, requested: null };
    default:
      return state;
  }
}

// Whether a response for +hours+ answers the range currently being asked for:
// the in-flight request when one exists, else the committed range (a
// background refresh). Anything else is stale and must not render.
function rangeAccepts(state, hours) {
  return state.requested !== null ? hours === state.requested : hours === state.committed;
}

// The range the presets control shows as selected: the in-flight request when
// one exists (optimistic, reverted by "failed"), else the committed range.
function rangeShown(state) {
  return state.requested !== null ? state.requested : state.committed;
}

// Stable identity for a focusable element across full rebuilds, so focus can
// be restored after a re-render. kind and part come from fixed vocabularies;
// the id (sensor/device) may contain anything, so it rides last and unsplit.
function focusKey(kind, part, id) {
  return kind + "|" + part + "|" + id;
}

function parseFocusKey(key) {
  if (!key) return null;
  var a = key.indexOf("|");
  if (a === -1) return null;
  var b = key.indexOf("|", a + 1);
  if (b === -1) return null;
  return { kind: key.slice(0, a), part: key.slice(a + 1, b), id: key.slice(b + 1) };
}

// Bucket width (minutes) the server serves for an hours-long window — the
// same math as Janus::Store#bucket_window over its 144-point series cap,
// mirrored here the way expectedIntervals mirrors the schedule math.
function bucketMinutesFor(hours) {
  return Math.ceil((hours * 60) / 144);
}

// The readings disclosure named by what the table holds: raw-cadence
// readings for fine buckets, averages labeled with their bucket otherwise.
function tableSummaryLabel(bucketMinutes) {
  if (!bucketMinutes || bucketMinutes <= 10) return "readings";
  if (bucketMinutes === 60) return "hourly averages";
  if (bucketMinutes % 60 === 0) return "bucket averages — " + (bucketMinutes / 60) + " h";
  return "bucket averages — " + bucketMinutes + " min";
}

// The acting register for a device's switch: "pending" while a command is in
// flight, else "on"/"off" from the recorded state. Unknown recorded state
// (never observed) settles a resting binary switch to "off".
function switchState(device) {
  if (device.pending) return "pending";
  return device.on === true ? "on" : "off";
}

// The on-state a tap should request given the currently displayed switch state:
// flip a committed state; a pending or unknown switch acts toward on.
function nextOn(state) {
  return state !== "on";
}

// Reducer for one device's command lifecycle. State:
// { phase: "pending"|"confirmed"|"failed", on, prior, commandId, elapsedMs }.
// The switch shows pending until an observed confirmation (status) or the poll
// cap (tick) resolves it — a 2xx on submit only makes it pending, never done.
function commandReducer(state, action) {
  switch (action.type) {
    case "submit":
      return { phase: "pending", on: action.on, prior: action.prior, commandId: null, elapsedMs: 0 };
    case "accepted":
      return Object.assign({}, state, { commandId: action.commandId });
    case "status":
      if (state.phase !== "pending") return state;
      if (action.status === "confirmed") return Object.assign({}, state, { phase: "confirmed" });
      if (action.status === "failed") return Object.assign({}, state, { phase: "failed" });
      return state;
    case "tick":
      if (state.phase !== "pending") return state;
      var elapsed = state.elapsedMs + action.ms;
      if (elapsed >= action.cap) return Object.assign({}, state, { phase: "failed", elapsedMs: elapsed });
      return Object.assign({}, state, { elapsedMs: elapsed });
    case "error":
      if (state.phase !== "pending") return state;
      return Object.assign({}, state, { phase: "failed" });
    default:
      return state;
  }
}

// Canonical monday-first week used by schedules; a single-letter chip and a
// full name per day, index-aligned.
var DAY_KEYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
var DAY_LETTERS = ["M", "T", "W", "T", "F", "S", "S"];
var DAY_FULL = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

function hmToMinutes(hhmm) {
  return parseInt(hhmm.slice(0, 2), 10) * 60 + parseInt(hhmm.slice(3, 5), 10);
}

// Expected-on intervals for a schedule clipped to the x-domain, ascending
// [{fromMs, toMs}] — the same math as Janus::Schedules.expected_intervals.
// Times are LOCAL wall clock: here the viewer's zone, server-side the
// server's zone; enforcement follows the server's wall. A span may cross
// midnight (on 21:00, off 02:00) and belongs to the day of its on_time, so
// the walk starts one day before the window to catch a reaching span.
function expectedIntervals(schedule, xDomain) {
  if (!schedule || !schedule.enabled) return [];
  var overnight = hmToMinutes(schedule.on_time) > hmToMinutes(schedule.off_time);
  var out = [];
  var d = new Date(xDomain[0]);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - 1);
  function atLocal(base, hhmm, dayOffset) {
    return new Date(base.getFullYear(), base.getMonth(), base.getDate() + dayOffset,
      parseInt(hhmm.slice(0, 2), 10), parseInt(hhmm.slice(3, 5), 10)).getTime();
  }
  while (d.getTime() <= xDomain[1]) {
    if (schedule.days.indexOf(DAY_KEYS[(d.getDay() + 6) % 7]) !== -1) {
      var from = atLocal(d, schedule.on_time, 0);
      var to = atLocal(d, schedule.off_time, overnight ? 1 : 0);
      var a = Math.max(from, xDomain[0]);
      var b = Math.min(to, xDomain[1]);
      if (b > a) out.push({ fromMs: a, toMs: b });
    }
    d.setDate(d.getDate() + 1);
  }
  return out;
}

// Toggle one day in a selection, keeping canonical week order.
function toggleDayIn(days, day) {
  if (days.indexOf(day) !== -1) {
    return days.filter(function (d) { return d !== day; });
  }
  return DAY_KEYS.filter(function (d) { return days.indexOf(d) !== -1 || d === day; });
}

// "HH:MM" as a 12-hour clock: "19:00" -> "7:00 pm".
function fmtHM(hhmm) {
  var h = parseInt(hhmm.slice(0, 2), 10);
  var h12 = ((h + 11) % 12) + 1;
  return h12 + ":" + hhmm.slice(3, 5) + " " + (h < 12 ? "am" : "pm");
}

// The schedule's span for the expected-track tooltip: "7:00 pm to 10:30 pm".
function scheduleLabel(schedule) {
  return fmtHM(schedule.on_time) + " to " + fmtHM(schedule.off_time);
}

// Reducer for one device's schedule editor. State: { on_time, off_time,
// days, enabled, phase: "idle"|"saving", errors: {field: message} }. Edits
// clear their own field's error; "saved" reconciles the fields to the
// server's row; "failed" keeps the edits on screen beside their errors.
function scheduleEditorReducer(state, action) {
  switch (action.type) {
    case "init": {
      var s = action.schedule;
      return {
        on_time: s ? s.on_time : "19:00",
        off_time: s ? s.off_time : "23:00",
        days: s ? s.days.slice() : DAY_KEYS.slice(),
        enabled: s ? s.enabled : true,
        phase: "idle",
        errors: {},
      };
    }
    case "set_time":
      return Object.assign({}, state, clearedError(state, action.field),
        action.field === "on_time" ? { on_time: action.value } : { off_time: action.value });
    case "toggle_day":
      return Object.assign({}, state, clearedError(state, "days"),
        { days: toggleDayIn(state.days, action.day) });
    case "set_enabled":
      return Object.assign({}, state, clearedError(state, "enabled"), { enabled: action.value });
    case "save":
      return Object.assign({}, state, { phase: "saving" });
    case "saved":
      return Object.assign({}, state, {
        phase: "idle", errors: {},
        on_time: action.schedule.on_time, off_time: action.schedule.off_time,
        days: action.schedule.days.slice(), enabled: action.schedule.enabled,
      });
    case "failed":
      return Object.assign({}, state, { phase: "idle", errors: action.errors });
    default:
      return state;
  }
}

// A copy of state.errors without one field, for edits that address it.
function clearedError(state, field) {
  var errors = {};
  for (var k in state.errors) if (k !== field) errors[k] = state.errors[k];
  return { errors: errors };
}

// Index of the point nearest to xMs; ties snap to the earlier point.
function nearestIndex(points, xMs) {
  if (points.length === 0) return -1;
  var best = 0;
  var bestDist = Math.abs(pointMs(points[0]) - xMs);
  for (var i = 1; i < points.length; i++) {
    var dist = Math.abs(pointMs(points[i]) - xMs);
    if (dist < bestDist) { best = i; bestDist = dist; }
  }
  return best;
}

// ---------------------------------------------------------------------------
// DOM rendering — only runs in the browser.
// ---------------------------------------------------------------------------

if (typeof document !== "undefined") {
  (function () {
    var SVG_NS = "http://www.w3.org/2000/svg";
    var VBW = 960;
    var PAD_X = 10;
    // Colors live in the stylesheet's custom properties (which follow the
    // prefers-color-scheme media query); read them once per render so SVG
    // marks, rings, and swatches track the active scheme.
    var colors = {};
    function readColors() {
      var cs = getComputedStyle(document.documentElement);
      ["page", "muted", "secondary", "hairline", "temp", "hum", "lights"].forEach(function (name) {
        colors[name] = cs.getPropertyValue("--" + name).trim();
      });
      // Wash opacities are per-theme too: values that read on cream vanish
      // on the dark page, so the stylesheet owns them alongside the colors.
      colors.washOpacity = cs.getPropertyValue("--wash-opacity").trim() || "0.1";
      colors.unknownOpacity = cs.getPropertyValue("--unknown-opacity").trim() || "0.3";
    }
    var PRESETS = [
      { hours: 24, label: "24 h" },
      { hours: 72, label: "3 d" },
      { hours: 168, label: "7 d" },
      { hours: 720, label: "30 d" },
    ];
    var REFRESH_MS = 5 * 60 * 1000;
    // Command-status polling: a short interval capped near the server's own
    // confirmation timeout, so a command that never confirms fails on its own.
    var POLL_MS = 1500;
    var POLL_CAP_MS = 35 * 1000;

    var state = { data: null };
    // The range presets' lifecycle (see rangeReducer): committed is the range
    // the charts actually display; requested is an in-flight preset click.
    var range = { committed: 24, requested: null };
    // Per-device command lifecycle, keyed by device id, kept across renders so
    // an in-flight or just-failed control survives the periodic refresh. Absent
    // means the switch simply mirrors the recorded state.
    var controls = {};
    // Per-device schedule editor state (open flag + reducer state), kept
    // across renders for the same reason.
    var editors = {};
    var main = document.getElementById("sensors");
    var coolingEl = document.getElementById("cooling");
    var devicesModule = document.getElementById("lights-module");
    var devicesEl = document.getElementById("devices");
    var generatedEl = document.getElementById("generated");
    var themeBtn = document.getElementById("theme");
    var presetsEl = document.getElementById("presets");
    var tooltip = document.getElementById("tooltip");
    var tooltipVal = tooltip.querySelector(".val");
    var tooltipTime = tooltip.querySelector(".time");

    function el(tag, className, text) {
      var node = document.createElement(tag);
      if (className) node.className = className;
      if (text !== undefined) node.textContent = text;
      return node;
    }

    function svgEl(tag, attrs) {
      var node = document.createElementNS(SVG_NS, tag);
      for (var k in attrs) node.setAttribute(k, attrs[k]);
      return node;
    }

    function hideTooltip() {
      tooltip.style.display = "none";
    }

    // One crosshair-and-tooltip owner at a time: a chart claiming the hover
    // clears whichever chart held it before, wherever on the page it lives.
    // Owners register a clear function (which must release itself) plus a
    // scope so a partial rebuild can clear only its own module's hover.
    var hoverOwner = null;
    function claimHover(clear, scope) {
      if (hoverOwner && hoverOwner.clear !== clear) hoverOwner.clear();
      hoverOwner = { clear: clear, scope: scope };
    }
    function releaseHover(clear) {
      if (hoverOwner && hoverOwner.clear === clear) hoverOwner = null;
    }
    // Clears the active hover UI (all of it, or only one scope's) so a
    // rebuild never leaves an orphaned crosshair or tooltip behind.
    function clearHover(scope) {
      if (hoverOwner && (!scope || hoverOwner.scope === scope)) hoverOwner.clear();
      if (!scope) hideTooltip();
    }

    // Focus survival across full rebuilds: focusable elements carry a stable
    // identity in data-focus-key; capture before tearing down, restore after.
    function stampFocus(node, kind, part, id) {
      node.dataset.focusKey = focusKey(kind, part, id);
    }
    function captureFocus() {
      var active = document.activeElement;
      return (active && active.dataset && active.dataset.focusKey) || null;
    }
    function restoreFocus(key) {
      if (!key) return;
      var match = document.querySelector('[data-focus-key="' + CSS.escape(key) + '"]');
      if (match) match.focus();
    }

    // Position the tooltip beside a chart point given in viewBox coordinates.
    function showTooltip(svg, height, xVb, yVb, valueText, timeText) {
      tooltipVal.textContent = valueText;
      tooltipTime.textContent = " — " + timeText;
      tooltip.style.display = "block";
      var rect = svg.getBoundingClientRect();
      var px = rect.left + window.scrollX + (xVb / VBW) * rect.width;
      var py = rect.top + window.scrollY + (yVb / height) * rect.height;
      var left = px + 12;
      var top = py - tooltip.offsetHeight - 10;
      if (left + tooltip.offsetWidth > window.scrollX + document.documentElement.clientWidth - 8) {
        left = px - tooltip.offsetWidth - 12;
      }
      if (left < window.scrollX + 4) left = window.scrollX + 4;
      if (top < window.scrollY + 4) top = py + 14;
      tooltip.style.left = left + "px";
      tooltip.style.top = top + "px";
    }

    // Build one single-series chart (line, gap breaks, min/max/end marks,
    // crosshair, pointer + keyboard interaction).
    function buildChart(opts) {
      var points = opts.points;
      var key = opts.key;
      var height = opts.height;
      var wrap = el("div", "chartwrap");

      // A chart can carry its own key row, or lean on a combined key its
      // caller draws once for a stacked pair (noKey).
      if (!opts.noKey) {
        var keyRow = el("div", "key");
        var swatch = el("span", "swatch");
        swatch.style.background = opts.color;
        keyRow.appendChild(swatch);
        keyRow.appendChild(el("span", null, opts.unitLabel));
        wrap.appendChild(keyRow);
      }

      // The plot box wraps just the SVG so mark labels can be positioned as
      // percentages of the chart area (the key row above would skew them).
      var plot = el("div", "plot");
      wrap.appendChild(plot);

      var svg = svgEl("svg", {
        viewBox: "0 0 " + VBW + " " + height,
        role: "img",
        tabindex: "0",
        "aria-label": opts.ariaLabel,
      });
      if (opts.focus) stampFocus(svg, opts.focus.kind, opts.focus.part, opts.focus.id);
      plot.appendChild(svg);

      var padTop = opts.padTop, padBottom = opts.padBottom;
      var xs = linScale(opts.xDomain, [PAD_X, VBW - PAD_X]);
      var ext = extentOf(points, key);
      // A diverging chart anchors its scale to zero even when the data
      // stays on one side of it.
      if (opts.includeZero) {
        if (ext[0] > 0) ext[0] = 0;
        if (ext[1] < 0) ext[1] = 0;
      }
      if (ext[0] === ext[1]) { ext = [ext[0] - 1, ext[1] + 1]; }
      var ys = linScale(ext, [height - padBottom, padTop]);

      // Underlays (washes, baselines) go in before the line so it stays on top.
      if (opts.decorate) opts.decorate(svg, xs, ys);

      var segs = segmentSeries(points);
      for (var i = 0; i < segs.length; i++) {
        svg.appendChild(svgEl("path", {
          d: pathFor(segs[i], xs, ys, key),
          fill: "none",
          stroke: opts.color,
          "stroke-width": "2",
          "stroke-linejoin": "round",
          "stroke-linecap": "round",
        }));
      }

      function dot(p) {
        return svgEl("circle", {
          cx: xs(pointMs(p)).toFixed(2),
          cy: ys(p[key]).toFixed(2),
          r: "4",
          fill: opts.color,
          stroke: colors.page,
          "stroke-width": "2",
        });
      }

      // Direct labels for min and max: HTML spans positioned as percentages
      // of the plot box so they render at a fixed screen size regardless of
      // chart width. Nudged away from the line, flipped when they would leave
      // the chart, and clamped inside the plot box (never over the tick row);
      // text stays in the secondary color, never the data color.
      var labelGap = 6;
      function mark(idx, below) {
        var p = points[idx];
        var x = xs(pointMs(p));
        var y = ys(p[key]);
        svg.appendChild(dot(p));
        if (below && y + labelGap > height - 4) below = false;
        if (!below && y - labelGap < 4) below = true;
        var tx = "-50%";
        if (x < 42) tx = "0%";
        if (x > VBW - 42) tx = "-100%";
        var lbl = el("span", "marklabel", opts.fmtLabel(p[key]));
        lbl.style.left = ((x / VBW) * 100).toFixed(2) + "%";
        if (below) {
          lbl.style.top = "min(" + (((y + labelGap) / height) * 100).toFixed(2) + "%, calc(100% - 0.8rem))";
          lbl.style.transform = "translate(" + tx + ", 0)";
        } else {
          lbl.style.top = "max(" + (((y - labelGap) / height) * 100).toFixed(2) + "%, 0.8rem)";
          lbl.style.transform = "translate(" + tx + ", -100%)";
        }
        plot.appendChild(lbl);
      }

      var mm = minMaxIndices(points, key);
      mark(mm.max, false);
      if (mm.min !== mm.max) mark(mm.min, true);
      svg.appendChild(dot(points[points.length - 1])); // end dot, no label

      var crosshair = svgEl("line", {
        y1: "0", y2: String(height),
        stroke: colors.muted, "stroke-width": "1",
        style: "display:none",
      });
      svg.appendChild(crosshair);

      function placeCrosshair(x) {
        crosshair.setAttribute("x1", x.toFixed(2));
        crosshair.setAttribute("x2", x.toFixed(2));
        crosshair.style.display = "";
      }

      // Linked crosshair within a sensor: peers in opts.link mirror this
      // chart's crosshair position (no second tooltip) and vice versa.
      function mirror(xMs) {
        if (xMs === null) { crosshair.style.display = "none"; return; }
        placeCrosshair(xs(xMs));
      }
      if (opts.link) opts.link.peers.push(mirror);
      function broadcast(xMs) {
        if (!opts.link) return;
        for (var b = 0; b < opts.link.peers.length; b++) {
          if (opts.link.peers[b] !== mirror) opts.link.peers[b](xMs);
        }
      }

      var activeIdx = -1;
      function showAt(idx) {
        if (idx < 0 || idx >= points.length) return;
        claimHover(clear, opts.hoverScope);
        activeIdx = idx;
        var p = points[idx];
        var x = xs(pointMs(p));
        placeCrosshair(x);
        broadcast(pointMs(p));
        showTooltip(svg, height, x, ys(p[key]),
          opts.fmtValue(p[key]),
          fmtTimeShort(new Date(pointMs(p)), opts.hours));
      }
      function clear() {
        releaseHover(clear);
        activeIdx = -1;
        crosshair.style.display = "none";
        broadcast(null);
        hideTooltip();
      }

      svg.addEventListener("pointermove", function (e) {
        var rect = svg.getBoundingClientRect();
        var xVb = ((e.clientX - rect.left) / rect.width) * VBW;
        var xMs = xs.invert(xVb);
        var idx = nearestIndex(points, xMs);
        // Over a void (a gap or the empty edge of a young sensor), hide the
        // crosshair rather than teleporting it to a distant point.
        if (withinReach(points, idx, xMs, 3)) showAt(idx);
        else clear();
      });
      svg.addEventListener("pointerleave", clear);
      svg.addEventListener("keydown", function (e) {
        if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
          e.preventDefault();
          var idx = activeIdx;
          if (idx === -1) idx = points.length - 1;
          else idx += e.key === "ArrowRight" ? 1 : -1;
          showAt(Math.max(0, Math.min(points.length - 1, idx)));
        } else if (e.key === "Home") {
          e.preventDefault();
          showAt(0);
        } else if (e.key === "End") {
          e.preventDefault();
          showAt(points.length - 1);
        } else if (e.key === "Escape") {
          clear();
        }
      });
      svg.addEventListener("focus", function () { showAt(points.length - 1); });
      svg.addEventListener("blur", clear);

      return wrap;
    }

    function buildTicksRow(xDomain, hours) {
      var row = el("div", "ticks");
      var ticks = tickTimes(xDomain[0], xDomain[1], hours);
      var xs = linScale(xDomain, [PAD_X, VBW - PAD_X]);
      for (var i = 0; i < ticks.length; i++) {
        var span = el("span", "tick", fmtTick(ticks[i], hours));
        span.style.left = ((xs(ticks[i]) / VBW) * 100).toFixed(2) + "%";
        row.appendChild(span);
      }
      return row;
    }

    function buildDataTable(points, hours) {
      var details = el("details", "datatable");
      // Named by what the rows are: raw readings at fine buckets, bucket
      // averages once the range coarsens them.
      details.appendChild(el("summary", null, tableSummaryLabel(bucketMinutesFor(hours))));
      var scroller = el("div", "tablescroll");
      var table = document.createElement("table");
      var thead = document.createElement("thead");
      var hr = document.createElement("tr");
      hr.appendChild(el("th", "tcol", "time"));
      hr.appendChild(el("th", "ncol", "°F"));
      hr.appendChild(el("th", "ncol", "% rh"));
      thead.appendChild(hr);
      table.appendChild(thead);
      var tbody = document.createElement("tbody");
      // Newest reading first: the latest row is the one people come for.
      for (var i = points.length - 1; i >= 0; i--) {
        var p = points[i];
        var tr = document.createElement("tr");
        tr.appendChild(el("td", "tcol", fmtTimeShort(new Date(pointMs(p)), hours)));
        tr.appendChild(el("td", "ncol", p.temp.toFixed(1)));
        tr.appendChild(el("td", "ncol", p.hum.toFixed(1)));
        tbody.appendChild(tr);
      }
      table.appendChild(tbody);
      scroller.appendChild(table);
      details.appendChild(scroller);
      return details;
    }

    // One instrument row per sensor: a slim meta column (name, the current
    // reading on one line, whispers below it) beside a tight stack of
    // temperature and humidity sparklines. Ticks are not drawn here — the
    // module shares one tick row under its last sensor, since every chart
    // reads the same x-domain.
    function buildSensor(sensor, xDomain, hours, openTables) {
      var section = el("section", "sensor");

      var meta = el("div", "meta");
      meta.appendChild(el("h3", "name", sensor.name));
      var latest = sensor.latest;
      var reading = el("div", "reading");
      reading.appendChild(el("span", "big", latest ? fmtTemp(latest.temperature) : "—"));
      if (latest) reading.appendChild(el("span", "humnow", " · " + fmtHum(latest.humidity)));
      meta.appendChild(reading);
      var staleMs = latest ?
        staleSinceMs(latest.observed, xDomain[1], staleThresholdMinutes(sensor.series)) : null;
      if (staleMs !== null) {
        meta.appendChild(el("div", "note", "as of " + fmtTimeShort(new Date(staleMs), hours)));
      }
      var beginMs = recordsBeginMs(sensor.series, xDomain);
      if (beginMs !== null) {
        meta.appendChild(el("div", "note", "records begin " + fmtDate(new Date(beginMs))));
      }
      if (typeof sensor.battery_percentage === "number" && sensor.battery_percentage < 25) {
        meta.appendChild(el("div", "battery", "battery " + Math.round(sensor.battery_percentage) + "%"));
      }
      section.appendChild(meta);

      var charts = el("div", "charts");
      if (!latest || !sensor.series || sensor.series.length === 0) {
        charts.appendChild(el("div", "nodata", "no data in range"));
        section.appendChild(charts);
        return section;
      }

      // One head line serves both charts: a combined key at the left, the
      // readings disclosure at the right — chart furniture off the plots.
      var head = el("div", "chartshead");
      var keyRow = el("div", "key");
      [[colors.temp, "°F"], [colors.hum, "% rh"]].forEach(function (pair) {
        var swatch = el("span", "swatch");
        swatch.style.background = pair[0];
        keyRow.appendChild(swatch);
        keyRow.appendChild(el("span", null, pair[1]));
      });
      head.appendChild(keyRow);
      var table = buildDataTable(sensor.series, hours);
      table.dataset.sensorId = sensor.id;
      stampFocus(table.querySelector("summary"), "sensor", "table", sensor.id);
      if (openTables && openTables[sensor.id]) table.open = true;
      head.appendChild(table);
      charts.appendChild(head);

      // The sensor's two charts share a crosshair link: hovering one mirrors
      // the position (without a tooltip) on the other.
      var link = { peers: [] };
      charts.appendChild(buildChart({
        points: sensor.series, key: "temp",
        height: 54, padTop: 9, padBottom: 8, noKey: true,
        color: colors.temp, unitLabel: "°F",
        xDomain: xDomain, hours: hours,
        ariaLabel: sensor.name + " temperature, " + hoursLabel(hours),
        fmtValue: fmtTemp,
        fmtLabel: fmtTemp,
        link: link, hoverScope: "climate",
        focus: { kind: "sensor", part: "temp", id: sensor.id },
      }));
      charts.appendChild(buildChart({
        points: sensor.series, key: "hum",
        height: 32, padTop: 7, padBottom: 7, noKey: true,
        color: colors.hum, unitLabel: "% rh",
        xDomain: xDomain, hours: hours,
        ariaLabel: sensor.name + " humidity, " + hoursLabel(hours),
        fmtValue: fmtHum,
        fmtLabel: function (v) { return Math.round(v) + "%"; },
        link: link, hoverScope: "climate",
        focus: { kind: "sensor", part: "hum", id: sensor.id },
      }));
      section.appendChild(charts);
      return section;
    }

    // The cooling strip: a one-line verdict on opening up the house plus a
    // diverging outside-minus-house chart. The line stays neutral (secondary
    // text color); the wash between line and zero carries the sign — warm
    // red above the baseline, cool blue below.
    function buildCoolingStrip(cooling, xDomain, hours) {
      var strip = el("section", "cooling");

      var parts = coolingSentence(cooling.now);
      if (parts) {
        var sentence = el("p", "sentence");
        for (var i = 0; i < parts.length; i++) {
          sentence.appendChild(el("span", parts[i].value ? "val" : null, parts[i].text));
        }
        strip.appendChild(sentence);
      }

      var points = cooling.series;
      var charts = el("div", "charts");
      // The key row names both bases on show: the sentence above reads the
      // latest readings; the chart draws bucket means.
      charts.appendChild(buildChart({
        points: points, key: "delta",
        height: 72, padTop: 14, padBottom: 12,
        color: colors.secondary, unitLabel: "Δ °F, outside − house · bucket means",
        xDomain: xDomain, hours: hours,
        ariaLabel: "Outside minus house temperature difference, " + hoursLabel(hours),
        fmtValue: function (v) { return "Δ " + fmtDelta(v); },
        fmtLabel: fmtDelta,
        includeZero: true,
        hoverScope: "climate",
        focus: { kind: "cooling", part: "delta", id: "" },
        decorate: function (svg, xs, ys) {
          var y0 = ys(0).toFixed(2);
          var gapSegs = segmentSeries(points);
          for (var g = 0; g < gapSegs.length; g++) {
            var signed = splitAtZero(gapSegs[g]);
            for (var s = 0; s < signed.length; s++) {
              var run = signed[s];
              if (run.points.length < 2) continue;
              var d = pathFor(run.points, xs, ys, "delta") +
                "L" + xs(pointMs(run.points[run.points.length - 1])).toFixed(2) + "," + y0 +
                "L" + xs(pointMs(run.points[0])).toFixed(2) + "," + y0 + "Z";
              svg.appendChild(svgEl("path", {
                d: d,
                fill: run.sign >= 0 ? colors.temp : colors.hum,
                "fill-opacity": colors.washOpacity,
                stroke: "none",
              }));
            }
          }
          svg.appendChild(svgEl("line", {
            x1: String(PAD_X), x2: String(VBW - PAD_X), y1: y0, y2: y0,
            stroke: colors.hairline, "stroke-width": "1",
          }));
        },
      }));
      charts.appendChild(buildTicksRow(xDomain, hours));
      strip.appendChild(charts);
      return strip;
    }

    // The on/off journal strip for one device: on-intervals filled in the
    // lights amber, known-off left as page background, and unknown stretches
    // (no recorded state) washed in the hairline color at low opacity —
    // encoding chosen so absence of data never reads as "off". Crosshair,
    // tooltip, and keyboard interaction mirror the sensor charts, stepping
    // across state-change boundaries.
    function buildStateStrip(device, xDomain, hours) {
      var height = 28;
      var wrap = el("div", "stripwrap");
      var svg = svgEl("svg", {
        viewBox: "0 0 " + VBW + " " + height,
        role: "img",
        tabindex: "0",
        "aria-label": device.name + " on/off history, " + hoursLabel(hours),
      });
      stampFocus(svg, "device", "strip", device.id);
      wrap.appendChild(svg);

      var xs = linScale(xDomain, [PAD_X, VBW - PAD_X]);
      var segments = intervalSegments(device.intervals, xDomain);

      function band(fromMs, toMs, fill, opacity) {
        svg.appendChild(svgEl("rect", {
          x: xs(fromMs).toFixed(2),
          y: "1",
          width: Math.max(0, xs(toMs) - xs(fromMs)).toFixed(2),
          height: String(height - 2),
          fill: fill,
          "fill-opacity": opacity,
        }));
      }

      var gaps = unknownRanges(segments, xDomain);
      for (var g = 0; g < gaps.length; g++) {
        band(gaps[g].fromMs, gaps[g].toMs, colors.hairline, colors.unknownOpacity);
      }
      for (var s = 0; s < segments.length; s++) {
        if (segments[s].on) band(segments[s].fromMs, segments[s].toMs, colors.lights, "1");
      }

      // Deviation moments (expected and recorded state disagreed past the
      // grace) as small ticks at the strip's base — a genuine alert, so they
      // borrow the temperature red.
      var marks = (device.adherence && device.adherence.marks) || [];
      for (var m = 0; m < marks.length; m++) {
        var markMs = Date.parse(marks[m].t);
        if (markMs < xDomain[0] || markMs > xDomain[1]) continue;
        svg.appendChild(svgEl("rect", {
          x: (xs(markMs) - 1).toFixed(2),
          y: String(height - 7),
          width: "2",
          height: "6",
          fill: colors.temp,
        }));
      }
      ["0.5", String(height - 0.5)].forEach(function (y) {
        svg.appendChild(svgEl("line", {
          x1: String(PAD_X), x2: String(VBW - PAD_X), y1: y, y2: y,
          stroke: colors.hairline, "stroke-width": "1",
        }));
      });

      var crosshair = svgEl("line", {
        y1: "0", y2: String(height),
        stroke: colors.muted, "stroke-width": "1",
        style: "display:none",
      });
      svg.appendChild(crosshair);

      function showAtMs(xMs) {
        var st = stateAtTime(device.intervals, xMs);
        if (!st) { clear(); return; }
        claimHover(clear, "devices");
        var x = xs(xMs);
        crosshair.setAttribute("x1", x.toFixed(2));
        crosshair.setAttribute("x2", x.toFixed(2));
        crosshair.style.display = "";
        showTooltip(svg, height, x, height / 2,
          st.on ? "on" : "off",
          sinceLabel(st, hours));
      }
      function clear() {
        releaseHover(clear);
        activeStop = -1;
        crosshair.style.display = "none";
        hideTooltip();
      }

      // Keyboard stops: each state change plus the end of the record.
      var stops = segments.map(function (seg) { return seg.fromMs; });
      if (segments.length > 0) stops.push(segments[segments.length - 1].toMs);
      var activeStop = -1;
      function showStop(idx) {
        if (stops.length === 0) return;
        activeStop = Math.max(0, Math.min(stops.length - 1, idx));
        showAtMs(stops[activeStop]);
      }

      svg.addEventListener("pointermove", function (e) {
        var rect = svg.getBoundingClientRect();
        var xVb = ((e.clientX - rect.left) / rect.width) * VBW;
        showAtMs(xs.invert(xVb));
      });
      svg.addEventListener("pointerleave", clear);
      svg.addEventListener("keydown", function (e) {
        if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
          e.preventDefault();
          if (activeStop === -1) showStop(stops.length - 1);
          else showStop(activeStop + (e.key === "ArrowRight" ? 1 : -1));
        } else if (e.key === "Home") {
          e.preventDefault();
          showStop(0);
        } else if (e.key === "End") {
          e.preventDefault();
          showStop(stops.length - 1);
        } else if (e.key === "Escape") {
          clear();
        }
      });
      svg.addEventListener("focus", function () { showStop(stops.length - 1); });
      svg.addEventListener("blur", clear);

      return wrap;
    }

    // The expected-state overlay: a thin outline-quality track under the
    // recorded strip showing when the schedule expects the device on, in the
    // muted tone so it stays clearly subordinate to the amber actual band.
    // Sharing the x-domain makes adherence visible as alignment. No schedule
    // (or nothing expected in the window) renders nothing.
    function buildExpectedTrack(device, xDomain) {
      var intervals = expectedIntervals(device.schedule, xDomain);
      if (intervals.length === 0) return null;
      var height = 8;
      var svg = svgEl("svg", {
        class: "expectedtrack",
        viewBox: "0 0 " + VBW + " " + height,
        role: "img",
        tabindex: "0",
        "aria-label": device.name + " scheduled on " + scheduleLabel(device.schedule),
      });
      stampFocus(svg, "device", "expected", device.id);
      var xs = linScale(xDomain, [PAD_X, VBW - PAD_X]);
      for (var i = 0; i < intervals.length; i++) {
        svg.appendChild(svgEl("rect", {
          x: xs(intervals[i].fromMs).toFixed(2),
          y: "1.5",
          width: Math.max(0, xs(intervals[i].toMs) - xs(intervals[i].fromMs)).toFixed(2),
          height: "5",
          fill: colors.muted,
          "fill-opacity": "0.12",
          stroke: colors.muted,
          "stroke-opacity": "0.8",
          "stroke-width": "1",
        }));
      }

      function clear() {
        releaseHover(clear);
        hideTooltip();
      }
      function showAtMs(xMs) {
        for (var j = 0; j < intervals.length; j++) {
          if (xMs >= intervals[j].fromMs && xMs <= intervals[j].toMs) {
            claimHover(clear, "devices");
            showTooltip(svg, height, xs(xMs), height / 2,
              "scheduled on", scheduleLabel(device.schedule));
            return;
          }
        }
        clear();
      }
      svg.addEventListener("pointermove", function (e) {
        var rect = svg.getBoundingClientRect();
        showAtMs(xs.invert(((e.clientX - rect.left) / rect.width) * VBW));
      });
      svg.addEventListener("pointerleave", clear);
      svg.addEventListener("focus", function () {
        var last = intervals[intervals.length - 1];
        showAtMs((last.fromMs + last.toMs) / 2);
      });
      svg.addEventListener("blur", clear);
      svg.addEventListener("keydown", function (e) {
        if (e.key === "Escape") clear();
      });
      return svg;
    }

    // The device's schedule editor state, kept across renders so live edits
    // survive the periodic refresh; a closed editor re-seeds from the
    // server's row, so closing the disclosure quietly discards unsaved edits.
    function editorFor(device) {
      var ed = editors[device.id];
      if (!ed) {
        ed = editors[device.id] = { open: false, state: null };
      }
      if (!ed.open || ed.state === null) {
        ed.state = scheduleEditorReducer(null, { type: "init", schedule: device.schedule });
      }
      return ed;
    }

    function fieldError(message) {
      return el("span", "fielderror", message);
    }

    // The per-device schedule editor, a quiet disclosure in the same idiom
    // as the sensors' "readings" table. Edits mutate the kept editor state
    // in place (no rebuild, so focus stays put); Save PUTs and reconciles
    // from the response; validation errors render inline beside their field.
    function buildScheduleEditor(device) {
      var ed = editorFor(device);
      var st = ed.state;
      var details = el("details", "schededitor");
      var summary = el("summary", null, "schedule");
      stampFocus(summary, "device", "sched", device.id);
      details.appendChild(summary);
      if (ed.open) details.open = true;
      details.addEventListener("toggle", function () {
        ed.open = details.open;
        if (!details.open) ed.state = null; // re-seed from the record next open
      });

      var body = el("div", "schedbody");

      var times = el("div", "schedtimes");
      [["on", "on_time"], ["off", "off_time"]].forEach(function (pair) {
        var label = el("label", null, pair[0]);
        var input = document.createElement("input");
        input.type = "time";
        input.value = st[pair[1]];
        stampFocus(input, "device", "sched-" + pair[0], device.id);
        input.setAttribute("aria-label", device.name + " " + pair[0] + " time");
        if (st.errors[pair[1]]) input.setAttribute("aria-invalid", "true");
        input.addEventListener("input", function () {
          ed.state = scheduleEditorReducer(ed.state, {
            type: "set_time", field: pair[1], value: input.value,
          });
        });
        label.appendChild(input);
        times.appendChild(label);
        if (st.errors[pair[1]]) times.appendChild(fieldError(st.errors[pair[1]]));
      });
      body.appendChild(times);

      var daysRow = el("div", "scheddays");
      DAY_KEYS.forEach(function (day, i) {
        var active = st.days.indexOf(day) !== -1;
        var chip = el("button", "daychip" + (active ? " active" : ""), DAY_LETTERS[i]);
        chip.type = "button";
        stampFocus(chip, "device", "day-" + day, device.id);
        chip.setAttribute("role", "checkbox");
        chip.setAttribute("aria-checked", active ? "true" : "false");
        chip.setAttribute("aria-label", DAY_FULL[i]);
        chip.addEventListener("click", function () {
          ed.state = scheduleEditorReducer(ed.state, { type: "toggle_day", day: day });
          var nowActive = ed.state.days.indexOf(day) !== -1;
          chip.classList.toggle("active", nowActive);
          chip.setAttribute("aria-checked", nowActive ? "true" : "false");
        });
        daysRow.appendChild(chip);
      });
      if (st.errors.days) daysRow.appendChild(fieldError(st.errors.days));
      body.appendChild(daysRow);

      var enabledLabel = el("label", "schedenabled");
      var enabledInput = document.createElement("input");
      enabledInput.type = "checkbox";
      stampFocus(enabledInput, "device", "sched-enabled", device.id);
      enabledInput.checked = st.enabled;
      enabledInput.addEventListener("change", function () {
        ed.state = scheduleEditorReducer(ed.state, { type: "set_enabled", value: enabledInput.checked });
      });
      enabledLabel.appendChild(enabledInput);
      enabledLabel.appendChild(el("span", null, "enabled"));
      if (st.errors.enabled) enabledLabel.appendChild(fieldError(st.errors.enabled));
      body.appendChild(enabledLabel);

      var actions = el("div", "schedactions");
      var save = el("button", "schedbtn", st.phase === "saving" ? "saving…" : "save");
      save.type = "button";
      stampFocus(save, "device", "sched-save", device.id);
      if (st.phase === "saving") save.disabled = true;
      save.addEventListener("click", function () { submitSchedule(device); });
      actions.appendChild(save);
      if (device.schedule) {
        var remove = el("button", "schedbtn", "remove");
        remove.type = "button";
        stampFocus(remove, "device", "sched-remove", device.id);
        remove.addEventListener("click", function () { removeSchedule(device); });
        actions.appendChild(remove);
      }
      if (st.errors.form) actions.appendChild(fieldError(st.errors.form));
      body.appendChild(actions);

      details.appendChild(body);
      return details;
    }

    // Save the editor's schedule: optimistic-render the expected track from
    // the edited values, then reconcile from the server's response (its row
    // on success, the prior schedule plus field errors on failure).
    function submitSchedule(device) {
      var ed = editors[device.id];
      if (!ed || (ed.state && ed.state.phase === "saving")) return;
      var st = ed.state;
      ed.state = scheduleEditorReducer(st, { type: "save" });
      var payload = { on_time: st.on_time, off_time: st.off_time, days: st.days, enabled: st.enabled };
      var prior = device.schedule;
      device.schedule = Object.assign({ entity: device.id }, payload);
      rerenderDevices();

      fetch("/api/schedules/" + encodeURIComponent(device.id), {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      }).then(function (res) {
        return res.json().then(function (data) { return { ok: res.ok, data: data }; });
      }).then(function (r) {
        var dev = deviceById(device.id);
        var e = editors[device.id];
        if (r.ok) {
          if (e && e.state) e.state = scheduleEditorReducer(e.state, { type: "saved", schedule: r.data });
          if (dev) dev.schedule = r.data;
        } else {
          if (e && e.state) {
            e.state = scheduleEditorReducer(e.state, {
              type: "failed",
              errors: r.data.errors || { form: r.data.error || "couldn't save" },
            });
          }
          if (dev) dev.schedule = prior;
        }
        rerenderDevices();
      }).catch(function () {
        var dev = deviceById(device.id);
        var e = editors[device.id];
        if (e && e.state) {
          e.state = scheduleEditorReducer(e.state, { type: "failed", errors: { form: "couldn't save" } });
        }
        if (dev) dev.schedule = prior;
        rerenderDevices();
      });
    }

    // Remove the device's schedule; the track disappears optimistically and
    // comes back (with an error note) if the server declines.
    function removeSchedule(device) {
      var prior = device.schedule;
      var priorAdherence = device.adherence;
      device.schedule = null;
      device.adherence = null;
      var ed = editors[device.id];
      if (ed) ed.state = null;
      rerenderDevices();

      fetch("/api/schedules/" + encodeURIComponent(device.id), { method: "DELETE" })
        .then(function (res) {
          if (res.ok || res.status === 404) return; // gone either way
          throw new Error("http " + res.status);
        })
        .catch(function () {
          var dev = deviceById(device.id);
          if (dev) { dev.schedule = prior; dev.adherence = priorAdherence; }
          var e = editors[device.id];
          if (e) {
            e.state = scheduleEditorReducer(null, { type: "init", schedule: prior });
            e.state = scheduleEditorReducer(e.state, { type: "failed", errors: { form: "couldn't remove" } });
          }
          rerenderDevices();
        });
    }

    // The device's switch — the acting register. A styled role="switch" button
    // (big hit target, keyboard-operable), pending while a command is in flight
    // and never lying that an unconfirmed command is done. The strip below
    // stays the record; this button is the intent.
    function buildSwitch(device) {
      var ctl = controls[device.id];
      var display = (ctl && ctl.phase === "pending") ? "pending" : switchState(device);
      // During pending the committed on-state is whatever we acted from (a live
      // tap knows its prior; a pending command from a reload falls back to the
      // recorded state), so the control never pretends the change has landed.
      var committedOn = display === "pending"
        ? (ctl ? ctl.prior === "on" : device.on === true)
        : (display === "on");

      var btn = el("button", "switch " + display);
      btn.type = "button";
      stampFocus(btn, "device", "switch", device.id);
      btn.setAttribute("role", "switch");
      btn.setAttribute("aria-checked", committedOn ? "true" : "false");
      btn.setAttribute("aria-label", device.name);
      if (display === "pending") btn.setAttribute("aria-busy", "true");
      btn.appendChild(el("span", "knob"));
      btn.addEventListener("click", function () { submitToggle(device); });
      return btn;
    }

    function buildDeviceRow(device, xDomain, hours) {
      var row = el("div", "device");

      var meta = el("div", "meta");
      meta.appendChild(el("h3", "name", device.name));
      if (device.room) meta.appendChild(el("div", "room", device.room));
      meta.appendChild(buildSwitch(device));
      var stateRow = el("div", "staterow");
      if (device.on === null || device.on === undefined) {
        stateRow.appendChild(el("span", "state unknown", "no record yet"));
      } else {
        stateRow.appendChild(el("span", "state " + (device.on ? "ison" : "isoff"),
          device.on ? "on" : "off"));
        // How long the current state has held, from the recorded journal. A
        // state older than the window is a floor, not a measurement, and the
        // "+" says so.
        var current = stateAtTime(device.intervals, xDomain[1]);
        if (current && current.on === device.on) {
          stateRow.appendChild(el("span", "statefor",
            " " + heldForLabel(current, xDomain[1])));
        }
      }
      // A quiet marker when the last command did not confirm; it clears on the
      // next successful action (the next tap replaces this device's control).
      var ctl = controls[device.id];
      if (ctl && ctl.phase === "failed") {
        stateRow.appendChild(el("span", "cmdfail",
          ctl.reason === "unavailable" ? " · control unavailable" : " · didn't confirm"));
      }
      meta.appendChild(stateRow);
      meta.appendChild(buildScheduleEditor(device));
      row.appendChild(meta);

      var strip = el("div", "strip");
      strip.appendChild(buildStateStrip(device, xDomain, hours));
      var track = buildExpectedTrack(device, xDomain);
      if (track) strip.appendChild(track);
      var deviations = device.adherence ? device.adherence.deviations : 0;
      if (deviations > 0) {
        strip.appendChild(el("div", "devnote",
          deviations === 1 ? "1 deviation" : deviations + " deviations"));
      }
      row.appendChild(strip);
      return row;
    }

    // Rebuild just the lights module from the current data, so a control state
    // change repaints its switch without disturbing the sensor charts. Focus
    // inside the module survives the rebuild by identity; any hover UI the
    // module owned is cleared rather than left orphaned.
    function rerenderDevices() {
      if (!state.data) return;
      var focused = captureFocus();
      clearHover("devices");
      var endMs = Date.parse(state.data.generated_at);
      var xDomain = [endMs - state.data.hours * 3600 * 1000, endMs];
      renderDevices(state.data.devices, xDomain, state.data.hours);
      restoreFocus(focused);
    }

    // The device object currently in state.data, or null if it has gone.
    function deviceById(id) {
      var devices = (state.data && state.data.devices) || [];
      for (var i = 0; i < devices.length; i++) if (devices[i].id === id) return devices[i];
      return null;
    }

    // Tap handler: move the switch to pending, POST the toggle, then poll the
    // command until it leaves pending. Optimistic but honest — pending is a
    // distinct state, and a failure snaps back to where we started.
    function submitToggle(device) {
      var id = device.id;
      var ctl = controls[id];
      if (ctl && ctl.phase === "pending") return; // one command at a time

      var current = switchState(device);
      controls[id] = commandReducer(null, { type: "submit", on: nextOn(current), prior: current });
      rerenderDevices();

      var target = controls[id].on;
      fetch("/api/devices/" + encodeURIComponent(id) + "/toggle", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ on: target })
      }).then(function (res) {
        return res.json().then(function (body) { return { ok: res.ok, status: res.status, body: body }; });
      }).then(function (r) {
        var c = controls[id];
        if (!c || c.phase !== "pending") return;
        if (r.ok) {
          controls[id] = commandReducer(c, { type: "accepted", commandId: r.body.command_id });
          pollCommand(id);
        } else {
          controls[id] = { phase: "failed", prior: c.prior, reason: r.status === 409 ? "unavailable" : "error" };
          rerenderDevices();
        }
      }).catch(function () {
        var c = controls[id];
        if (c && c.phase === "pending") {
          controls[id] = commandReducer(c, { type: "error" });
          rerenderDevices();
        }
      });
    }

    // Polls GET /api/commands/:id on an interval, advancing the poll clock each
    // step so an unconfirmed command fails at the cap. Confirmation reloads the
    // dashboard so the strip (the record) shows the newly observed state.
    function pollCommand(id) {
      function step() {
        var c = controls[id];
        if (!c || c.phase !== "pending") return;
        c = controls[id] = commandReducer(c, { type: "tick", ms: POLL_MS, cap: POLL_CAP_MS });
        if (c.phase !== "pending") { rerenderDevices(); return; } // timed out
        if (!c.commandId) { window.setTimeout(step, POLL_MS); return; }

        fetch("/api/commands/" + c.commandId)
          .then(function (res) { if (!res.ok) throw new Error("http " + res.status); return res.json(); })
          .then(function (data) {
            var cur = controls[id];
            if (!cur || cur.phase !== "pending") return;
            cur = controls[id] = commandReducer(cur, { type: "status", status: data.status });
            if (cur.phase === "confirmed") {
              delete controls[id];
              load(range.committed); // the confirming state event extends the strip
            } else if (cur.phase === "failed") {
              rerenderDevices();
            } else {
              window.setTimeout(step, POLL_MS);
            }
          })
          .catch(function () {
            // A transient poll error keeps the command pending; the cap still
            // bounds the wait on the next tick.
            if (controls[id] && controls[id].phase === "pending") window.setTimeout(step, POLL_MS);
          });
      }
      window.setTimeout(step, POLL_MS);
    }

    // The lights & outlets module renders only when devices exist; a house
    // without a paired bridge never sees an empty shell.
    function renderDevices(devices, xDomain, hours) {
      devicesEl.textContent = "";
      if (!devices || devices.length === 0) {
        devicesModule.hidden = true;
        return;
      }
      devicesModule.hidden = false;
      devicesEl.classList.remove("stale");
      for (var i = 0; i < devices.length; i++) {
        devicesEl.appendChild(buildDeviceRow(devices[i], xDomain, hours));
      }
      // One sparse tick row for the whole module, aligned with the strips.
      var ticksRow = el("div", "device-ticks");
      ticksRow.appendChild(el("div"));
      var strip = el("div", "strip");
      strip.appendChild(buildTicksRow(xDomain, hours));
      ticksRow.appendChild(strip);
      devicesEl.appendChild(ticksRow);
    }

    function hoursLabel(hours) {
      if (hours <= 24) return "24 hours";
      return (hours / 24) + " days";
    }

    function fmtGenerated(d) {
      return DAY_LONG[d.getDay()] + ", " + MONTH_LONG[d.getMonth()] + " " +
        d.getDate() + " · " + fmtClock(d);
    }

    function showMessage(text) {
      hideTooltip();
      coolingEl.textContent = "";
      coolingEl.classList.remove("stale");
      main.textContent = "";
      main.appendChild(el("div", "message", text));
      main.classList.remove("stale");
      devicesEl.textContent = "";
      devicesModule.hidden = true;
    }

    function render(data) {
      // A full rebuild: remember who held focus (by stable identity), drop
      // any live hover UI with the elements that owned it, and restore focus
      // into the fresh DOM at the end.
      var focused = captureFocus();
      clearHover();
      readColors();
      // The timestamp is the data's freshness, not a wall clock, so say so.
      // Assigning textContent also drops any pending update-failure marker.
      generatedEl.textContent = "data as of " + fmtGenerated(new Date(data.generated_at));
      // Carry each sensor's open data table across the rebuild.
      var openTables = {};
      main.querySelectorAll(".datatable[open]").forEach(function (d) {
        openTables[d.dataset.sensorId] = true;
      });
      main.textContent = "";
      var endMs = Date.parse(data.generated_at);
      var xDomain = [endMs - data.hours * 3600 * 1000, endMs];
      if (!data.sensors || data.sensors.length === 0) {
        showMessage("No readings yet — add SensorPush credentials to .env and run bin/collect.");
        renderDevices(data.devices, xDomain, data.hours);
        restoreFocus(focused);
        return;
      }
      renderDevices(data.devices, xDomain, data.hours);
      coolingEl.textContent = "";
      if (data.cooling && data.cooling.series && data.cooling.series.length > 0) {
        coolingEl.appendChild(buildCoolingStrip(data.cooling, xDomain, data.hours));
      }
      coolingEl.classList.remove("stale");
      for (var i = 0; i < data.sensors.length; i++) {
        main.appendChild(buildSensor(data.sensors[i], xDomain, data.hours, openTables));
      }
      // One sparse tick row for the whole climate module: every chart above
      // (ΔT strip included) shares this x-domain, so per-chart ticks would be
      // redundant ink at this density.
      var sensorTicks = el("div", "sensor-ticks");
      sensorTicks.appendChild(el("div"));
      var tickCol = el("div", "charts");
      tickCol.appendChild(buildTicksRow(xDomain, data.hours));
      sensorTicks.appendChild(tickCol);
      main.appendChild(sensorTicks);
      main.classList.remove("stale");
      restoreFocus(focused);
    }

    function renderPresets() {
      presetsEl.textContent = "";
      var shown = rangeShown(range);
      for (var i = 0; i < PRESETS.length; i++) {
        if (i > 0) presetsEl.appendChild(el("span", "sep", "·"));
        var a = el("a", shown === PRESETS[i].hours ? "selected" : "", PRESETS[i].label);
        a.href = "?hours=" + PRESETS[i].hours;
        a.dataset.hours = String(PRESETS[i].hours);
        presetsEl.appendChild(a);
      }
    }

    // dim=true marks a user-initiated range change, where the old charts no
    // longer answer the question being asked; background refreshes keep the
    // current render at full strength until new data lands. The requested
    // range (and the ?hours= URL) commits only when its fetch lands; a
    // failure reverts the presets control to the range actually displayed.
    function load(hours, dim) {
      if (dim) {
        main.classList.add("stale");
        coolingEl.classList.add("stale");
        devicesEl.classList.add("stale");
      }
      fetch("/api/dashboard?hours=" + hours)
        .then(function (res) {
          if (!res.ok) throw new Error("http " + res.status);
          return res.json();
        })
        .then(function (data) {
          if (!rangeAccepts(range, data.hours)) return; // stale response
          var wasRequested = range.requested !== null;
          range = rangeReducer(range, { type: "loaded", hours: data.hours });
          if (wasRequested) {
            history.replaceState(null, "", "?hours=" + range.committed);
            renderPresets();
          }
          state.data = data;
          render(data);
        })
        .catch(function () {
          range = rangeReducer(range, { type: "failed", hours: hours });
          renderPresets(); // revert any optimistic selection
          // Keep any previous render on screen; the refresh timer retries.
          if (!state.data) { showMessage("Can't reach the server."); return; }
          main.classList.remove("stale");
          coolingEl.classList.remove("stale");
          devicesEl.classList.remove("stale");
          if (!generatedEl.querySelector(".updatefail")) {
            generatedEl.appendChild(el("span", "updatefail", " · update failed — retrying"));
          }
        });
    }

    presetsEl.addEventListener("click", function (e) {
      var a = e.target.closest("a");
      if (!a) return;
      e.preventDefault();
      var hours = parseInt(a.dataset.hours, 10);
      if (hours === rangeShown(range)) return;
      range = rangeReducer(range, { type: "request", hours: hours });
      renderPresets();
      load(hours, true);
    });

    // Theme override: "auto" follows the OS via the media query; "light" and
    // "dark" pin the palette by stamping data-theme on the root element. The
    // meta color-scheme follows so scrollbars and form controls match.
    var THEME_STORAGE_KEY = "janus-theme";
    var theme = localStorage.getItem(THEME_STORAGE_KEY);
    if (THEME_MODES.indexOf(theme) === -1) theme = "auto";

    function applyTheme() {
      if (theme === "auto") delete document.documentElement.dataset.theme;
      else document.documentElement.dataset.theme = theme;
      document.querySelector('meta[name="color-scheme"]')
        .setAttribute("content", theme === "auto" ? "light dark" : theme);
      themeBtn.textContent = "theme: " + theme;
      themeBtn.setAttribute("aria-label", "theme: " + theme);
    }

    themeBtn.addEventListener("click", function () {
      // The cycle is ordered against the resolved scheme so no step flashes
      // the opposite palette: from auto it first pins what is on screen.
      var resolved = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
      theme = nextTheme(theme, resolved);
      try { localStorage.setItem(THEME_STORAGE_KEY, theme); } catch (e) { /* private mode */ }
      applyTheme();
      // Redraw so canvas-side colors (SVG strokes, washes, dot rings,
      // swatches) re-read the custom properties under the new theme.
      if (state.data) render(state.data);
    });
    applyTheme();

    // Re-render on light/dark scheme changes so canvas-side colors (SVG
    // strokes, dot rings, swatches) pick up the new custom-property values.
    // Under a pinned theme the palette doesn't change, so the redraw is a
    // harmless no-op.
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      if (state.data) render(state.data);
    });

    var param = parseInt(new URLSearchParams(location.search).get("hours"), 10);
    if ([24, 72, 168, 720].indexOf(param) !== -1) range.committed = param;
    renderPresets();
    load(range.committed);
    setInterval(function () { load(range.committed); }, REFRESH_MS);
  })();
}

if (typeof module !== "undefined") {
  module.exports = {
    linScale: linScale,
    extentOf: extentOf,
    medianSpacing: medianSpacing,
    segmentSeries: segmentSeries,
    pathFor: pathFor,
    minMaxIndices: minMaxIndices,
    tickTimes: tickTimes,
    fmtTemp: fmtTemp,
    fmtHum: fmtHum,
    fmtTimeShort: fmtTimeShort,
    fmtDate: fmtDate,
    recordsBeginMs: recordsBeginMs,
    staleSinceMs: staleSinceMs,
    staleThresholdMinutes: staleThresholdMinutes,
    fmtTick: fmtTick,
    nearestIndex: nearestIndex,
    withinReach: withinReach,
    fmtDelta: fmtDelta,
    splitAtZero: splitAtZero,
    coolingSentence: coolingSentence,
    nextTheme: nextTheme,
    intervalSegments: intervalSegments,
    unknownRanges: unknownRanges,
    stateAtTime: stateAtTime,
    sinceLabel: sinceLabel,
    heldForLabel: heldForLabel,
    fmtDuration: fmtDuration,
    rangeReducer: rangeReducer,
    rangeAccepts: rangeAccepts,
    rangeShown: rangeShown,
    focusKey: focusKey,
    parseFocusKey: parseFocusKey,
    bucketMinutesFor: bucketMinutesFor,
    tableSummaryLabel: tableSummaryLabel,
    switchState: switchState,
    nextOn: nextOn,
    commandReducer: commandReducer,
    DAY_KEYS: DAY_KEYS,
    expectedIntervals: expectedIntervals,
    toggleDayIn: toggleDayIn,
    fmtHM: fmtHM,
    scheduleLabel: scheduleLabel,
    scheduleEditorReducer: scheduleEditorReducer,
  };
}
