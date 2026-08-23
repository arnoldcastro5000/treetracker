Feature: A11y onboarding probe (issue #23 tight loop)

  # Minimal, BACKEND-FREE reproduction of the API-34 a11y-stabilization bug.
  # The failure manifests at onboarding start (empty a11y tree / launcher-ANR jank),
  # long before any capture/upload, so this drives onboarding only up to the capture
  # screen and asserts it was reached. Reaching it REQUIRES the Compose a11y tree to
  # stabilize, so a green run == a11y OK and a red run == the exact #23 stall - with
  # no k3d stack, no LocalStack, no camera capture, no upload. Runs in PROBE_ONLY mode.
  Scenario: Onboarding reaches the capture screen (a11y tree stabilizes)
    Given the app is launched with an existing user
    When I tap "TRACK"
    And I dismiss sync reminder if present
    And I select the first user and advance
    And I enter organization "Test Org"
    And I tap the right arrow
    And I should see the capture screen
