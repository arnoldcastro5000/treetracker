import { browser } from "@wdio/globals";
import * as fs from "fs";
import * as path from "path";

// Evidence capture for CI (and local): a full-scenario emulator video plus a
// screenshot after every step. Everything is best-effort and wrapped so a
// capture failure never fails a scenario, and so a non-Android session (or a
// driver that lacks screen recording) degrades silently. Toggle off with
// CAPTURE_ARTIFACTS=0 to keep the suite env-neutral for local runs that don't
// want the overhead.

const ROOT = "./test-artifacts";
const SHOTS = path.join(ROOT, "screenshots");
const VIDEOS = path.join(ROOT, "videos");

const enabled = (): boolean => process.env.CAPTURE_ARTIFACTS !== "0";

const slug = (s: string): string =>
  (s || "scenario").replace(/[^a-zA-Z0-9._-]+/g, "_").slice(0, 80);

let stepIndex = 0;

function ensureDir(dir: string): void {
  fs.mkdirSync(dir, { recursive: true });
}

export async function beginScreenRecording(): Promise<void> {
  if (!enabled()) return;
  stepIndex = 0;
  try {
    // Android `screenrecord` caps at 180s per file. A longer timeLimit makes Appium
    // record multiple segments and merge them with ffmpeg on stop; the CI runner has
    // no ffmpeg, so that merge fails and Appium returns only the last (near-empty)
    // segment - an intermittent near-0s video whenever the scenario runs past 180s
    // (the `/verify` poll pushes it there). So cap at one 180s segment: no merge, no
    // dependency. The on-device work (onboard -> capture -> upload) finishes well
    // inside 180s; the dropped tail is the emulator sitting idle while `/verify`
    // polls in desktop Chrome, which the emulator video cannot show anyway.
    // forceRestart drops any recording left over from a prior scenario.
    await browser.startRecordingScreen({ timeLimit: 180, forceRestart: true } as never);
  } catch {
    // driver has no screen recording (or not a mobile session), skip silently
  }
}

export async function saveStepScreenshot(label: string): Promise<void> {
  if (!enabled()) return;
  try {
    ensureDir(SHOTS);
    const name = `${String(++stepIndex).padStart(3, "0")}-${slug(label)}.png`;
    await browser.saveScreenshot(path.join(SHOTS, name));
  } catch {
    // best-effort
  }
}

export async function endScreenRecording(scenarioName: string): Promise<void> {
  if (!enabled()) return;
  try {
    const b64 = await browser.stopRecordingScreen();
    if (b64) {
      ensureDir(VIDEOS);
      fs.writeFileSync(path.join(VIDEOS, `${slug(scenarioName)}.mp4`), Buffer.from(b64, "base64"));
    }
  } catch {
    // best-effort
  }
}
