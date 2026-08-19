import { $ } from "@wdio/globals";

/**
 * Automation ids, mirrored from the Android app's `AutomationTags` object
 * (treetracker-android: app/.../view/AutomationTags.kt).
 *
 * The app enables `testTagsAsResourceId = true` at each Activity root, so every
 * `Modifier.testTag(...)` surfaces to UiAutomator2 as a selectable `resource-id`.
 * These replace the coordinate taps in `helpers.ts`.
 *
 * Keep this file in sync with AutomationTags.kt. If the two drift, the selectors
 * silently stop matching and the suite falls back to coordinates.
 */
export const Tags = {
  // Navigation
  NAV_FORWARD: "nav-forward",
  NAV_BACK: "nav-back",

  // Primary actions
  APPROVE: "approve",
  DECLINE: "decline",
  CAPTURE_SELFIE: "capture-selfie",
  CAPTURE_TREE: "capture-tree",

  // Text inputs
  INPUT_FIRST_NAME: "input-first-name",
  INPUT_LAST_NAME: "input-last-name",
  INPUT_PHONE: "input-phone",
  INPUT_EMAIL: "input-email",

  // Screen-scoped (where a role tag would collide on one screen)
  TUTORIAL_DISMISS: "tutorial-dismiss",

  // Misc controls
  LANGUAGE_MENU: "language-menu",
  INFO: "info",
  ADD: "add",
  USER_IMAGE: "user-image",
} as const;

/** Per-language selection row, e.g. languageOption("ENGLISH") -> "language-option-english". */
export const languageOption = (name: string): string =>
  "language-option-" + name.toLowerCase().replace(/ /g, "-");

/**
 * Appium selector for a Compose testTag surfaced via testTagsAsResourceId.
 *
 * NOTE: the exact resource-id form in the UiAutomator2 tree (raw tag vs
 * "<package>:id/<tag>") is confirmed empirically on the first CI run with the
 * tagged APK; adjust here once pinned. `resourceId(...)` on the raw tag is the
 * expected form for Compose testTagsAsResourceId.
 */
export const byTag = (tag: string) =>
  $(`android=new UiSelector().resourceId("${tag}")`);
