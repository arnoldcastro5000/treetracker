import { $, browser } from "@wdio/globals";
import { Tags, byTag, languageOption } from "./tags";
import { perfTapAttempts, perfFallback } from "./perf";

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
// accessibility tree, all icon button taps use coordinates.

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

// ─── testTag (resource-id) Tap Layer ──────────────────────────────────────────
// The app enables testTagsAsResourceId at each Activity root (the automation-ids
// work, Phases 0-3), so every Modifier.testTag(...) surfaces to UiAutomator2 as a
// raw resource-id (confirmed in CI: resource-id="nav-forward", no package prefix).
// Locating a control by its id is resolution- and layout-independent, unlike the
// pixel-fraction taps further down, which this layer supersedes. The tap itself
// still routes through tapAt (clickGesture then a real input tap) at the tagged
// node's bounds centre, the mechanism proven to fire this app's Compose
// pointerInput{detectTapGestures} controls (a plain element.click can miss them).
//
// Every migrated helper is tag-FIRST with the old coordinate/desc path kept as a
// fallback, so a build without tags (or an ad-hoc local run) still works. When the
// fallback fires it logs loudly; set E2E_STRICT_TAGS=1 to make that a hard failure,
// which CI uses to assert the suite runs on ids and never silently drifts back to
// coordinate taps.

const STRICT_TAGS = !!process.env.E2E_STRICT_TAGS;

function tagFallback(label: string, tag: string): void {
  const msg = `[tags] FALLBACK for ${label}: resource-id "${tag}" not usable, using coordinate/desc path`;
  console.log(msg);
  perfFallback(label);
  if (STRICT_TAGS) {
    throw new Error(`${msg} (E2E_STRICT_TAGS set: tagged automation is required)`);
  }
}

// Tap the centre of a tagged node once, via the proven tapAt mechanism. Returns
// false immediately if the node is absent, so probing for an optional tag (e.g. a
// language row) costs nothing and the caller can fall through.
async function tapTag(tag: string): Promise<boolean> {
  const el = await byTag(tag);
  if (!(await el.isDisplayed().catch(() => false))) return false;
  const bounds = await el.getAttribute("bounds").catch(() => null);
  const c = bounds ? boundsCentre(bounds) : null;
  if (!c) return false;
  await tapAt(c.x, c.y);
  return true;
}

// Tap a tagged node and retry until `success` holds, re-reading the node each
// attempt. Mirrors tapFractionUntil but locates by id instead of a screen fraction.
// Returns false if the tag is absent from the start (caller falls back to
// coordinates); a tag that disappears after a tap is treated as a successful
// navigation (verified via `success`).
async function tapTagUntil(
  tag: string,
  success: () => Promise<boolean>,
  label = "tapTag",
  tries = 5,
): Promise<boolean> {
  for (let i = 0; i < tries; i++) {
    const el = await byTag(tag);
    const shown = await el.isDisplayed().catch(() => false);
    if (!shown) {
      if (i === 0) return false;      // tag was never present -> fall back
      return await success();         // gone after a tap -> did it navigate?
    }
    const bounds = await el.getAttribute("bounds").catch(() => null);
    const c = bounds ? boundsCentre(bounds) : null;
    if (!c) return i === 0 ? false : await success();
    await browser.pause(i === 0 ? 400 : 300);
    await browser.execute("mobile: clickGesture", { x: c.x, y: c.y }).catch(() => {});
    await browser.pause(500);
    if (await success()) {
      if (i > 0) console.log(`[${label}] tag tap succeeded on attempt ${i + 1}`);
      perfTapAttempts(label, i + 1);
      return true;
    }
    await inputTap(c.x, c.y, label);
    await browser.pause(500);
    if (await success()) {
      if (i > 0) console.log(`[${label}] tag tap (input) succeeded on attempt ${i + 1}`);
      perfTapAttempts(label, i + 1);
      return true;
    }
    console.log(`[${label}] tag tap attempt ${i + 1} had no effect, retrying`);
  }
  return false;
}

// Set a text field located by its stable id, falling back to the positional
// EditText selector (fragile: breaks if field order changes) when the tag is
// absent.
export async function setFieldByTag(
  tag: string,
  value: string,
  fallbackIndex = 0,
  timeout = 8000,
): Promise<void> {
  const tagged = await byTag(tag);
  if (await tagged.isDisplayed().catch(() => false)) {
    await tagged.setValue(value);
    return;
  }
  try {
    await tagged.waitForDisplayed({ timeout: 1500 });
    await tagged.setValue(value);
    return;
  } catch {
    // fall through to the positional fallback
  }
  tagFallback(`field:${tag}`, tag);
  const field = await byClass("android.widget.EditText", fallbackIndex);
  await field.waitForDisplayed({ timeout });
  await field.setValue(value);
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
  // Language rows carry a stable id (language-option-<name>); prefer it when the
  // tapped text is a language option. Not every tapText target is tagged (TRACK,
  // UPLOAD, NOTE are plain screen text), so a miss here is expected, not a fallback.
  if (await tapTag(languageOption(text))) return;
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
  const before = await safeSource();
  const changed = async () => (await safeSource()) !== before;
  // Tag-first: the forward ArrowButton now carries testTag "nav-forward".
  if (await tapTagUntil(Tags.NAV_FORWARD, changed, "tapRightArrow")) return;
  tagFallback("tapRightArrow", Tags.NAV_FORWARD);
  // Preferred fallback: content-description, present on app versions that label
  // the arrow. Quick, non-blocking check so we don't wait the full timeout.
  try {
    const btn = await byDesc("Navigate forward");
    if (await btn.isDisplayed().catch(() => false)) {
      await btn.click();
      return;
    }
  } catch {
    // fall through to the coordinate tap
  }
  // Last resort: the arrow's VISUAL centre is ~0.82w x 0.855h, but the
  // language/credential screens draw a full-height content layer that intercepts a
  // tap there; the arrow only receives taps a little lower, at ~0.82w x 0.88h
  // (886,2059 on 1080x2340), pinned by a coordinate sweep in CI.
  await tapFractionUntil(0.82, 0.88, changed, "tapRightArrow");
}

export async function tapBackArrow(): Promise<void> {
  const before = await safeSource();
  const changed = async () => (await safeSource()) !== before;
  // Tag-first: the back ArrowButton carries testTag "nav-back".
  if (await tapTagUntil(Tags.NAV_BACK, changed, "tapBackArrow")) return;
  tagFallback("tapBackArrow", Tags.NAV_BACK);
  const btn = await byDesc("Navigate back");
  await btn.waitForDisplayed({ timeout: 8000 });
  await btn.click();
}

// Accept the Privacy Policy dialog. Its confirm control is an ApprovalButton
// (TreeTrackerButton, contentDescription=null) centred horizontally at the
// dialog's bottom, so it has no queryable node; tap by coordinate and retry
// until the dialog's "Privacy Policy" title is gone.
export async function acceptPrivacyPolicy(): Promise<void> {
  await waitForVisible("Privacy Policy", 15000);
  const gone = async () => !(await isVisible("Privacy Policy"));
  // Tag-first: the accept control is an ApprovalButton, tagged "approve".
  if (await tapTagUntil(Tags.APPROVE, gone, "acceptPrivacyPolicy")) return;
  tagFallback("acceptPrivacyPolicy", Tags.APPROVE);
  await tapFractionUntil(0.5, 0.905, gone, "acceptPrivacyPolicy");
}

// Tap a screen-fraction point and retry until `success` holds. This app's Compose
// controls are pointerInput{detectTapGestures} with no queryable node, so they can
// only be driven by coordinate, and a tap can be dropped if sent before the
// control settles. Each attempt tries clickGesture then a real `input tap`,
// checking `success` between them so a working tap returns before the other fires.
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
    await browser.pause(i === 0 ? 700 : 400);
    await browser.execute("mobile: clickGesture", { x, y }).catch(() => {});
    await browser.pause(500);
    if (await success()) {
      if (i > 0) console.log(`[${label}] succeeded via clickGesture on attempt ${i + 1}`);
      return true;
    }
    await inputTap(x, y, label);
    await browser.pause(500);
    if (await success()) {
      if (i > 0) console.log(`[${label}] succeeded via inputTap on attempt ${i + 1}`);
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
 * Prefers an element-based tap when an anchor text is provided, robust against
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
  // clearApp revokes all runtime permissions, re-grant camera + location so the
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
  } catch { /* best-effort, emulator may already have a location */ }
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

// Diagnostic: how much of the Compose UI is visible to UiAutomator right now.
// A source tree with textNodes=0 means the Jetpack Compose semantics are NOT
// exposed to the accessibility bridge, so NO element is findable (this is the
// route2 stage-2 empty-tree stall). The line prints to the wdio stdout, which
// the CI step captures, so a run tells us fresh-vs-relaunch semantics state.
async function logSemanticsProbe(label: string): Promise<void> {
  try {
    const src = await browser.getPageSource();
    const textNodes = (src.match(/text="[^"]+"/g) || []).length;
    const descNodes = (src.match(/content-desc="[^"]+"/g) || []).length;
    // eslint-disable-next-line no-console
    console.log(
      `[compose-probe] ${label} relaunch=${!process.env.E2E_SKIP_RELAUNCH} ` +
        `srcLen=${src.length} textNodes=${textNodes} descNodes=${descNodes}`,
    );
  } catch (e) {
    // eslint-disable-next-line no-console
    console.log(`[compose-probe] ${label} getPageSource failed: ${(e as Error).message}`);
  }
}

export async function launchWithExistingUser(): Promise<void> {
  // EXPERIMENT (E2E_SKIP_RELAUNCH): the terminate + activate relaunch below is
  // suspected to leave Jetpack Compose semantics unexposed to UiAutomator, so the
  // a11y tree returns zero text/content-desc and nothing is findable (route2
  // stage-2 stall on the language picker). When the flag is set, drive onboarding
  // on appium's original fresh launch instead, to test whether a fresh launch
  // restores semantics exposure. Compare the [compose-probe] line to a relaunch run.
  if (process.env.E2E_SKIP_RELAUNCH) {
    await browser.pause(1500);
  } else {
    // Terminate + reactivate so each scenario starts from the Dashboard root,
    // not whatever screen the prior scenario ended on. With noReset:true, app
    // data persists, so the cold start auto-skips onboarding.
    await browser.terminateApp(APP_PACKAGE);
    await browser.activateApp(APP_PACKAGE);
    await browser.pause(1500);
  }
  await logSemanticsProbe("launchWithExistingUser");
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
 * Also safe to call when already on the Dashboard, returns immediately.
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
    const gone = async () => !(await isVisible("Privacy Policy"));
    if (!(await tapTagUntil(Tags.APPROVE, gone, "ensureOnDashboard:privacy"))) {
      tagFallback("ensureOnDashboard:privacy", Tags.APPROVE);
      await tapAt(540, 1800);
    }
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
  // SelfieScreen shows a tutorial ("Click on ... to take a selfie...") whose
  // dismiss control is a checkmark (TreeTrackerButton, contentDescription=null)
  // at the dialog's bottom-centre. Tap by coordinate until the tutorial is gone.
  if (await isVisibleWithTimeout("Click on", 8000)) {
    const dismissed = async () => !(await isVisible("Click on"));
    // Tag-first: the real dismiss control is scoped "tutorial-dismiss" (the selfie
    // tutorial also renders demo ApprovalButtons, so the plain "approve" id collides
    // there, hence a dedicated tag).
    if (!(await tapTagUntil(Tags.TUTORIAL_DISMISS, dismissed, "dismissSelfieTutorial"))) {
      tagFallback("dismissSelfieTutorial", Tags.TUTORIAL_DISMISS);
      // Fallback: the tutorial is a Material AlertDialog centred on screen (bounds
      // ~[100,635][980,1717]); its dismiss checkmark sits at the dialog's
      // bottom-centre, ~0.5w x 0.69h, NOT at the screen bottom.
      await tapFractionUntil(0.5, 0.69, dismissed, "dismissSelfieTutorial");
    }
  }

  // ── Selfie Screen ────────────────────────────────────────────────────────
  // The CaptureButton is the bottom ActionBar's centre action (no queryable
  // node), at ~0.5w x 0.88h. Capturing navigates to the review screen, so retry
  // until the page changes (the a11y tree is stable except for that navigation).
  if (!(await isVisible("UPLOAD"))) {
    const beforeCapture = await safeSource();
    const captured = async () =>
      (await isVisible("UPLOAD")) || (await safeSource()) !== beforeCapture;
    // Tag-first: the selfie CaptureButton carries testTag "capture-selfie".
    if (!(await tapTagUntil(Tags.CAPTURE_SELFIE, captured, "takeSelfie"))) {
      tagFallback("takeSelfie", Tags.CAPTURE_SELFIE);
      await tapFractionUntil(0.5, 0.88, captured, "takeSelfie");
    }
    await browser.pause(1500);
  }

  // ── Image Review Screen ──────────────────────────────────────────────────
  // Reject/approve are a centred ApprovalButton pair (no queryable node); the
  // approval (right) button sits at ~0.6w x 0.9h. Retry until the dashboard shows.
  if (!(await isVisible("UPLOAD"))) {
    const onDashboard = async () => await isVisible("UPLOAD");
    // Tag-first: the review approve control is an ApprovalButton, tagged "approve".
    if (!(await tapTagUntil(Tags.APPROVE, onDashboard, "approveSelfie"))) {
      tagFallback("approveSelfie", Tags.APPROVE);
      await tapFractionUntil(0.6, 0.9, onDashboard, "approveSelfie");
    }
  }

  await waitForVisible("UPLOAD", 30000);
}
