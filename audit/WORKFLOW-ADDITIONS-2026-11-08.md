# iOS workflow additions — November 8, 2026

Implemented locally in BridgeViewController.swift, OSCCodec.swift and EosPracticeDesk.swift. No gel library, macros page, group browser or channel-check page added.

## Entry points and behavior

- Console: Type Command opens keyboard input. Numbers default to Chan, Return submits, Command-L starts Chan, Command-Q starts Cue, Command-Delete clears, Escape closes. Recent selection chips recall session-scoped selections without changing levels. Changing the selection invalidates in-progress gestures and command drafts.
- More > My Work Screens: multiple named, saved layouts with reorderable and removable submaster, palette, preset, selection and main-playback controls. Layouts remain on device. They refer to console target numbers, so verify target numbering when changing shows.
- Movement: larger Fine Focus page, axis locks, sensitivity, coarse/fine control and direction inversion. Changing resolution or axes discards outstanding touch movement. Reset Touch clears the touch indicator without moving fixtures.
- Fixture wheels > Set Value: absolute numeric values using reported units. All selected fixtures must report the parameter and accept the value within their individual ranges. Limited to 12 fixtures per action; no partial send on validation failure. Named gobo/slot labels are not invented from numeric values.
- Cue browser > cue detail > Edit Cue Notes: separate console notes and locally saved rehearsal notebook. Notebook names are explicit and local notes are scoped by console address and cue part. Console writes use one literal string argument and retain the cue part. Sent writes are not advertised as acknowledged saves.
- More > Record Palette: review selected channels, category, target number and optional label. Records focus/color/beam category only. The app does not auto-confirm overwrites. Labels are a separate explicit action after the operator checks the record result. Review becomes invalid after a selection/session change.
- Submaster detail and work screens: direct level, paired bump, home, full and out. Metadata already includes reported mode, priority and timing. Unsupported stop/load endpoints have not been fabricated.
- Magic Sheets: saved PNG/JPEG background with up to 12 manually placed channel targets. Pinch/pan/double-tap fit remain available. Target taps select channels; Movement/Color links operate on that selection. Target patch levels refresh every five seconds, and expired replies disappear after 12 seconds. Replacing the background clears target placement. The background itself remains static.
- Console Health: actionable connection/feedback/user/parameter diagnostics and a shareable report excluding raw packet payloads and console host addresses.
- More > Why Is This Light On?: reports queried fixture values and routes to submaster/connection information. Source attribution is explicitly unavailable: no supported source-owner query has been verified for the original Element setup. No automatic unpark, release or level changes.

## Outstanding dependencies

- Automatic interactive Magic Sheet XML import is unfinished. An actual XML export and associated image assets from the user's Element are needed to verify the schema, object coordinates, types and mappings. The implemented interaction uses manual channel targets over a static image; it is not a claim of full XML import or console screen mirroring.
- Focus Wand and Find Me are separate unfinished AR features, not part of this implementation.
- Exact installed Eos version and live fixture behavior remain unverified. Source-owner attribution and named parameter slots need verified console replies before adding them.
- SwiftUI/UIKit have not been fully type-checked with Xcode in this Linux environment. No TestFlight build was requested or started in this turn.

## Validation

- Swift frontend syntax parsing passed for BridgeViewController.swift.
- All 73 OSCWire Swift tests passed under Swift 6.2 on Linux, including six new workflow tests.
- New tests cover numeric channel defaults, literal cue-note content and part targeting, palette selection scoping and separate label arguments, finite/range validation across mixed fixtures, paired bump release and category-specific practice palette recall.
- Test Mode retains edited cue notes/palette records during browser refresh and stores recorded palette values separately by category/channel. Submaster bumps restore their pre-bump practice level after release.

## Protocol references

- https://www.etcconnect.com/WebDocs/Controls/EosFamilyOnlineHelp/en/Content/22_Show_Control/08_OSC/OSC_Dictionary.htm
- https://www.etcconnect.com/WebDocs/Controls/EosFamilyOnlineHelp/en/Content/22_Show_Control/08_OSC/Using_OSC_with_Eos/OSC_Third-Party_Integration/OSC_Get.htm
