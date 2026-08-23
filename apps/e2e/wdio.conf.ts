import "dotenv/config";
import { browser } from "@wdio/globals";
import {
  beginScreenRecording,
  saveStepScreenshot,
  endScreenRecording,
} from "./utils/artifacts";
import {
  perfBeginScenario,
  perfResetDevice,
  perfBeginStep,
  perfEndStep,
  perfEndScenario,
} from "./utils/perf";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const config: any = {
  runner: "local",
  specs: ["./features/**/*.feature"],
  exclude: [],
  maxInstances: 1,

  capabilities: [
    {
      platformName: "Android",
      "appium:deviceName": process.env.DEVICE_NAME || "emulator-5554",
      "appium:app": process.env.APK_PATH,
      "appium:automationName": "UiAutomator2",
      "appium:appPackage":
        process.env.APP_PACKAGE || "org.greenstand.android.TreeTracker.local",
      "appium:appActivity":
        "org.greenstand.android.TreeTracker.activities.TreeTrackerActivity",
      "appium:autoGrantPermissions": true,
      "appium:noReset": true,
      "appium:newCommandTimeout": 240,
      "appium:uiautomator2ServerLaunchTimeout": 60000,
      // Keep any enabled accessibility service alive during the UiAutomator2
      // session. By default the driver suppresses a11y services, which can stop
      // Jetpack Compose from emitting its semantics tree. On API 34 the app's
      // AccessibilityManager.isEnabled() flip is already racy (issue #23), so
      // the emulator step forces a11y on; suppressing it again would undo that.
      // With no a11y service enabled there is nothing to suppress, so this is a
      // no-op there and a correct default for a Compose app under UiAutomator2.
      "appium:disableSuppressAccessibilityService": true,
    },
  ],

  // API-34 Compose semantics exposure to UiAutomator is an intermittent per-session race
  // (issue #23) that a11y enablement does not fix - proven: a fully BOUND a11y service still
  // did not expose. The failure lands at onboarding start (empty tree), before any app state,
  // so a spec retry restarts the session (new UiAutomator2 connection = a fresh roll of the
  // race) and re-attempts onboarding cleanly. This makes the API-34 real-camera a reliable
  // BEST-EFFORT signal (NOT the required gate - that stays the deterministic API-30 pipeline).
  // Env-driven and defaults to 0, so the API-30 green pipeline keeps zero retries.
  specFileRetries: Number(process.env.E2E_SPEC_RETRIES) || 0,
  specFileRetriesDelay: 3,

  logLevel: "warn",
  bail: 0,
  waitforTimeout: 15000,
  connectionRetryTimeout: 120000,
  connectionRetryCount: 3,

  services: [
    [
      "appium",
      {
        command: "appium",
        args: {
          relaxedSecurity: true,
          log: "./test-artifacts/appium.log",
        },
      },
    ],
  ],

  framework: "@wdio/cucumber-framework",

  reporters: [
    "spec",
    [
      "allure",
      {
        outputDir: "./test-artifacts/allure-results",
        disableWebdriverStepsReporting: false,
        useCucumberStepReporter: true,
      },
    ],
  ],

  cucumberOpts: {
    require: ["./features/step-definitions/**/*.ts"],
    requireModule: ["ts-node/register"],
    backtrace: false,
    dryRun: false,
    failFast: false,
    snippets: true,
    source: true,
    strict: false,
    tags: process.env.WDIO_TAGS || "not @skip",
    // Per-step timeout. Long because `the admin panel verify page shows our note`
    // polls /verify for up to 360s while the backend ingest pipeline catches up.
    timeout: 420000,
    ignoreUndefinedDefinitions: false,
  },

  // ─── Evidence capture (screenshots + full-scenario emulator video) ──────────
  // Best-effort hooks; each helper swallows its own errors so capture never
  // fails a test. Env-neutral: identical behavior locally and in CI, and a
  // driver without screen recording degrades silently. See utils/artifacts.ts.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  beforeScenario: async function (world: any) {
    perfBeginScenario(world?.pickle?.name || "scenario");
    await perfResetDevice();
    await beginScreenRecording();
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  beforeStep: function () {
    perfBeginStep();
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  afterStep: async function (step: any, _scenario: any, result: any) {
    perfEndStep(step?.text || "", result?.passed !== false);
    await saveStepScreenshot(step?.text || "step");
    // On a step failure, dump the UI hierarchy to stdout so the CI log (always
    // reachable) shows exactly what was on screen and the real element ids,
    // without depending on downloading the screenshot artifact.
    //
    // With E2E_DUMP_ALL set, dump after EVERY step (pass or fail). This is the
    // tap-diagnosis mode: comparing the hierarchy before and after a passing
    // "tap" step reveals whether the tap actually changed the screen, and the
    // dumped nodes carry each control's clickable/bounds attributes.
    const dumpAll = !!process.env.E2E_DUMP_ALL;
    const failed = !!(result && result.passed === false);
    if (dumpAll || failed) {
      try {
        const src = await browser.getPageSource();
        const tag = failed ? "ON FAILURE" : "AFTER STEP";
        console.log(
          `\n===== PAGE SOURCE ${tag}: ${step?.text || ""} =====\n${src}\n===== END PAGE SOURCE =====\n`,
        );
      } catch {
        // best-effort
      }
    }
  },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  afterScenario: async function (world: any) {
    await perfEndScenario();
    await endScreenRecording(world?.pickle?.name || "scenario");
  },
};
