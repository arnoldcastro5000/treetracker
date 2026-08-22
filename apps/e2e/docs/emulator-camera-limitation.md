# Headless-emulator camera capture: limitation, version analysis, and the `.local` bypass

Status: validated (independent Android-developer review, 2026-08-22, against the emulator source
`mirror/qemu-android`, the current `androidx/androidx` CameraX tree, and public virtualscene-poster
users). Verdict: keep the `.local` bypass as the primary CI path; a real back-lens capture path is a
legitimate future follow-up, not a downgrade.

## 1. The limitation, stated precisely
On the CI emulator the app's real camera capture path (Jetpack CameraX `ImageCapture`) does not
complete in our tested configuration: `takePicture(...)`'s save/captured callback does not fire, and in
our config the provider does not bind a usable device either. This blocks both capture points in `03` —
the onboarding **selfie** (front lens) and the **tree capture** (back lens). We work around it with a
`.local`-build bypass that feeds a bundled image through the same post-processing and
`onImageCaptured(...)` path.

## 2. Exact stack we run today
| Component | Value |
|---|---|
| Emulator binary | 37.1.11.0 (build_id 15917651) |
| System image | `system-images;android-30;google_apis;x86_64` -> Android 11 / API 30 |
| Device profile | pixel_5, 2 cores |
| GPU | `swiftshader_indirect` (software) |
| Camera flags | `-camera-back emulated -camera-front emulated` |
| Runner | standard `ubuntu-latest`, no physical camera |

## 3. Root cause, layer by layer
(a) **Camera source (`emulated`), in our tested config.** In general `emulated` DOES enumerate as a
camera (an animated checkerboard feed) and CameraX often binds+previews it on emulators; the common
failure is downstream in JPEG capture (see 3b). In OUR config (API 30 + swiftshader + 2 cores) the
observed bind is unreliable, which is why the bypass sits at the top of the camera factory rather than
in the provider callback. Do not generalise the bind failure beyond this config.

(b) **Camera2 HAL / capture pipeline.** `ImageCapture.takePicture(...)` drives the HAL JPEG pipeline;
on the emulator that pipeline is unreliable and the callback may never return. This is independent of
app code, and CameraX itself acknowledges it: `camera-testing/.../AndroidUtil.java` ships an emulator
detector (fingerprint / ranchu / Cuttlefish) used across the suite to skip capture-adjacent checks on
emulators (e.g. "Emulator has issue on checking gainmap for saved to file").

(c) **Lens facing.** The selfie uses `CameraSelector.DEFAULT_FRONT_CAMERA`. Confirmed against the
emulator source (`android/main-common.c`, `emulator_parseFeatureCommandLineOptions`): `-camera-front`
accepts only `emulated | webcam<N> | videoplayback | none` - `virtualscene` is NOT parsed for the front
lens in any configuration. So the rich synthetic scene cannot serve a front-facing selfie.

(d) **GPU.** `virtualscene` needs GPU rendering; headless CI uses `swiftshader_indirect` (software).
It renders but is historically flaky for the 3D scene and its capture. `-gpu host` is unavailable on
headless GitHub runners.

(e) **Real image injection** (making `takePicture` return an arbitrary chosen image at the API level)
is a proprietary device-farm / Genymotion feature; the AOSP emulator on GitHub runners has none. Note
this is distinct from virtualscene posters (see 6.2), which place a chosen image INTO the rendered
scene rather than injecting frames into the capture API.

## 4. API 30 is the worst image for this task (Google's own evidence)
The current `androidx` tree carries explicit `SDK_INT == 30 && isEmulator()` skips for camera:
`camera-video/.../VideoCaptureDeviceTest.kt` ("Emulator API 30 crashes running this test", b/264902324),
`integration-tests/.../SensorPatternUtil.kt` (b/342016557), plus ~12 more API-30-emulator skips in
`OutputOptionsTest.kt` / `MediaSpecTest.kt`. Google's CI treats the API 30 emulator as a specially
defective camera environment. Newer google_apis images have only narrower quirk skips (e.g. API 33-37
"can not correctly apply solid color pattern", b/412262667), so basic bind/capture generally works
there in Google's CI. This is strong support for "a system-image upgrade is the best lever."

## 5. Where version upgrades MAY uncover improvement
| Axis | Change | Likely effect |
|---|---|---|
| System image | API 30 -> API 34/35 google_apis | Best lever. Newer Camera2 HAL; Google's own CI runs CameraX capture on newer images with only narrow skips. Could enable real back-lens capture. |
| Camera flag | `emulated` -> `virtualscene` (back) | Presents a bindable back camera + supports posters (6.2). Does NOT help the front lens. |
| Emulator binary | 37.1.11.0 -> latest | Better virtualscene fidelity/defaults; behavior of 37.1.11.0 vs latest is UNVERIFIED here (release notes unreachable) - confirm before Exp A. |
| GPU | swiftshader (headless) | Stuck with software headless; marginal gains only. |

## 6. Hard limits and the corrected content-control picture
### 6.1 Front-lens selfie: no supported built-in source with controllable content
`virtualscene` is back-only (confirmed, 3c). `emulated` front, even if a newer image fixes capture,
would only ever produce a checkerboard - useless content. So the practical conclusion holds, but state
it as "no supported built-in front source with controllable content," not "does not bind in all
versions" (that is asserted beyond what we tested).
Footnote: the emulator source also has a `videoplayback` camera source
(`android/android-emu/android/camera/camera-videoplayback.*`) valid on BOTH lenses, which plays supplied
video as the feed. It is OFF by default (`VideoPlayback = off` in `advancedFeatures.ini`), feature-gated
(`-feature VideoPlayback`), and appears experimental/undocumented. Worth a <=30-minute spike; expect
failure; do not plan around it.

### 6.2 Content control on the BACK lens IS achievable (corrects the prior "impossible" claim)
The emulator supports custom posters in the virtual scene - no device farm, no injection:
- CLI flag (`android/emu/cmdline/include/android/cmdline-options.h`):
  `-virtualscene-poster <name>=<filename>` ("Load a png or jpeg image as a poster in the virtual scene"),
  e.g. `-camera-back virtualscene -virtualscene-poster wall=/path/tree.jpg`.
- Resource file: append a `poster` block (name, size, position, rotation) to
  `$ANDROID_SDK/emulator/resources/Toren1BD.posters` referencing `tree.jpg`; position/rotation let the
  image dominate the default view.
Real-world use: `mobile_scanner` PR #121 and `session-appium` scan real QR codes through the emulator
camera this way. So on a newer image, `virtualscene` + poster could plausibly yield real CameraX
capture of a real tree image on the back lens.
What still stands: (a) no published green run of virtualscene+poster capture on headless swiftshader
(mobile_scanner's merged CI omits the emulator camera test); (b) the poster is part of a rendered 3D
scene, not a full-frame image; (c) determinism and flake-risk remain. The bypass's justification is
therefore determinism + headless-swiftshader reliability risk + the front-lens gap - NOT content
impossibility.

## 7. Net assessment
Keep the deterministic `.local` bypass as the primary CI path. It is defensible even against the
corrected facts: it is deterministic, gives real-tree content on both lenses, and exercises the full
pipeline (post-processing -> S3 -> k3d -> Postgres -> admin `/verify`). BUT the back-lens tree capture
via API 34 + virtualscene + poster is more promising than a naive reading suggests. If the amended
Exp A proves stable on headless swiftshader, converting the tree capture to a real-capture path (while
keeping the bypass for the front-lens selfie) is a legitimate follow-up, not a downgrade.

## 8. Experiments (if we choose to probe)
- Exp A (amended, back lens, real content): AVD `system-images;android-34;google_apis;x86_64` +
  `-camera-back virtualscene -virtualscene-poster tree=/abs/path/tree.jpg`; run only the tree capture
  WITHOUT the bypass; watch logcat for `bindToLifecycle` success and a real `OnImageSaved`; inspect the
  saved JPEG for the tree poster. One isolated run, off the green pipeline. Confirm emulator release
  behavior first (37.1.11.0 vs latest is unverified here).
- Exp B (front lens + controlled content): `v4l2loopback` + `ffmpeg` stream a static tree image to
  `/dev/video0`; emulator `-camera-back webcam0 -camera-front webcam0`; test whether CameraX binds a
  host-backed camera and whether the front lens maps. Only listed path that solves the FRONT lens with
  controlled content; also the fallback if Exp A flakes on swiftshader.
- Out of scope (cost): proprietary device farms / Genymotion offer true frame injection - the only way
  to get real capture API + chosen content + both lenses simultaneously.

## 9. Unverified items (confirm before acting)
- Emulator 37.1.11.0 vs latest camera behavior (release notes unreachable; qemu mirror may lag).
- Whether `aosp_atd` / `google_atd` images strip the camera HAL (no source found either way; verify).
- virtualscene+poster capture completing on headless swiftshader (this is what Exp A answers).
