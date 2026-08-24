// Unit tests for the pure status-derivation logic of the Capture Journey report.
// Runs with the Node built-in test runner (no dependencies), so it works even when
// the e2e node_modules is absent: `node --test utils/capture-journey.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { deriveJourney } from "./capture-journey.mjs";

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
