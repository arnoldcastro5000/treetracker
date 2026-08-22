// ESLint flat config for the Android e2e suite (community typescript-eslint stack).
// Beyond the standard recommended rules it carries a project anti-pattern guard:
// step definitions must not select UI by content-description (byDesc/tapDesc) - Jetpack
// Compose does not surface content-descriptions to UiAutomator on the emulator, so those
// selectors silently never resolve. Use the testTag helpers (byTag / tapTagUntil) with a
// coordinate fallback instead. See apps/e2e/docs/emulator-camera-limitation.md.
import tseslint from "typescript-eslint";
import noOnlyTests from "eslint-plugin-no-only-tests";

export default tseslint.config(
  {
    ignores: [
      "node_modules/**",
      "test-artifacts/**",
      "dist/**",
      "**/allure-results/**",
    ],
  },
  ...tseslint.configs.recommended,
  {
    plugins: { "no-only-tests": noOnlyTests },
    rules: {
      "no-debugger": "error",
      "no-only-tests/no-only-tests": "error",
      // The suite intentionally logs diagnostics (compose-probe, tap traces) to the CI
      // logcat / wdio output, so `no-console` is deliberately NOT enabled here.
    },
  },
  {
    // Anti-pattern guard, scoped to step definitions.
    files: ["features/**/*.ts"],
    rules: {
      "no-restricted-syntax": [
        "error",
        {
          selector:
            "CallExpression[callee.name='byDesc'], CallExpression[callee.name='tapDesc']",
          message:
            "Do not select by content-description in step definitions: Compose does not expose it to UiAutomator on the emulator, so byDesc/tapDesc never resolve. Use byTag / tapTagUntil (testTag) with a coordinate fallback. See apps/e2e/docs/emulator-camera-limitation.md.",
        },
      ],
    },
  },
);
