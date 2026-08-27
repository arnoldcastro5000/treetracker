// Capture Journey report generator.
//
// Joins the scattered per-hop signals of one capture e2e run into a single ordered
// table that pinpoints where the capture stopped, and renders it as markdown to
// stdout, to test-artifacts/journey/summary.json, and to $GITHUB_STEP_SUMMARY.
//
// Inputs (both best-effort; a missing input degrades to UNKNOWN, never an error):
//   test-artifacts/journey/run.json    - written by utils/journey.ts (wdio hook):
//                                        { feature, scenario, fingerprint, steps:[{text,passed}] }
//   test-artifacts/journey/probes.json - written by scripts/collect-journey-probes.sh:
//                                        { <hopKey>: { signal, evidence } }
//
// Report-only (Phase 1): no thresholds, no gating, and it never fails the job.
//
// Usage: node utils/capture-journey.mjs [journeyDir]

import { readFileSync, writeFileSync, appendFileSync, existsSync } from "fs";
import path from "path";

// ── Pure status-derivation (unit-tested in capture-journey.test.mjs) ───────────
//
// Each hop carries a `signal`: one of
//   present  - a positive signal proves data reached this hop
//   absent   - checked, no positive signal found
//   error    - an explicit failure at this hop
//   unknown  - no signal is wired for this hop (cannot determine directly)
//   skipped  - the hop was not exercised (env-disabled)
//
// deriveJourney assigns each hop a final `status` and finds the stop boundary.
export function deriveJourney(hops) {
  const n = hops.length;
  const sig = (i) => hops[i].signal;

  let lastPresent = -1;
  for (let i = 0; i < n; i++) if (sig(i) === "present") lastPresent = i;

  let firstError = -1;
  for (let i = 0; i < n; i++)
    if (sig(i) === "error") {
      firstError = i;
      break;
    }

  let firstAbsentAfter = -1;
  for (let i = lastPresent + 1; i < n; i++)
    if (sig(i) === "absent") {
      firstAbsentAfter = i;
      break;
    }

  const cands = [firstError, firstAbsentAfter].filter((x) => x >= 0);
  const stopIndex = cands.length ? Math.min(...cands) : -1;

  const laterPresent = (i) => {
    for (let j = i + 1; j < n; j++) if (sig(j) === "present") return true;
    return false;
  };

  const out = hops.map((h, i) => {
    let status;
    if (sig(i) === "skipped") status = "SKIPPED";
    else if (stopIndex >= 0 && i === stopIndex) status = "STOPPED";
    else if (stopIndex >= 0 && i > stopIndex) status = "NOT REACHED";
    else {
      const s = sig(i);
      if (s === "present") status = "PASS";
      else if (s === "error") status = "STOPPED";
      // unknown/absent before the stop: data demonstrably crossed if a later hop
      // is present; otherwise we genuinely cannot tell.
      else status = laterPresent(i) ? "PASS" : "UNKNOWN";
    }
    return { ...h, status };
  });

  const stoppedKey = stopIndex >= 0 ? hops[stopIndex].key : null;
  const complete =
    stopIndex < 0 && out.every((h) => h.status === "PASS" || h.status === "SKIPPED");

  let headline;
  if (stopIndex >= 0) {
    let prev = null;
    for (let j = stopIndex - 1; j >= 0; j--)
      if (out[j].status === "PASS") {
        prev = out[j];
        break;
      }
    headline =
      `Capture Journey: STOPPED at ${hops[stopIndex].hop}` +
      (prev ? ` (last confirmed: ${prev.hop} via ${prev.source})` : "");
  } else if (complete) {
    headline = "Capture Journey: COMPLETE";
  } else {
    const tail = lastPresent >= 0 ? hops[lastPresent].hop : "start";
    headline = `Capture Journey: INCOMPLETE (no positive signal past ${tail})`;
  }

  return { hops: out, headline, stoppedKey, complete };
}

// ── Assembly: build the ordered hop list from run.json + probes.json ───────────

// UI phase maps. A phase's signal is derived from the recorded cucumber steps
// whose text matches any of its substrings (case-insensitive).
const CAPTURE_UI_PHASES = [
  { key: "ui_onboard", hop: "Onboard / dashboard", match: ["existing user", "reach the dashboard"] },
  { key: "ui_navigate", hop: "Navigate to capture", match: ["track", "first user", "organization", "capture screen"] },
  { key: "ui_capture", hop: "Capture tree (UI)", match: ["take a tree capture", "tree image review"] },
  { key: "ui_note", hop: "Add note (UI)", match: ["add a unique note"] },
  { key: "ui_approve", hop: "Approve capture (UI)", match: ["accept the tree capture", "back on the capture"] },
  { key: "ui_upload", hop: "Upload (UI)", match: ["upload the captures", "ready-to-upload count", "uploaded count"] },
];

const SIGNUP_UI_PHASES = [
  { key: "ui_launch", hop: "Launch", match: ["launched fresh"] },
  { key: "ui_language", hop: "Language", match: ['"english"'] },
  { key: "ui_privacy", hop: "Privacy", match: ["privacy policy"] },
  { key: "ui_phone", hop: "Phone", match: ['"phone"', "enter phone"] },
  { key: "ui_name", hop: "Name", match: ["first name", "enter name"] },
  { key: "ui_dashboard", hop: "Dashboard", match: ["reach the dashboard"] },
];

// Backend hops (capture flow only), in pipeline order. Signals come from probes.json.
const BACKEND_HOPS = [
  { key: "capture", layer: "Android internal", hop: "Capture (CameraX)", source: "logcat CameraXApp" },
  { key: "bundle", layer: "Android internal", hop: "Bundle build", source: "logcat TreeUploader" },
  { key: "upload", layer: "Android internal", hop: "Upload (app)", source: "logcat TreeUploader" },
  { key: "s3", layer: "Backend", hop: "S3 object", source: "batch-uploads LastModified" },
  { key: "ingest", layer: "Backend", hop: "Ingest (bulk_tree_upload)", source: "bulk_tree_upload.created_at" },
  { key: "processor", layer: "Backend", hop: "Processor", source: "bulk_tree_upload.processed_at" },
  { key: "transformer", layer: "Backend", hop: "Transformer", source: "processor forward" },
  { key: "raw_capture", layer: "Backend", hop: "raw_capture", source: "field_data.raw_capture" },
];

// The active feature decides the node set: 03_capture_setup runs the full pipeline,
// so it gets the backend + verify hops; 02_signup_flow is onboarding-only (no
// capture), so it gets the UI phases alone.
const isCaptureFlow = (feature) => /03|capture/i.test(feature || "");

function uiPhaseHop(phase, steps) {
  const matched = steps.filter((s) =>
    phase.match.some((m) => (s.text || "").toLowerCase().includes(m)),
  );
  let signal, evidence;
  if (!matched.length) {
    signal = "absent";
    evidence = "no step reached";
  } else if (matched.some((s) => s.passed === false)) {
    signal = "error";
    evidence = matched.find((s) => s.passed === false).text;
  } else {
    signal = "present";
    evidence = `${matched.length} step(s) passed`;
  }
  // A phase spans one or more steps; its timestamp is when the phase last ran,
  // i.e. the last matched step's time (blank if no step matched or none carried a time).
  const ts = matched.length ? matched[matched.length - 1].ts || "" : "";
  return { key: phase.key, layer: "Android UI", hop: phase.hop, signal, source: "cucumber step", evidence, ts };
}

export function assembleHops(run, probes) {
  const steps = Array.isArray(run.steps) ? run.steps : [];
  const capture = isCaptureFlow(run.feature);
  const uiSpec = capture ? CAPTURE_UI_PHASES : SIGNUP_UI_PHASES;
  const hops = uiSpec.map((p) => uiPhaseHop(p, steps));

  if (!capture) return hops;

  for (const h of BACKEND_HOPS) {
    const p = probes[h.key] || {};
    hops.push({
      key: h.key,
      layer: h.layer,
      hop: h.hop,
      signal: p.signal || "unknown",
      source: h.source,
      evidence: p.evidence || "",
      ts: p.ts || "",
    });
  }

  // Verify hop comes from the cucumber verify step; probes may override to skipped.
  const vstep = steps.find((s) => (s.text || "").toLowerCase().includes("verify page"));
  const vprobe = probes.verify || {};
  let vsignal, vevidence;
  if (vprobe.signal === "skipped") {
    vsignal = "skipped";
    vevidence = vprobe.evidence || "E2E_SKIP_ADMIN_VERIFY";
  } else if (vstep) {
    vsignal = vstep.passed === false ? "error" : "present";
    vevidence = vstep.text;
  } else {
    vsignal = "absent";
    vevidence = "verify step did not run";
  }
  const vts = vprobe.signal === "skipped" ? "" : vstep ? vstep.ts || "" : "";
  hops.push({ key: "verify", layer: "Frontend", hop: "Admin /verify", signal: vsignal, source: "cucumber /verify", evidence: vevidence, ts: vts });

  return hops;
}

// ── Render ─────────────────────────────────────────────────────────────────────

const SYMBOL = {
  PASS: "✓",
  STOPPED: "⛔",
  "NOT REACHED": "·",
  UNKNOWN: "?",
  SKIPPED: "–",
};

// Format a hop timestamp for the report: the UTC wall clock (with a Z marker so
// the reader knows it is UTC), plus a relative offset from the earliest hop
// timestamp (baselineMs). A blank or unparseable timestamp renders blank, never
// breaking the row.
const pad2 = (n) => String(n).padStart(2, "0");
export function formatClock(iso, baselineMs) {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "";
  const d = new Date(t);
  const clock = `${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}:${pad2(d.getUTCSeconds())}Z`;
  if (baselineMs == null || Number.isNaN(baselineMs) || t < baselineMs) return clock;
  const off = Math.round((t - baselineMs) / 1000);
  return `${clock} (+${Math.floor(off / 60)}:${pad2(off % 60)})`;
}

export function render(result, meta) {
  const lines = [];
  lines.push(`## ${result.headline}`);
  lines.push("");
  const bits = [];
  if (meta.stage) bits.push(`Stage: **${meta.stage}**`);
  if (meta.scenario) bits.push(`Scenario: ${meta.scenario}`);
  if (meta.fingerprint) bits.push(`Fingerprint: \`${meta.fingerprint}\``);
  if (bits.length) {
    lines.push(bits.join(" &nbsp; "));
    lines.push("");
  }
  // Baseline for the relative offset: the earliest hop timestamp (the first
  // step, which is effectively scenario start; robust when a hop has no time).
  const times = result.hops
    .map((h) => Date.parse(h.ts))
    .filter((t) => !Number.isNaN(t));
  const baselineMs = times.length ? Math.min(...times) : null;
  lines.push("| Layer | Hop | Status | Timestamp | Signal source | Evidence |");
  lines.push("| --- | --- | --- | --- | --- | --- |");
  for (const h of result.hops) {
    const status = `${SYMBOL[h.status] || ""} ${h.status}`.trim();
    const ts = formatClock(h.ts, baselineMs);
    lines.push(`| ${h.layer} | ${h.hop} | ${status} | ${ts} | ${h.source} | ${h.evidence || ""} |`);
  }
  return lines.join("\n");
}

// ── CLI ────────────────────────────────────────────────────────────────────────

function readJson(file, fallback) {
  try {
    if (!existsSync(file)) return fallback;
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function main() {
  const dir = process.argv[2] || path.join("test-artifacts", "journey");
  const run = readJson(path.join(dir, "run.json"), {});
  const probes = readJson(path.join(dir, "probes.json"), {});

  const hops = assembleHops(run, probes);
  const result = deriveJourney(hops);
  const meta = {
    stage: process.env.STAGE,
    scenario: run.scenario,
    fingerprint: run.fingerprint,
  };
  const md = render(result, meta);
  console.log("\n" + md + "\n");

  try {
    writeFileSync(
      path.join(dir, "summary.json"),
      JSON.stringify({ ...meta, headline: result.headline, stoppedKey: result.stoppedKey, complete: result.complete, hops: result.hops }, null, 2),
    );
  } catch {
    /* best-effort */
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    try {
      appendFileSync(process.env.GITHUB_STEP_SUMMARY, md + "\n");
    } catch {
      /* best-effort */
    }
  }
}

// Run main only as a CLI, not when imported by the test.
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
