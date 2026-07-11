// ABOUTME: Node tests for the schedule logic in public/dash.js — expected-on
// ABOUTME: intervals (parity with the Ruby math), day toggles, editor reducer.
"use strict";
const { test } = require("node:test");
const assert = require("node:assert");

const {
  expectedIntervals, toggleDayIn, fmtHM, scheduleLabel, scheduleEditorReducer,
  DAY_KEYS,
} = require("../../public/dash.js");

// All times below are LOCAL wall clock, mirroring the Ruby tests:
// 2026-07-06 is a Monday (month index 6 = July).
const local = (d, h, m) => new Date(2026, 6, d, h, m).getTime();
const ALL_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
const sched = (over = {}) => Object.assign(
  { on_time: "19:00", off_time: "23:00", days: ["mon"], enabled: true }, over);

// ---- expectedIntervals: the same table the Ruby math is tested against ----

test("same-day span yields one interval on the scheduled day", () => {
  assert.deepStrictEqual(
    expectedIntervals(sched(), [local(6, 18, 0), local(7, 0, 0)]),
    [{ fromMs: local(6, 19, 0), toMs: local(6, 23, 0) }]);
});

test("intervals clip to the window", () => {
  assert.deepStrictEqual(
    expectedIntervals(sched(), [local(6, 20, 0), local(6, 22, 0)]),
    [{ fromMs: local(6, 20, 0), toMs: local(6, 22, 0) }]);
});

test("multi-day windows produce one interval per scheduled day, ascending", () => {
  assert.deepStrictEqual(
    expectedIntervals(sched({ days: ["mon", "tue"] }), [local(6, 0, 0), local(8, 0, 0)]),
    [{ fromMs: local(6, 19, 0), toMs: local(6, 23, 0) },
     { fromMs: local(7, 19, 0), toMs: local(7, 23, 0) }]);
});

test("overnight span crosses midnight, owned by the day of its on_time", () => {
  assert.deepStrictEqual(
    expectedIntervals(sched({ on_time: "21:00", off_time: "02:00" }),
      [local(6, 20, 0), local(7, 3, 0)]),
    [{ fromMs: local(6, 21, 0), toMs: local(7, 2, 0) }]);
});

test("an overnight span from the day before reaches into the window", () => {
  assert.deepStrictEqual(
    expectedIntervals(sched({ on_time: "21:00", off_time: "02:00" }),
      [local(7, 1, 0), local(7, 12, 0)]),
    [{ fromMs: local(7, 1, 0), toMs: local(7, 2, 0) }]);
});

test("disabled schedules and unscheduled days expect nothing", () => {
  assert.deepStrictEqual(
    expectedIntervals(sched({ enabled: false }), [local(6, 0, 0), local(7, 0, 0)]), []);
  assert.deepStrictEqual(
    expectedIntervals(sched({ days: ["tue"] }), [local(6, 0, 0), local(6, 23, 0)]), []);
  assert.deepStrictEqual(expectedIntervals(null, [local(6, 0, 0), local(7, 0, 0)]), []);
});

// ---- day toggles and round-trips ----

test("DAY_KEYS is the canonical monday-first week", () => {
  assert.deepStrictEqual(DAY_KEYS, ALL_DAYS);
});

test("toggleDayIn adds in canonical order and removes in place", () => {
  assert.deepStrictEqual(toggleDayIn(["mon", "fri"], "wed"), ["mon", "wed", "fri"]);
  assert.deepStrictEqual(toggleDayIn(["mon", "wed", "fri"], "mon"), ["wed", "fri"]);
  assert.deepStrictEqual(toggleDayIn([], "sun"), ["sun"]);
});

test("a day list round-trips through the API's join/split shape", () => {
  const days = ["mon", "wed", "sat"];
  assert.deepStrictEqual(days.join(",").split(","), days);
  // An out-of-order selection settles into canonical order via toggles.
  let acc = [];
  ["sat", "mon", "wed"].forEach((d) => { acc = toggleDayIn(acc, d); });
  assert.deepStrictEqual(acc, days);
});

// ---- clock formatting for the tooltip ----

test("fmtHM renders HH:MM as a 12-hour clock", () => {
  assert.strictEqual(fmtHM("19:00"), "7:00 pm");
  assert.strictEqual(fmtHM("00:15"), "12:15 am");
  assert.strictEqual(fmtHM("12:00"), "12:00 pm");
  assert.strictEqual(fmtHM("09:05"), "9:05 am");
});

test("scheduleLabel spells out the span", () => {
  assert.strictEqual(scheduleLabel(sched({ on_time: "19:00", off_time: "22:30" })),
    "7:00 pm to 10:30 pm");
});

// ---- editor reducer ----

test("init without a schedule starts from sensible defaults", () => {
  const s = scheduleEditorReducer(null, { type: "init", schedule: null });
  assert.strictEqual(s.on_time, "19:00");
  assert.strictEqual(s.off_time, "23:00");
  assert.deepStrictEqual(s.days, ALL_DAYS);
  assert.strictEqual(s.enabled, true);
  assert.strictEqual(s.phase, "idle");
  assert.deepStrictEqual(s.errors, {});
});

test("init from an existing schedule copies its fields", () => {
  const s = scheduleEditorReducer(null, {
    type: "init",
    schedule: { on_time: "21:00", off_time: "02:00", days: ["fri", "sat"], enabled: false },
  });
  assert.strictEqual(s.on_time, "21:00");
  assert.deepStrictEqual(s.days, ["fri", "sat"]);
  assert.strictEqual(s.enabled, false);
});

test("edits update fields and clear that field's error", () => {
  let s = scheduleEditorReducer(null, { type: "init", schedule: null });
  s = scheduleEditorReducer(s, { type: "failed", errors: { on_time: "bad", days: "bad" } });
  s = scheduleEditorReducer(s, { type: "set_time", field: "on_time", value: "20:15" });
  assert.strictEqual(s.on_time, "20:15");
  assert.strictEqual(s.errors.on_time, undefined);
  assert.strictEqual(s.errors.days, "bad", "other field errors persist until edited");
  s = scheduleEditorReducer(s, { type: "toggle_day", day: "mon" });
  assert.deepStrictEqual(s.days, ALL_DAYS.slice(1));
  assert.strictEqual(s.errors.days, undefined);
  s = scheduleEditorReducer(s, { type: "set_enabled", value: false });
  assert.strictEqual(s.enabled, false);
});

test("save/saved/failed drive the phase and reconcile fields", () => {
  let s = scheduleEditorReducer(null, { type: "init", schedule: null });
  s = scheduleEditorReducer(s, { type: "save" });
  assert.strictEqual(s.phase, "saving");
  s = scheduleEditorReducer(s, {
    type: "saved",
    schedule: { on_time: "18:45", off_time: "23:00", days: ["mon"], enabled: true },
  });
  assert.strictEqual(s.phase, "idle");
  assert.strictEqual(s.on_time, "18:45", "the server's row is the reconciled truth");
  assert.deepStrictEqual(s.errors, {});

  s = scheduleEditorReducer(s, { type: "save" });
  s = scheduleEditorReducer(s, { type: "failed", errors: { off_time: "must differ" } });
  assert.strictEqual(s.phase, "idle");
  assert.strictEqual(s.errors.off_time, "must differ");
  assert.strictEqual(s.on_time, "18:45", "a failure keeps the edits on screen");
});
