# Native iOS interface

The app now launches `NativeRemoteView` through a SwiftUI hosting controller. The user interface uses native SwiftUI tabs, forms, sliders, navigation, alerts and buttons; it does not launch React or WKWebView. The website remains a separate React interface.

`App/BridgeViewController.swift` currently contains the native model, views and `NativeOSCConnection`, reusing the bounded OSC transport and codec logic. The historical filename is retained to avoid changing the Xcode source references. `ElementOSCPlugin.swift` remains in the project for compatibility but is not instantiated by the native app.

The persistent command panel uses real Liquid Glass on iOS 26 and system material on iOS 16–18. Build with Xcode 26 or later. Syntax parsing has passed on Linux, but the SwiftUI interface has not yet been type checked with the Apple SDK or exercised on a device.

Native screens currently cover keypad and extra keys, forty selectable faders, locked playback, wheels/focus, hue/saturation color, submaster sliders, macros, raw paged patch feedback and connection settings. The website retains richer CIE color and patch/cue presentation; native feature parity and real-console verification remain outstanding.

# Element Remote for iPhone and iPad

This is a Capacitor iOS project containing the React interface and a custom Swift OSC plugin. The native app bundles its UI and sends OSC directly over the local network. It does **not** contact the web server, need Node.js on the phone, or load the Cloudflare website.

## Current validation status

- The web production build and existing real-socket backend/browser tests pass.
- A browser test of Capacitor's native bridge contract verifies on-device configuration, direct command routing, selected fader output, haptics and keep-awake preferences without HTTP API or WebSocket traffic.
- The Foundation-only Swift OSC codec compiles and its tests run under Swift 6.1 on Linux, including a cue packet produced independently by osc.js.
- Native Swift source passes a syntax parse and the Xcode project parses with all native source files included.
- **The full UIKit/Network/Capacitor app has not been compiled with Xcode or tested on an iPhone here. No signed IPA or TestFlight build has been produced.** This environment is Linux and does not have Apple's iOS SDK or signing credentials. Syntax and codec checks are not a substitute for a device build.

## Build on a Mac

Use Xcode 26+ and Node 22.12+ (Node 24 recommended). Capacitor 8 uses Swift Package Manager. The generated project targets iOS 16+.

```sh
npm ci
npm run ios:sync
npm run ios:open
```

1. In Xcode, select the App target, Signing & Capabilities, and your Apple team. Change `app.elementremote.mobile` to a unique bundle identifier if necessary.
2. Select an iPhone/iPad or simulator and run. A physical device and its local network are required for a meaningful console test.
3. A personal Apple account can be used for development installation through Xcode, subject to Apple's provisioning limits. TestFlight/App Store distribution requires the appropriate Apple Developer membership and signing.
4. The source bundle includes synced web assets, so the Xcode project can be opened directly without Node if you only need to build the supplied version. Run sync after any React changes.

The manual GitHub Actions workflow `.github/workflows/ios-build.yml` performs Swift tests and unsigned simulator/device builds on a Mac runner. It is provided but has not been run from this workspace. Unsigned build artifacts **cannot be installed directly on an iPhone**. It does not create certificates, enroll accounts or publish an app.

## Direct console setup

1. Connect the iPhone/iPad to Wi-Fi on the console's network. Internet access is not required.
2. Open Connection in the app. Save the console IP address, display name and transport.
3. For original Element, start with TCP 3032 / OSC 1.0 packet-length framing and match the console settings.
4. Third Party OSC uses TCP 3037 and SLIP, requiring Eos 3.1+ and the console's Third Party OSC option.
5. UDP uses separate send and receive ports. Point the console's transmit address to the phone's Wi-Fi IP, and match its transmit port to the app's receive port (default 8001). The app sends to the console receive port (default 8000).
6. Allow Local Network access when iOS prompts. If denied, enable it in iOS Settings → Privacy & Security → Local Network.

The app does not scan or broadcast on the LAN; the console IP is entered manually. It uses unicast TCP/UDP, so it does not request multicast privileges. Features still depend on console software and fixture capabilities.

## Native implementation

- `App/App/ElementOSCPlugin.swift`: direct Network.framework connections, configuration persistence, ping latency, reconnect, foreground/background handling, momentary-key release, haptics and screen wake.
- `../native/OSCWire`: bounded OSC packet encoder/decoder and TCP packet-length/SLIP framing. Its source is compiled into the app and separately testable with `swift test --package-path native/OSCWire` from the repository root.
- `App/App/BridgeViewController.swift`: registers the local plugin. `SceneDelegate.swift` creates this controller.
- `App/App/Info.plist`: Local Network permission explanation and dark appearance.
- `App/App/PrivacyInfo.xcprivacy`: app-owned UserDefaults access declaration. No analytics or tracking is added by the app.
- `../src/platform.js`: selects the native plugin on iOS and the existing server API in browsers.

Leaving the app releases held momentary controls, clears queued slider changes and closes the console connection. Returning reconnects; selections and cue playback locks reset. No control messages are replayed after a reconnect. Keep Awake and Haptics are optional device preferences in More.

## Before live use

Build on Xcode and verify permission denial/recovery, TCP reconnect, UDP replies, all 40 mapped faders, selected-only levels, key and bump release on app backgrounding, cue locking, and protocol compatibility on the actual Element. Do not assume simulator success verifies Wi-Fi permissions or physical desk output.

References: [Capacitor iOS requirements](https://capacitorjs.com/docs/getting-started/environment-setup), [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [ETC OSC transports](https://support.etcconnect.com/ETC/Consoles/Eos_Family/Software_and_Programming/TCP_port_for_OSC_communication_with_Eos_Software).

## TestFlight cloud build

The manual `.github/workflows/testflight.yml` workflow validates an unsigned device build first. With its upload option enabled, it signs and uploads an internal TestFlight build; it does not submit a public App Store release. The workflow has not yet run on a Mac.

Account setup for this project:

- Apple Team ID: `JUV7448PYM`
- Registered bundle identifier: `app.elementremote.mobile`
- App Store Connect app record: **Element Remote**, app ID `6829988397` (verified). This is separate from FareDrop.
- GitHub repository: `https://github.com/stormey2010/Element-Remote`. Local GitHub authentication is still required to publish and configure Actions.

In the repository's `testflight` environment, configure variables `APPLE_TEAM_ID` and `IOS_BUNDLE_ID`, and secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY`. The existing server-side Apple API configuration can supply these through a secure transfer; never commit signing material or paste it into chat.

The signing lane uses fastlane cert/sigh and never revokes existing certificates. A fresh hosted runner may need to create a distribution certificate because it has no existing private key. Certificate limits can therefore block repeated uploads: configure persistent signing material before routine releases, and never revoke another app's certificate to make room automatically. Temporary signing files are removed after the job.

After upload, Apple must process the build before it appears in TestFlight. A real-device console test remains required.

## Cloud build without GitHub

EAS can upload this project directly with `EAS_NO_VCS=1`. The root `app.json` is delivery metadata; it does not add an Expo or React Native runtime. `.easignore` excludes server data, legacy SSL material, dependencies and local signing files.

Once authenticated to an Expo account, run `EAS_NO_VCS=1 eas init` to link the project, then `EAS_NO_VCS=1 eas build --platform ios --profile native-check --non-interactive --no-wait`. This custom profile checks out the uploaded archive, installs the existing SPM/npm dependencies, tests the codec and compiles an **unsigned** device build using Xcode. It does not produce an installable TestFlight build or submit anything to Apple. A signed store profile and credentials must be configured after the native build passes.

### Signed EAS TestFlight profile

The `testflight` custom profile runs fastlane directly on the uploaded Xcode project and submits the signed archive to App Store Connect. Its `ELEMENT_SIGNING_BUNDLE` variable is an EAS secret file containing the Apple API key and a reusable distribution identity. That file is stored outside the repository, excluded from source uploads, and only supplied to the build worker through EAS. No certificate is revoked by this flow.

The current upload adapter in `/tmp/element-eas-retry.py` flattens the nested Capacitor-generated Xcode directory in a temporary copy so EAS discovers the shared App scheme. It adjusts the codec path in that copy. The custom build references `ios/App.xcodeproj` in the uploaded layout. Do not run `expo prebuild` on this SwiftUI project.

The native compile check succeeded in EAS build `17a768dd-1d5b-427d-a284-efaa3e6551da`. Signed upload build `9908283b-3adf-404c-b92f-ebb8b32150cc` has been started; verify its result and Apple processing before considering it available to testers.

Signed EAS build `7ff057ff-6ec3-4122-b7a9-f807c248fece` finished successfully and fastlane confirmed upload to App Store Connect. The distribution identity uses Apple-compatible PKCS#12 serialization (SHA-1 MAC / PBESv1 TripleDES inside the EAS encrypted secret file). Initial attempts `9908283b-3adf-404c-b92f-ebb8b32150cc` and `b7c9e9a0-fc61-4c06-8c41-b747ad21366c` failed before upload; do not treat those as released builds.

## Console control styling

Console uses the website's six-column keypad arrangement, a two-column Enter key, matte surfaces and restrained shortcut accents. System navigation remains native. Wheels and Focus use custom SwiftUI touch strips and a relative pan/tilt pad instead of Form rows. Wheel gestures accumulate five-point ticks and send at most 30 updates per second per control, flushing final deltas on release and resetting on disconnect. Fine mode uses the console's fine wheel addresses. Accessible step controls remain available.

## Current source changes (not built)

Console has no category strip or More console keys; Record/Cue/Sub/Go To Cue/Chan/Group use filled color keys. Faders use square selection tiles, controls above the grid, and individual/selected-group Bump actions (`/eos/fader/1/N/fire` with no arguments, per ETC's mapped-fader API). Bump invokes the mapped action; it is not a simulated temporary level override or submaster hold. Fader bank 1 is explicitly configured to forty faders when opening/reconnecting the view. Playback uses custom cards without the enable switch. The separate Submasters page was removed.

Color now shares the website's CIE locus and xy-to-RGB preview mapping, custom hue/saturation strips, and a color-palette search. Color gestures are limited to 30 Hz and flush their final value. Haptic feedback is subtle and optional in More.

Wi-Fi state uses `NWPathMonitor` and the network name uses `NEHotspotNetwork.fetchCurrent`. The Apple bundle has Access Wi-Fi Information enabled; `App.entitlements` is configured for signing. Showing the SSID requires user-granted Precise Location authorization; the app only requests authorization after the user taps the Wi-Fi indicator or connection setting. No coordinate updates are requested. Unknown SSID and disconnected states are explicitly shown rather than guessed. SSID/permissions and the new interface need a future Apple SDK build and device test. The user requested no new cloud/TestFlight build for these changes.

Keyboard dismissal: the scene observes taps outside text fields/views with a simultaneous, non-cancelling gesture so buttons and custom controls still receive touches. A native keyboard toolbar adds Done for numeric keypads, Return dismisses editing, and scroll views dismiss interactively. Syntax checked locally; real-device gesture/keyboard behavior remains to be verified in the next user-authorized build. No cloud build was started for this change.

Latest user-authorized build: `d69ee72f-63d4-494d-8bc8-3cc23ce21b39` compiled, signed (including Wi-Fi entitlement), and uploaded to App Store Connect successfully. This supersedes the earlier "not built" status for the current UI and keyboard changes. Apple processing and physical-device behavior still require verification.

## Quick channel control (source only)

The initial tab is now Quick Control: a local channel keypad with digits, Thru, plus, minus, Clear, Backspace and Enter. Enter validates the expression, selects the channels if connected, and opens a dedicated action page. The full Console is available in More. Typing alone sends no OSC.

Selections support individual channels, ascending ranges, additions and exclusions, capped at 512 channels and 256 input characters. Brightness, presets, Rem Dim, Highlight and Sneak send complete commands targeting the entered expression rather than relying on whatever selection another operator last made. Rem Dim affects other channels; its separate toggle uses the console's current mode and is not presented as a locally verified on/off state. The brightness slider shows last sent intensity, not fabricated live feedback.

Fixture Details opens a dismissible sheet, requests `/eos/get/patch/N` in pages of twelve channels, and reassembles fragmented `/eos/out/get/patch/CHANNEL/PART/list/OFFSET/COUNT` data and notes. It displays labels, fixture type/manufacturer, universe/address, reported level, gel and notes when received. Missing/partial replies remain visibly missing. Refresh sends read-only patch queries. No cloud or TestFlight build was started for this feature. Thirteen Swift tests, including selection validation and out-of-order patch assembly, pass; iOS source syntax checks pass. The new screens still need Apple SDK compilation and device testing.

Quick Control release validation: user-authorized EAS build `3cc56d23-a1cf-4242-8a46-1d5958214efd` finished successfully. Thirteen Swift tests passed; the complete current iOS interface/OSC audit fixes compiled, archived, signed and uploaded to App Store Connect as build `307.04.39`. This supersedes earlier source-only/Apple-SDK-pending notes for these changes. Apple processing and physical-console testing remain separate.

Navigation update: Console is the initial/default tab again. Quick Control retains its keypad and actions and is opened from More → Quick Control. This source change has not been built or uploaded.

Haptic refinement: one reused soft feedback generator now serves controls through a monotonic cadence gate. Continuous movement pulses are limited to one every 180 ms at lighter intensity; discrete taps are deduplicated within 35 ms. Wheels, pan/tilt pad, brightness/fader sliders, color adjustments, tab navigation and More links now participate. The preference is checked before every pulse. Fourteen Swift tests pass, including haptic cadence/preference tests; actual vibration strength/availability depends on device hardware and system settings.

Haptic/navigation release: EAS build `267a3c80-75c6-43ab-9837-8e7820366ea4` passed fourteen Swift tests, Apple SDK compilation, signed export and App Store Connect upload. Console is the default tab and Quick Control is under More. Haptic cadence/preference logic is verified in software; vibration feel still requires a supported physical device. Apple processing remains separate from upload success.

Export compliance: `ITSAppUsesNonExemptEncryption` is explicitly false in the native Info.plist; EAS app metadata also sets `ios.config.usesNonExemptEncryption` false. This declares the current app's lack of non-exempt encryption and avoids the repeated upload questionnaire on future builds. Reassess if app-runtime encryption functionality changes. Existing build `307.5.15` was checked through Apple API: declaration already false and internal state IN_BETA_TESTING. No new build was started for this change.

UI overhaul v2: see `design/REDESIGN.md`. The pre-overhaul source is preserved in a verified baseline archive under `artifacts`, with `scripts/restore-ui.py` for reversible restoration. Console remains the default; Quick Control stays in More. No cloud build/upload was started for this redesign. Syntax and baseline integrity checks passed; native layout review remains pending.

Design v2 release: user-authorized EAS build `96b13340-573a-43d9-afc8-13b5e225f02f` completed successfully and uploaded to App Store Connect. The prior UI baseline and restore utility remain intact.

Refinement pass: see `audit/REFINEMENT-2026-11-03.md` for selective glass styling, shortcut proportions, bounded/coalesced outbound commands, reconnect-safe gestures, monotonic timing, version-reply filtering and decoder fixes. Twenty-three Swift tests and five backend tests pass, and the unsigned Apple SDK check passed for the main changes. No TestFlight upload was started. Pre-refinement design/protocol source is preserved under `artifacts/refinement-baseline-20261103-060951.zip`.
