# Local Windows setup: emulator + Appium (for the sandbox-driven e2e loop)

Goal: run the Android emulator and an Appium server on your Windows 11 machine, so the
agent can drive `apps/e2e` from the sandbox against your emulator over the network. This
gives a seconds-fast edit->run loop instead of the ~7-minute CI cycle.

You do this ONCE. After it's up, you just leave the emulator + Appium running; the agent
runs the tests.

--------------------------------------------------------------------------------
## 0. Turn on virtualization (needed for a fast emulator)
- BIOS/UEFI: make sure CPU virtualization is enabled (Intel VT-x / AMD-V).
- Windows Features (search "Turn Windows features on or off"), tick:
  - "Windows Hypervisor Platform"
  - "Virtual Machine Platform"
  Reboot after enabling.

## 1. Install JDK 17 (Temurin) and set JAVA_HOME
- Install Eclipse Temurin JDK 17 (msi from adoptium.net).
- Set a user env var JAVA_HOME to the install dir, e.g.:
  C:\Program Files\Eclipse Adoptium\jdk-17.x.x-hotspot
- Verify in a NEW PowerShell:  java -version   (should say 17)

## 2. Install the Android SDK
Easiest: install Android Studio (bundles the SDK). Or command-line tools only.
Then set env vars (user-level) and reopen PowerShell:
  setx ANDROID_HOME "$env:LOCALAPPDATA\Android\Sdk"
  setx ANDROID_SDK_ROOT "$env:LOCALAPPDATA\Android\Sdk"
Add to PATH (Settings -> Environment Variables -> Path), these folders:
  %ANDROID_HOME%\platform-tools
  %ANDROID_HOME%\emulator
  %ANDROID_HOME%\cmdline-tools\latest\bin
Verify in a NEW PowerShell:  adb --version   and   emulator -version

## 3. Install SDK packages + accept licenses
In PowerShell:
  sdkmanager "platform-tools" "emulator" "platforms;android-30" "build-tools;34.0.0" "system-images;android-30;google_apis;x86_64"
  sdkmanager --licenses      # press y to accept all
(We use api-level 30, google_apis, x86_64 to match what passed in CI. x86_64 is the fast
 image on an Intel/AMD Windows host.)

## 4. Create the emulator (AVD)
  avdmanager create avd -n greenstand_test -k "system-images;android-30;google_apis;x86_64" -d pixel_5
(If it asks "create a custom hardware profile?", answer: no)

## 5. Boot the emulator (leave this window open)
  emulator -avd greenstand_test -no-snapshot -camera-back emulated -camera-front emulated
In another PowerShell, confirm it's up:
  adb wait-for-device
  adb devices        # should list:  emulator-5554   device

## 6. Install Node.js 20
- Install Node 20 LTS (msi from nodejs.org).
- Verify:  node -v   (v20.x)

## 7. Install Appium 2 + the UiAutomator2 driver (version-pinned to match CI)
  npm install -g appium@2.19.0
  appium driver install uiautomator2@3.10.0
  appium -v          # 2.19.0
  appium driver list --installed

## 8. Build the debug APK and install it on the emulator
From the repo root on Windows (the same treetracker checkout):
  # a) create the dummy keys file the Gradle build requires (11 pre-declared keys):
  @"
  s3_production_identity_pool_id=placeholder
  prod_treetracker_client_id=placeholder
  prod_treetracker_client_secret=placeholder
  s3_test_identity_pool_id=placeholder
  test_treetracker_client_id=placeholder
  test_treetracker_client_secret=placeholder
  s3_dev_identity_pool_id=placeholder
  dev_treetracker_client_id=placeholder
  dev_treetracker_client_secret=placeholder
  treetracker_client_id=placeholder
  treetracker_client_secret=placeholder
  "@ | Set-Content -NoNewline treetracker-android\treetracker.keys.properties

  # b) build (from treetracker-android):
  cd treetracker-android
  .\gradlew :app:assembleDebug
  cd ..

  # c) install on the emulator:
  adb -s emulator-5554 install -r treetracker-android\app\build\outputs\apk\debug\app-debug.apk
App package is: org.greenstand.android.TreeTracker.debug

## 9. Start Appium listening for the sandbox
Stop any Appium from step 7, then start it bound to all interfaces so the sandbox can reach it:
  appium --address 0.0.0.0 --port 4723 --relaxed-security --allow-cors
Leave this running. You should see "Appium REST http interface listener started on 0.0.0.0:4723".

## 10. Let the sandbox reach it
- Windows Firewall: allow inbound TCP on port 4723 (or allow the node/appium app through the
  firewall when Windows prompts on first start).
- The sandbox reaches your host at host.docker.internal:4723. Tell me once Appium is running
  and I will (a) allow host.docker.internal:4723 in the sandbox network policy and (b) point
  the test runner at it, then drive the tests from here.

--------------------------------------------------------------------------------
## Daily use after setup
Just two windows running:
  1) emulator -avd greenstand_test -no-snapshot -camera-back emulated -camera-front emulated
  2) appium --address 0.0.0.0 --port 4723 --relaxed-security --allow-cors
Then tell me they're up and I run the tests.

## Notes
- The APK only needs rebuilding (step 8) when the app code changes, not per test run.
- `noReset: true` in the suite keeps app data between runs; if a run leaves the app in a weird
  state, tell me and I'll relaunch/clear it, or you can:  adb shell pm clear org.greenstand.android.TreeTracker.debug
- Chrome + matching chromedriver are only needed later for 03_capture_setup, not for 02_signup.
