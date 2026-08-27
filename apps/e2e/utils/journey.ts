import * as fs from "fs";
import * as path from "path";

// Capture Journey recorder. Writes one run record per scenario to
// test-artifacts/journey/run.json: the ordered cucumber steps (text + pass/fail)
// plus the scenario's note fingerprint. utils/capture-journey.mjs joins this with
// the backend probes (scripts/collect-journey-probes.sh) into the trace table.
//
// Always-on and best-effort: every helper swallows its own errors so recording
// never fails a scenario, and it is env-neutral (identical locally and in CI).
// CI runs one scenario per stage, so the last scenario's record wins.

const JOURNEY_DIR = path.join("./test-artifacts", "journey");
const RUN = path.join(JOURNEY_DIR, "run.json");

interface StepRec {
  text: string;
  passed: boolean;
  // UTC ISO 8601 time the step finished; drives the report's Timestamp column.
  ts: string;
}
interface RunRec {
  feature: string;
  scenario: string;
  fingerprint: string;
  steps: StepRec[];
}

let current: RunRec | null = null;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function journeyBeginScenario(world: any): void {
  const uri: string = world?.pickle?.uri || "";
  current = {
    feature: uri ? path.basename(uri) : "",
    scenario: world?.pickle?.name || "scenario",
    fingerprint: "",
    steps: [],
  };
}

// Set from the cucumber Before hook, which generates the per-scenario fingerprint
// after journeyBeginScenario has created the record.
export function journeySetFingerprint(fingerprint: string): void {
  if (current) current.fingerprint = fingerprint || "";
}

export function journeyRecordStep(text: string, passed: boolean): void {
  if (!current) return;
  current.steps.push({ text: text || "", passed, ts: new Date().toISOString() });
}

export function journeyEndScenario(): void {
  if (!current) return;
  try {
    fs.mkdirSync(JOURNEY_DIR, { recursive: true });
    fs.writeFileSync(RUN, JSON.stringify(current, null, 2));
  } catch {
    // best-effort
  }
  current = null;
}
