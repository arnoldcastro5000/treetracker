// Unit tests for the pure status-derivation logic of the Capture Journey report.
// Runs with the Node built-in test runner (no dependencies), so it works even when
// the e2e node_modules is absent: `node --test utils/capture-journey.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  deriveJourney,
  assembleHops,
  render,
  formatClock,
} from "./capture-journey.mjs";

// Build an ordered hop list from a compact [key, signal] spec.
const hops = (...pairs) =>
  pairs.map(([key, signal]) => ({
    key,
    layer: "test",
    hop: key,
    signal,
    source: `${key}-src`,
    evidence: "",
  }));

const statusOf = (res, key) => res.hops.find((h) => h.key === key).status;

test("all present -> COMPLETE, every hop PASS", () => {
  const res = deriveJourney(hops(["a", "present"], ["b", "present"], ["c", "present"]));
  assert.equal(res.complete, true);
  assert.equal(res.stoppedKey, null);
  assert.match(res.headline, /COMPLETE/);
  assert.deepEqual(
    res.hops.map((h) => h.status),
    ["PASS", "PASS", "PASS"],
  );
});

test("error hop is STOPPED; earlier PASS, later NOT REACHED", () => {
  const res = deriveJourney(
    hops(["a", "present"], ["b", "error"], ["c", "absent"], ["d", "absent"]),
  );
  assert.equal(res.stoppedKey, "b");
  assert.equal(statusOf(res, "a"), "PASS");
  assert.equal(statusOf(res, "b"), "STOPPED");
  assert.equal(statusOf(res, "c"), "NOT REACHED");
  assert.equal(statusOf(res, "d"), "NOT REACHED");
  assert.match(res.headline, /STOPPED at b/);
  assert.match(res.headline, /last confirmed: a/);
});

test("first absent after last present is the stop", () => {
  const res = deriveJourney(
    hops(["a", "present"], ["b", "present"], ["c", "absent"], ["d", "absent"]),
  );
  assert.equal(res.stoppedKey, "c");
  assert.equal(statusOf(res, "b"), "PASS");
  assert.equal(statusOf(res, "c"), "STOPPED");
  assert.equal(statusOf(res, "d"), "NOT REACHED");
});

test("unknown hop back-fills to PASS when a later hop is present", () => {
  // transformer (unknown) between processor (present) and raw_capture (present).
  const res = deriveJourney(
    hops(["processor", "present"], ["transformer", "unknown"], ["raw_capture", "present"]),
  );
  assert.equal(res.complete, true);
  assert.equal(statusOf(res, "transformer"), "PASS");
});

test("unknown hop stays UNKNOWN when nothing downstream is present (stop is the absent output)", () => {
  // transformer unknown, its output raw_capture absent -> stop at raw_capture,
  // transformer cannot be confirmed.
  const res = deriveJourney(
    hops(["processor", "present"], ["transformer", "unknown"], ["raw_capture", "absent"]),
  );
  assert.equal(res.stoppedKey, "raw_capture");
  assert.equal(statusOf(res, "processor"), "PASS");
  assert.equal(statusOf(res, "transformer"), "UNKNOWN");
  assert.equal(statusOf(res, "raw_capture"), "STOPPED");
});

test("absent hop back-fills to PASS when a later hop is present (a missed probe)", () => {
  // The S3 list probe missed the object, but the ingest row downstream proves it
  // existed, so S3 must have been crossed.
  const res = deriveJourney(
    hops(["upload", "present"], ["s3", "absent"], ["ingest", "present"]),
  );
  assert.equal(res.complete, true);
  assert.equal(statusOf(res, "s3"), "PASS");
});

test("skipped hop is SKIPPED and is not treated as the stop", () => {
  const res = deriveJourney(
    hops(["a", "present"], ["verify", "skipped"]),
  );
  assert.equal(res.complete, true);
  assert.equal(statusOf(res, "verify"), "SKIPPED");
  assert.equal(res.stoppedKey, null);
});

test("skipped hop between present hops does not break the chain", () => {
  const res = deriveJourney(
    hops(["a", "present"], ["b", "skipped"], ["c", "present"]),
  );
  assert.equal(res.complete, true);
  assert.equal(statusOf(res, "b"), "SKIPPED");
  assert.equal(statusOf(res, "c"), "PASS");
});

test("no positive signal anywhere -> INCOMPLETE, first absent is the stop", () => {
  const res = deriveJourney(hops(["a", "absent"], ["b", "absent"]));
  // lastPresent = -1, first absent after -1 is index 0.
  assert.equal(res.stoppedKey, "a");
  assert.equal(statusOf(res, "a"), "STOPPED");
});

test("empty hop list is trivially complete", () => {
  const res = deriveJourney([]);
  assert.equal(res.complete, true);
  assert.equal(res.stoppedKey, null);
});

// ── Timestamp column (ticket 35) ───────────────────────────────────────────────

const BASE = "2026-08-27T12:15:36Z";

test("formatClock: empty or unparseable timestamp renders blank", () => {
  assert.equal(formatClock("", Date.parse(BASE)), "");
  assert.equal(formatClock(undefined, Date.parse(BASE)), "");
  assert.equal(formatClock("not-a-date", Date.parse(BASE)), "");
});

test("formatClock: with a baseline shows UTC clock plus relative offset", () => {
  // 12:17:25 is 1 min 49 s after the 12:15:36 baseline. The Z marks it UTC.
  assert.equal(formatClock("2026-08-27T12:17:25Z", Date.parse(BASE)), "12:17:25Z (+1:49)");
  // the baseline hop itself reads +0:00.
  assert.equal(formatClock(BASE, Date.parse(BASE)), "12:15:36Z (+0:00)");
  // an offset with a two-digit second pads correctly.
  assert.equal(formatClock("2026-08-27T12:15:45Z", Date.parse(BASE)), "12:15:45Z (+0:09)");
});

test("formatClock: without a baseline shows the bare UTC clock", () => {
  assert.equal(formatClock("2026-08-27T12:15:36Z", null), "12:15:36Z");
});

const captureRun = () => ({
  feature: "03_capture_setup.feature",
  scenario: "capture a tree",
  fingerprint: "fp-1",
  steps: [
    { text: "the app is launched with an existing user", passed: true, ts: "2026-08-27T12:16:00Z" },
    { text: "take a tree capture", passed: true, ts: "2026-08-27T12:17:00Z" },
    { text: "the tree image review shows", passed: true, ts: "2026-08-27T12:17:10Z" },
    { text: "the admin panel verify page shows our note", passed: true, ts: "2026-08-27T12:19:09Z" },
  ],
});

const hopByKey = (hops, key) => hops.find((h) => h.key === key);

test("assembleHops: a UI phase hop takes the last matched step timestamp", () => {
  const hops = assembleHops(captureRun(), {});
  // ui_capture matches both "take a tree capture" and "tree image review";
  // the phase timestamp is the later of the two matched steps.
  assert.equal(hopByKey(hops, "ui_capture").ts, "2026-08-27T12:17:10Z");
  assert.equal(hopByKey(hops, "ui_onboard").ts, "2026-08-27T12:16:00Z");
});

test("assembleHops: a backend hop takes its timestamp from probes.json", () => {
  const probes = { processor: { signal: "present", ts: "2026-08-27T12:18:03Z", evidence: "processed" } };
  const hops = assembleHops(captureRun(), probes);
  assert.equal(hopByKey(hops, "processor").ts, "2026-08-27T12:18:03Z");
  // a backend hop with no probe timestamp defaults to blank, never undefined.
  assert.equal(hopByKey(hops, "raw_capture").ts, "");
});

test("assembleHops: the verify hop takes the verify step timestamp", () => {
  const hops = assembleHops(captureRun(), {});
  assert.equal(hopByKey(hops, "verify").ts, "2026-08-27T12:19:09Z");
});

test("render: the table has a Timestamp column with formatted cells", () => {
  const probes = { processor: { signal: "present", ts: "2026-08-27T12:18:03Z", evidence: "processed" } };
  const result = deriveJourney(assembleHops(captureRun(), probes));
  const md = render(result, {});
  assert.match(md, /\| Layer \| Hop \| Status \| Timestamp \| Signal source \| Evidence \|/);
  // baseline is the earliest hop (12:16:00); the capture phase reads its last
  // matched step (12:17:10), i.e. +1:10. The Z marks the clock as UTC.
  assert.match(md, /12:17:10Z \(\+1:10\)/);
  // the processor backend timestamp reaches the table too.
  assert.match(md, /12:18:03Z \(\+2:03\)/);
});
