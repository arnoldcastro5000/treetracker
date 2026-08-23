Feature: Capture probe (issue #23 / API-32 camera stall tight loop)

  # BACKEND-FREE reproduction of the API-32 real-camera still-capture stall.
  # On API 32 the CameraX camera binds (bindToLifecycle OK) but ImageCapture.takePicture()
  # never completes under the co-located k3d contention (ImageReader buffer starvation),
  # so the app never reaches the review screen. This drives onboarding + a REAL tree
  # capture on a QUIET host (no k3d, PROBE_ONLY) and asserts the review screen appears.
  # Green == takePicture completed on a quiet host (=> the stall is contention, config-
  # fixable). Red == capture stalls even quiet (=> an API-32 emulator HAL limit). The
  # emulator script sets debug.e2e.realtree=1, so the tree uses the REAL CameraX path.
  Scenario: A real tree capture completes and reaches the review screen
    Given the app is launched with an existing user
    When I tap "TRACK"
    And I dismiss sync reminder if present
    And I select the first user and advance
    And I enter organization "Test Org"
    And I tap the right arrow
    And I should see the capture screen
    And I take a tree capture
    And I should see the tree image review screen
