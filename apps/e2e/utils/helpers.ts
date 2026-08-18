import { $, browser } from "@wdio/globals";

// Must match the wdio cap `appium:appPackage`. Read from env so the suite can
// target any build (local/dev/prod) without code changes.
export const APP_PACKAGE =
  process.env.APP_PACKAGE || "org.greenstand.android.TreeTracker.local";

// ─── Screen Layout Constants ──────────────────────────────────────────────────
// Physical screen: 1080 × 2400 px, density 420 dpi, gesture navigation.
//
// Empirically measured:
//   Bottom ActionBar centre Y ≈ 2230
//   "D" notification badge: x=938–1064, y=2195–2321
//   "Sync" overlay:   x=800–977,  y=1957–2063
//   "Sensors" overlay: x=800–1027, y=2063–2189
//
// Jetpack Compose buttons do NOT set android:clickable=true in the UiAutomator2
// accessibility tree — all icon button taps use coordinates.

const ACTION_BAR_Y  = 2230;
const RIGHT_BTN_X   = 860;   // left of the "D" badge (starts x=938)
const TOP_BAR_Y     = 136;
const LIST_FIRST_Y  = 63 + 147 + 120; // ≈ 330

// ─── Element Selectors ────────────────────────────────────────────────────────

export const byText = (text: string) =>
  $(`android=new UiSelector().text("${text}")`);

export const byTextContains = (text: string) =>
  $(`android=new UiSelector().textContains("${text}")`);

export const byDesc = (desc: string) =>
  $(`android=new UiSelector().description("${desc}")`);

export const byClass = (className: string, index = 0) =>
  $(`android=new UiSelector().className("${className}").instance(${index})`);

// ─── Coordinate Tap ───────────────────────────────────────────────────────────

export async function tapAt(x: number, y: number): Promise<void> {
  const px = Math.round(x);
  const py = Math.round(y);
  // Prefer UiAutomator2's native click gesture. A raw W3C pointer action can land
  // on the right pixel without triggering a Compose button's onClick (observed on
  // this driver: an on-target tap on the forward arrow produced no navigation);
  // clickGesture dispatches a real click and is reliable across Compose controls.
  try {
    await browser.execute("mobile: clickGesture", { x: px, y: py });
    console.log(`[tapAt] clickGesture ok x=${px} y=${py}`);
    return;
  } catch (e) {
    console.log(
      `[tapAt] clickGesture FAILED x=${px} y=${py} err=${(e as Error)?.message || String(e)} -> W3C fallback`,
    );
    // Fallback for drivers without clickGesture.
    await browser
      .action("pointer", { parameters: { pointerType: "touch" } })
      .move({ duration: 0, x: px, y: py })
      .down({ button: 0 })
      .pause(100)
      .up({ button: 0 })
      .perform();
  }
}

// ─── Wait Helpers ─────────────────────────────────────────────────────────────

export async function waitForVisible(text: string, timeout = 20000): Promise<void> {
  await (await byText(text)).waitForDisplayed({ timeout });
}

export async function isVisible(text: string): Promise<boolean> {
  try {
    return await (await byText(text)).isDisplayed();
  } catch {
    return false;
  }
}

export async function isVisibleWithTimeout(text: string, timeout: number): Promise<boolean> {
  try {
    await (await byText(text)).waitForDisplayed({ timeout });
    return true;
  } catch {
    return false;
  }
}

// ─── Tap Helpers ──────────────────────────────────────────────────────────────

export async function tapText(text: string, timeout = 10000): Promise<void> {
  const el = await byText(text);
  await el.waitForDisplayed({ timeout });
  // Compose text controls report clickable=false in the accessibility tree, so a
  // WebDriver element .click() dispatches to a node the framework does not treat
  // as interactive and the button's onClick never fires. Tap the centre of the
  // element's real bounds by coordinate instead, which reaches the Compose
  // pointerInput handler underneath.
  const bounds = await el.getAttribute("bounds").catch(() => null);
  const c = bounds ? boundsCentre(bounds) : null;
  if (c) {
    await tapAt(c.x, c.y);
    return;
  }
  await el.click();
}

export async function tapDesc(desc: string, timeout = 10000): Promise<void> {
  const el = await byDesc(desc);
  await el.waitForDisplayed({ timeout });
  await el.click();
}

export async function tapSettingsIcon(): Promise<void> {
  await tapAt(120, TOP_BAR_Y);
}

export async function tapRightArrow(): Promise<void> {
  // Preferred: content-description, present on app versions that label the arrow.
  // Quick, non-blocking check so we don't wait the full timeout when it is absent.
  try {
    const btn = await byDesc("Navigate forward");
    if (await btn.isDisplayed().catch(() => false)) {
      await btn.click();
      return;
    }
  } catch {
    // fall through to the coordinate tap
  }
  // DIAGNOSTIC SWEEP: the forward ArrowButton has no accessibility node at all
  // and taps at its visual centre (886,2001) do not fire it, yet an earlier probe
  // navigated from some other point. Sweep coordinates x methods and log which
  // (point, method) actually leaves the screen, so the real handler can lock it in.
  await browser.pause(800);
  const { width, height } = await browser.getWindowSize();
  const before = await safeSource();
  const changed = async () => (await safeSource()) !== before;
  const pts: Array<[number, number]> = [
    [0.82, 0.855],
    [0.82, 0.88],
    [0.82, 0.9],
    [0.82, 0.92],
    [0.77, 0.855],
    [0.87, 0.855],
    [0.82, 0.83],
  ];
  for (const [xf, yf] of pts) {
    const x = Math.round(width * xf);
    const y = Math.round(height * yf);
    for (const method of ["clickGesture", "inputTap"] as const) {
      if (method === "clickGesture") {
        await browser.execute("mobile: clickGesture", { x, y }).catch(() => {});
      } else {
        await inputTap(x, y, "sweep");
      }
      await browser.pause(600);
      if (await changed()) {
        console.log(`[tapRightArrow] SWEEP HIT ${method} @ ${x},${y} (${xf},${yf})`);
        return;
      }
      console.log(`[tapRightArrow] sweep miss ${method} @ ${x},${y}`);
    }
  }
  console.log("[tapRightArrow] SWEEP exhausted, nothing navigated");
}

// Accept the Privacy Policy dialog. Its confirm control is an ApprovalButton
// (TreeTrackerButton, contentDescription=null) centred horizontally at the
// dialog's bottom, so it has no queryable node; tap by coordinate and retry
// until the dialog's "Privacy Policy" title is gone.
export async function acceptPrivacyPolicy(): Promise<void> {
  await waitForVisible("Privacy Policy", 15000);
  const gone = async () => !(await isVisible("Privacy Policy"));
  await tapFractionUntil(0.5, 0.905, gone, "acceptPrivacyPolicy");
}

// Inject a real tap (MotionEvent) at a screen-fraction point via `input tap`,
// retrying until `success` holds or the attempts are exhausted. This app's
// Compose controls are pointerInput{detectTapGestures} with no queryable node,
// and a tap can be dropped if sent before the control settles; a real input
// event plus a success-gated retry is the robust way to drive them by coordinate.
async function tapFractionUntil(
  xFrac: number,
  yFrac: number,
  success: () => Promise<boolean>,
  label = "tap",
  tries = 5,
): Promise<boolean> {
  const { width, height } = await browser.getWindowSize();
  const x = Math.round(width * xFrac);
  const y = Math.round(height * yFrac);
  for (let i = 0; i < tries; i++) {
    await browser.pause(i === 0 ? 700 : 500);
    await inputTap(x, y, label);
    await browser.pause(700);
    if (await success()) {
      if (i > 0) console.log(`[${label}] succeeded on attempt ${i + 1}`);
      return true;
    }
    console.log(`[${label}] attempt ${i + 1} had no effect, retrying`);
  }
  console.log(`[${label}] gave up after ${tries} attempts`);
  return false;
}

// Inject a genuine tap via `adb shell input tap` (relaxedSecurity is enabled on
// the Appium server). This dispatches a real MotionEvent through the input
// system, which Compose's detectTapGestures handles like a finger, unlike
// mobile: clickGesture / W3C pointer actions which do not reliably fire it here.
async function inputTap(x: number, y: number, label = "inputTap"): Promise<void> {
  console.log(`[${label}] input tap ${x},${y}`);
  await browser.execute("mobile: shell", {
    command: "input",
    args: ["tap", String(x), String(y)],
  });
}

// getPageSource() that never throws, for cheap before/after screen comparisons.
async function safeSource(): Promise<string> {
  try {
    return await browser.getPageSource();
  } catch {
    return "";
  }
}

// Parse a UiAutomator2 bounds string "[x1,y1][x2,y2]" into its centre point.
function boundsCentre(bounds: string): { x: number; y: number } | null {
  const m = bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
  if (!m) return null;
  const [x1, y1, x2, y2] = [+m[1], +m[2], +m[3], +m[4]];
  return { x: Math.round((x1 + x2) / 2), y: Math.round((y1 + y2) / 2) };
}

/**
 * Tap the first list item (user/wallet card).
 * Prefers an element-based tap when an anchor text is provided — robust against
 * grid-vs-list layout differences. Falls back to a coordinate tap otherwise.
 */
export async function tapFirstListItem(anchorText?: string, timeout = 12000): Promise<void> {
  if (anchorText) {
    const el = await byText(anchorText);
    await el.waitForDisplayed({ timeout });
    await el.click();
    await browser.pause(600);
    return;
  }
  await browser.pause(1500);
  await tapAt(540, LIST_FIRST_Y);
  await browser.pause(800);
}

/**
 * Tap the first list item then tap the right arrow.
 * Used in UserSelect (2.1.3): tapping a user card selects it;
 * right arrow advances to WalletSelect.
 */
export async function tapFirstListItemAndAdvance(anchorText?: string, timeout = 12000): Promise<void> {
  await tapFirstListItem(anchorText, timeout);
  await tapRightArrow();
}

// ─── App Lifecycle ────────────────────────────────────────────────────────────

export async function launchFresh(): Promise<void> {
  await browser.terminateApp(APP_PACKAGE);
  try {
    await browser.execute("mobile: clearApp", { appId: APP_PACKAGE });
  } catch {
    // clearApp is best-effort; ignore errors
  }
  // clearApp revokes all runtime permissions — re-grant camera + location so the
  // selfie capture activity and any GPS-gated screens don't hang on a system dialog.
  for (const perm of [
    "android.permission.CAMERA",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
  ]) {
    try {
      await browser.execute("mobile: shell", {
        command: `pm grant ${APP_PACKAGE} ${perm}`,
      });
    } catch { /* best-effort */ }
  }
  // Seed an emulator GPS fix so TreeCaptureScreen's location-gated UI (capture
  // button enable, navigation to ImageReview) progresses on test devices.
  try {
    await browser.execute("mobile: setGeolocation", {
      latitude: 37.422,
      longitude: -122.084,
      altitude: 0,
    });
  } catch { /* best-effort — emulator may already have a location */ }
  await browser.activateApp(APP_PACKAGE);
  await browser.pause(1500);
  // dismiss any system dialogs that appear on fresh launch
  await dismissSystemDialogsIfPresent();
}

export async function dismissSystemDialogsIfPresent(): Promise<void> {
  const allowTexts = ["While using the app", "Only this time", "Allow", "OK"];
  for (let i = 0; i < 3; i++) {
    let dismissed = false;
    for (const text of allowTexts) {
      try {
        const btn = await byText(text);
        if (await btn.isDisplayed()) {
          await btn.click();
          await browser.pause(500);
          dismissed = true;
          break;
        }
      } catch {
        // not present
      }
    }
    if (!dismissed) break;
  }
}

export async function launchWithExistingUser(): Promise<void> {
  // Terminate + reactivate so each scenario starts from the Dashboard root,
  // not whatever screen the prior scenario ended on. With noReset:true, app
  // data persists, so the cold start auto-skips onboarding.
  await browser.terminateApp(APP_PACKAGE);
  await browser.activateApp(APP_PACKAGE);
  await browser.pause(1500);
  await ensureOnDashboard();
}

// ─── Dialog Helpers ───────────────────────────────────────────────────────────

export async function dismissSyncReminderIfPresent(): Promise<void> {
  if (await isVisible("Upload Trees Soon")) {
    await tapText("OK");
  }
}

export async function advancePastSessionNote(): Promise<void> {
  await waitForVisible("Add note to session", 15000);
  await browser.pressKeyCode(66); // KEYCODE_ENTER → IME Go → NavigateNext
}

// ─── Full First-Launch Navigation ─────────────────────────────────────────────

/**
 * Navigate the app from any screen to the Dashboard ("UPLOAD" visible).
 *
 * Handles the complete first-launch onboarding sequence:
 *   Language Picker → Privacy Policy dialog → Credential Entry →
 *   Name Entry → Selfie → Image Review → Dashboard
 *
 * Also safe to call when already on the Dashboard — returns immediately.
 */
export async function ensureOnDashboard(): Promise<void> {
  if (await isVisible("UPLOAD")) return;

  // ── Language Picker ──────────────────────────────────────────────────────
  if (await isVisibleWithTimeout("ENGLISH", 10000)) {
    await tapText("ENGLISH");
    await browser.pause(500);
    await tapRightArrow();
    await browser.pause(1500);
  }

  // ── Privacy Policy Dialog ────────────────────────────────────────────────
  if (await isVisibleWithTimeout("Privacy Policy", 6000)) {
    await tapAt(540, 1800);
    await browser.pause(1000);
  }

  // ── Credential Entry ─────────────────────────────────────────────────────
  if (await isVisibleWithTimeout("PHONE", 6000)) {
    await tapText("PHONE");
    await browser.pause(300);
    const phoneField = await byClass("android.widget.EditText", 0);
    await phoneField.waitForDisplayed({ timeout: 5000 });
    await phoneField.setValue("1234567890");
    try { await browser.hideKeyboard(); } catch { /* not shown */ }
    await browser.pause(500);
    await tapRightArrow();
    await browser.pause(1500);
  }

  // ── Name Entry ──────────────────────────────────────────────────────────
  if (await isVisibleWithTimeout("First Name", 8000)) {
    const firstNameField = await byClass("android.widget.EditText", 0);
    await firstNameField.waitForDisplayed({ timeout: 5000 });
    await firstNameField.setValue("Test");
    const lastNameField = await byClass("android.widget.EditText", 1);
    await lastNameField.setValue("User");
    try { await browser.hideKeyboard(); } catch { /* not shown */ }
    await browser.pause(500);
    await tapRightArrow();
    await browser.pause(3000);
  }

  // A camera-permission dialog can render between name-entry and selfie capture
  // even after `pm grant` because the app may probe permissions before the grant lands.
  await dismissSystemDialogsIfPresent();

  // ── Selfie Tutorial Dialog ───────────────────────────────────────────────
  if (await isVisibleWithTimeout("Click on", 8000)) {
    await tapDesc("Dismiss tutorial", 8000);
    // Wait for the next anchor (capture button) instead of a fixed pause.
    await (await byDesc("Take selfie")).waitForDisplayed({ timeout: 15000 });
  }

  // ── Selfie Screen ────────────────────────────────────────────────────────
  if (!(await isVisible("UPLOAD"))) {
    const takeSelfie = await byDesc("Take selfie");
    await takeSelfie.waitForDisplayed({ timeout: 15000 });
    await takeSelfie.click();
    // Wait until the review screen renders (Approve appears) — guarantees the
    // capture-then-transition completed, regardless of camera latency.
    await (await byDesc("Approve selfie")).waitForDisplayed({ timeout: 20000 });
  }

  // ── Image Review Screen ──────────────────────────────────────────────────
  if (!(await isVisible("UPLOAD"))) {
    const approve = await byDesc("Approve selfie");
    await approve.waitForDisplayed({ timeout: 8000 });
    await approve.click();
  }

  await waitForVisible("UPLOAD", 30000);
}
