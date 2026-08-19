// Aggregate the per-iteration perf records (test-artifacts/perf/runs.jsonl) into a
// summary: pass/fail, timing percentiles + variance, tap stability, fallbacks, and
// device metrics. Prints a markdown table to stdout, appends it to the GitHub Actions
// job summary ($GITHUB_STEP_SUMMARY), and writes summary.json. Report-only (Phase 1);
// no thresholds / gating here.
//
// Usage: node utils/perf-summary.mjs [runsPath]

import { readFileSync, writeFileSync, appendFileSync, existsSync } from "fs";

const runsPath = process.argv[2] || "test-artifacts/perf/runs.jsonl";
if (!existsSync(runsPath)) {
  console.log(`[perf-summary] no runs file at ${runsPath}, nothing to summarize`);
  process.exit(0);
}

const records = readFileSync(runsPath, "utf8")
  .split("\n")
  .filter((l) => l.trim())
  .map((l) => JSON.parse(l));

const n = records.length;
const passed = records.filter((r) => r.passed).length;

// ── stats helpers ────────────────────────────────────────────────────────────
const num = (xs) => xs.filter((x) => typeof x === "number" && !isNaN(x));
const pct = (sorted, p) =>
  sorted.length ? sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)] : NaN;
function stats(xs) {
  const a = num(xs).slice().sort((x, y) => x - y);
  if (!a.length) return null;
  const mean = a.reduce((s, x) => s + x, 0) / a.length;
  const sd = Math.sqrt(a.reduce((s, x) => s + (x - mean) ** 2, 0) / a.length);
  return {
    n: a.length,
    min: a[0],
    median: pct(a, 50),
    mean: Math.round(mean),
    p90: pct(a, 90),
    p95: pct(a, 95),
    max: a[a.length - 1],
    stddev: Math.round(sd),
    cov: mean ? +(sd / mean).toFixed(2) : 0,
  };
}

// Warm iterations exclude iteration 1 (dex2oat / JIT warmup outlier).
const warm = records.filter((r) => r.iteration > 1);
const pull = (recs, fn) => recs.map(fn);

const timing = {
  "time-to-dashboard (total)": stats(pull(warm, (r) => r.ms)),
  "cold launch": stats(pull(warm, (r) => r.marks?.launch)),
  "-> privacy": stats(pull(warm, (r) => r.marks?.t_to_privacy)),
  "-> phone": stats(pull(warm, (r) => r.marks?.t_to_phone)),
  "-> name": stats(pull(warm, (r) => r.marks?.t_to_name)),
  "-> dashboard (selfie flow)": stats(pull(warm, (r) => r.marks?.t_to_dashboard)),
};
const device = {
  "jank %": stats(pull(warm, (r) => r.device?.jank_pct)),
  "frame p95 (ms)": stats(pull(warm, (r) => r.device?.frame_p95_ms)),
  "app PSS (KB)": stats(pull(warm, (r) => r.device?.pss_kb)),
};

// Tap stability: how often a control needed more than one attempt.
const allTaps = [];
for (const r of records) for (const arr of Object.values(r.taps || {})) allTaps.push(...arr);
const multiTap = allTaps.filter((a) => a > 1).length;
const maxAttempts = allTaps.length ? Math.max(...allTaps) : 0;
const fallbacks = records.reduce((s, r) => s + (r.fallbacks?.length || 0), 0);

// iteration-1 outlier, reported separately
const iter1 = records.find((r) => r.iteration === 1);

// ── render ───────────────────────────────────────────────────────────────────
const fmt = (s) =>
  s ? `${s.min} / ${s.median} / ${s.mean} / ${s.p95} / ${s.max} | ${s.stddev} | ${s.cov}` : "n/a";
const lines = [];
lines.push(`## 02 stress + performance baseline`);
lines.push("");
lines.push(`Iterations: **${n}** &nbsp; Passed: **${passed}/${n}** &nbsp; Fallbacks (want 0): **${fallbacks}** &nbsp; Taps needing >1 attempt: **${multiTap}** (max ${maxAttempts})`);
lines.push("");
lines.push(`Warm stats exclude iteration 1 (warmup). Columns: **min / median / mean / p95 / max | stddev | CoV** (ms unless noted).`);
lines.push("");
lines.push(`### Timing`);
lines.push(`| metric | min / med / mean / p95 / max | stddev | CoV |`);
lines.push(`| --- | --- | --- | --- |`);
for (const [k, s] of Object.entries(timing)) {
  lines.push(`| ${k} | ${s ? `${s.min} / ${s.median} / ${s.mean} / ${s.p95} / ${s.max}` : "n/a"} | ${s ? s.stddev : "-"} | ${s ? s.cov : "-"} |`);
}
lines.push("");
lines.push(`### Device (relative only: software-GPU emulator, not real-device UX)`);
lines.push(`| metric | min / med / mean / p95 / max | stddev | CoV |`);
lines.push(`| --- | --- | --- | --- |`);
for (const [k, s] of Object.entries(device)) {
  lines.push(`| ${k} | ${s ? `${s.min} / ${s.median} / ${s.mean} / ${s.p95} / ${s.max}` : "n/a"} | ${s ? s.stddev : "-"} | ${s ? s.cov : "-"} |`);
}
if (iter1) {
  lines.push("");
  lines.push(`Iteration 1 (warmup, excluded above): time-to-dashboard ${iter1.ms} ms, cold launch ${iter1.marks?.launch ?? "n/a"} ms.`);
}
const md = lines.join("\n");
console.log("\n" + md + "\n");

const summary = { n, passed, fallbacks, multiTap, maxAttempts, timing, device, iter1: iter1 ? { ms: iter1.ms, launch: iter1.marks?.launch } : null };
try { writeFileSync("test-artifacts/perf/summary.json", JSON.stringify(summary, null, 2)); } catch { /* ignore */ }
if (process.env.GITHUB_STEP_SUMMARY) {
  try { appendFileSync(process.env.GITHUB_STEP_SUMMARY, md + "\n"); } catch { /* ignore */ }
}
