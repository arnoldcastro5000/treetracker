import { browser } from "@wdio/globals";
import * as fs from "fs";
import * as path from "path";

// Performance + stress instrumentation for the 02 onboarding loop. Everything is
// gated on E2E_PERF=1 and best-effort (never fails a scenario), so normal PR runs
// and local runs are completely unaffected (ticket 10 guardrail).
//
// One JSON object is appended to test-artifacts/perf/runs.jsonl per scenario
// (== per stress iteration). utils/perf-summary.mjs aggregates them.

const PERF_DIR = path.join("./test-artifacts", "perf");
const RUNS = path.join(PERF_DIR, "runs.jsonl");

export const perfEnabled = (): boolean => process.env.E2E_PERF === "1";

const APP_PKG =
  process.env.APP_PACKAGE || "org.greenstand.android.TreeTracker.local";

interface StepRec {
  text: string;
  ms: number;
  passed: boolean;
}
interface ScenarioRec {
  iteration: number;
  name: string;
  ms: number; // full scenario wall-clock (time-to-dashboard proxy)
  passed: boolean;
  steps: StepRec[];
  marks: Record<string, number>; // derived named durations (launch, transitions)
  taps: Record<string, number[]>; // control label -> attempt counts observed
  fallbacks: string[]; // labels that fell back to coordinate/desc (want empty)
  device: Record<string, number>; // gfxinfo / meminfo, best-effort
}

let iteration = 0;
let scenarioStart = 0;
let stepStart = 0;
let current: ScenarioRec | null = null;

export function perfBeginScenario(name: string): void {
  if (!perfEnabled()) return;
  iteration += 1;
  scenarioStart = Date.now();
  current = {
    iteration,
    name: name || `iteration-${iteration}`,
    ms: 0,
    passed: true,
    steps: [],
    marks: {},
    taps: {},
    fallbacks: [],
    device: {},
  };
}

// Reset the emulator's frame stats so gfxinfo measures only this iteration.
export async function perfResetDevice(): Promise<void> {
  if (!perfEnabled()) return;
  try {
    await sh(["dumpsys", "gfxinfo", APP_PKG, "reset"]);
  } catch {
    // best-effort
  }
}

export function perfBeginStep(): void {
  if (!perfEnabled()) return;
  stepStart = Date.now();
}

export function perfEndStep(text: string, passed: boolean): void {
  if (!perfEnabled() || !current) return;
  current.steps.push({ text: text || "", ms: Date.now() - stepStart, passed });
  if (passed === false) current.passed = false;
}

// Record how many attempts a tagged control needed (from tapTagUntil). A value > 1
// means the first tap did not register; a rising trend across iterations is an
// early degradation signal before an outright failure.
export function perfTapAttempts(label: string, attempts: number): void {
  if (!perfEnabled() || !current) return;
  (current.taps[label] ||= []).push(attempts);
}

// Record that a control fell back to a coordinate/desc tap (tag not usable). Want
// zero across a whole run; any occurrence means an id regressed.
export function perfFallback(label: string): void {
  if (!perfEnabled() || !current) return;
  current.fallbacks.push(label);
}

export async function perfEndScenario(): Promise<void> {
  if (!perfEnabled() || !current) return;
  current.ms = Date.now() - scenarioStart;
  // Derive named marks from step texts (best-effort; a "Then I should see X" step's
  // duration is the wait for screen X to appear after the preceding tap, i.e. the
  // transition latency into X).
  for (const s of current.steps) {
    const t = s.text.toLowerCase();
    if (t.includes("launched fresh")) current.marks.launch = s.ms;
    else if (t.includes('"privacy policy"')) current.marks.t_to_privacy = s.ms;
    else if (t.includes('"phone"')) current.marks.t_to_phone = s.ms;
    else if (t.includes('"first name"')) current.marks.t_to_name = s.ms;
    else if (t.includes("reach the dashboard")) current.marks.t_to_dashboard = s.ms;
  }
  try {
    current.device = await collectDevice();
  } catch {
    // best-effort
  }
  try {
    fs.mkdirSync(PERF_DIR, { recursive: true });
    fs.appendFileSync(RUNS, JSON.stringify(current) + "\n");
  } catch {
    // best-effort
  }
  current = null;
}

async function collectDevice(): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  const gfx = await sh(["dumpsys", "gfxinfo", APP_PKG]);
  const jank = /Janky frames:\s+\d+\s+\(([\d.]+)%\)/.exec(gfx);
  if (jank) out.jank_pct = parseFloat(jank[1]);
  for (const [key, pctl] of [
    ["frame_p50_ms", "50th"],
    ["frame_p90_ms", "90th"],
    ["frame_p95_ms", "95th"],
    ["frame_p99_ms", "99th"],
  ] as const) {
    const m = new RegExp(`${pctl} percentile:\\s+(\\d+)ms`).exec(gfx);
    if (m) out[key] = parseInt(m[1], 10);
  }
  const mem = await sh(["dumpsys", "meminfo", APP_PKG]);
  const pss = /TOTAL(?:\s+PSS)?:?\s+(\d+)/.exec(mem);
  if (pss) out.pss_kb = parseInt(pss[1], 10);
  return out;
}

async function sh(args: string[]): Promise<string> {
  const res = await browser.execute("mobile: shell", {
    command: args[0],
    args: args.slice(1),
  });
  return typeof res === "string" ? res : String(res ?? "");
}
