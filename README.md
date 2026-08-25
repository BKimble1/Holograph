# Holograph

An iPad-only holographic launcher. One immersive screen, a carousel of your own
app icons rendered behind cyan glass, and a tap that opens the real app.

- **Product name** Holograph · **Display name** Holograph
- **Bundle identifier** `com.idlery.holograph` · **App Store Connect record** Holograph Launcher
- **Platform** iPadOS 17+, iPad only (`TARGETED_DEVICE_FAMILY = 2`)
- **Lifecycle** SwiftUI · **Language** Swift 6 · **Dependencies** none

Selected apps stay separate, installed apps. Tapping a tile plays a short portal
animation and then hands the app's registered deep link to iPadOS. Nothing is
embedded, nothing is enumerated.

---

## Getting started

```bash
open Holograph.xcodeproj
```

Choose the **Holograph** scheme and an iPad simulator or device. On first
run the launcher seeds five clearly-labelled demo tiles so the stage is never
blank; delete them and they stay gone.

To add your own app you need the URL scheme it registers with iPadOS — see
[`DEEP_LINK_INTEGRATION.md`](DEEP_LINK_INTEGRATION.md).

### Artwork

Source artwork lives in `Art/` and is the only thing a designer needs to touch:

| File | Becomes |
| ---- | ------- |
| `Art/HoloIcon.png` | the 1024×1024 app icon, and the loading screen's mark |
| `Art/IdleryWordmark.png` | the "powered by idlery" credit on the loading screen |

```bash
python3 Scripts/prepare_artwork.py   # regenerates the asset catalog images
```

The app icon is flattened to opaque RGB, since the App Store rejects icons with
an alpha channel. The other two are keyed to transparency — the mark by its own
luminance, the wordmark by removing its white paper — so both sit on the
launcher's backdrop without a visible edge.

### Regenerating the Xcode project

`Holograph.xcodeproj` is generated from the file tree so adding a source
file never means hand-editing a `pbxproj`:

```bash
python3 Scripts/generate_xcodeproj.py   # after adding or removing files
python3 Scripts/validate_pbxproj.py     # structural check
python3 Scripts/swift_sanity_check.py   # lexical check across all Swift sources
```

CI fails if the committed project is out of step with the source tree.

---

## How it is put together

```
Holograph/
├── App/                  Composition root, launch arguments, scene wiring
├── Models/               LauncherItem — the Sendable snapshot the UI sees
├── Persistence/          SwiftData model, repository protocol, two implementations
├── Services/             Launching, URL validation, App Store lookup, icon processing
├── Features/
│   ├── Holographic/      Backdrop, glass treatment, pedestal, portal effect
│   ├── Launcher/         Carousel, layout maths, view model, page indicator
│   └── Settings/         Glass settings sheet and the add/edit form
├── Demo/                 Five programmatically drawn demo icons
├── Support/              Accessibility identifiers, preview host, launch stub
└── Resources/            Asset catalog, app icon
```

A few decisions worth knowing about:

- **The UI never touches SwiftData.** `LauncherRepository` hands out
  `LauncherItem` value types. `InMemoryLauncherRepository` implements the same
  contract, and both are run against the same test suite.
- **Launching goes through `AppLaunching`.** The production implementation calls
  `UIApplication.open` and reports the system's result. `canOpenURL` is never
  used on user-entered schemes — that would require declaring every scheme in
  advance and amounts to probing what is installed.
- **Icon import is pure ImageIO.** `Data` in, `Data` out, no UIKit, so it is
  `Sendable` and runs off the main actor. Everything is centre-cropped to a
  square and capped at 512px.
- **One switch governs every continuous animation.** `HoloMotion` combines scene
  phase, Reduce Motion and the test flag; every `TimelineView` reads it, so the
  shimmer, scan lines and particles stop when the app is not on screen.
- **Overlays add light, they do not replace colour.** The glass, scan lines and
  shimmer composite with `.screen` and `.plusLighter` at low opacity, so an
  orange tag still reads as orange.
- **The app opens on a loading screen.** The launcher mark settles onto its
  pedestal over the same backdrop the launcher uses, with "powered by idlery" in
  small print along the bottom, then cross-fades to the carousel. The launcher
  is not mounted underneath it, so nothing is reachable before it is usable.

---

## Air gestures

Off by default, switched on under **Settings → Air Gestures**. Flick a hand left
or right in front of the screen, from a foot or two away, and the wall moves the
way your hand went — the same direction a swipe on the glass already moves it.
Gather your fingers and throw them open to launch the centred app.

Nothing on an iPad reports a hand waving in mid-air: there is no proximity or
depth API for it, and ARKit body tracking is far heavier than the question
deserves. `VNDetectHumanHandPoseRequest` returns 21 landmarks per hand from an
ordinary camera frame, and at one to two feet the hand fills enough of the frame
that a 640×480 feed tracks it comfortably. The feed is deliberately small and
slow — VGA at roughly 18 readings a second, late frames discarded. The
connection is mirrored, so moving your hand right moves it right in the frame,
and kept upright as the iPad turns.

### Measured in hands, not in pixels

The same six-inch flick covers about half the frame at a foot and a quarter of
it at two, so a threshold in frame-fractions means a different gesture at every
distance. Every threshold here is instead expressed in **knuckle spans** — the
width of the hand across the index and little-finger knuckles, about 3.3 inches,
and the one measurement on a hand that barely changes as the fingers move. A
six-inch flick is 1.8 spans whether you are close or far.

The same ruler gives the burst: fingertip spread is measured in spans too, so
gathered fingers read low and a thrown-open hand reads high regardless of
distance.

### What counts

`AirGestureDetector` decides, from how far the hand crossed, how fast, and how
straight the path was. Reversing is treated differently from repeating: after a
flick the hand has to come back, and that return journey is not a gesture — it
is the cost of having made one. So the same flick counts again quickly, while
the opposite one has to wait long enough to be meant.

It is a value type over plain numbers, so all of it is unit-tested by playing a
hand through it frame by frame, with distances written in inches: a six-inch
flick, a ten-inch flick, a three-inch nudge, the same distance taken slowly, a
path that doubles back, a hand leaving the frame, a return stroke, a deliberate
reverse, fingers thrown open, a hand already open, and a slow unfurl.

The camera runs only while the launcher is on screen, the feature is on, and the
scene is active — never behind Settings, never in the background. Nothing is
recorded and no video leaves the device; frames are analysed and dropped, and the
only thing that leaves the detector is a gesture.

---

## Sound

Two accents, both on by default and both switchable in Settings:

- **A click as the carousel moves.** Synthesised rather than shipped as an audio
  file. A click is a short burst of broadband energy with a resonance in it, over
  in a few milliseconds, so `HoloClick.waveform()` builds 22 ms of filtered noise,
  a 2.4 kHz resonance and a low knock, all decaying at once. Its noise comes from
  a seeded generator, so the sound is identical every time and its shape is
  unit-tested directly: how quickly it peaks, how fast it collapses, and that the
  attack is broadband rather than a pitch.
- **"Opening <app>" as one launches**, in a woman's voice, unhurried and level.
  `HoloVoice` ranks the installed voices — a woman first, then British, then the
  particular voice, then the quality of the recording. Gender comes from a list
  of Apple's own voice names before the API's `gender`, because plenty of
  installed voices report none at all, and a stock British device that has only
  Daniel installed will otherwise hand you a man. For the best result, download
  an English (UK) voice such as Serena under **Settings → Accessibility → Spoken
  Content → Voices**. A refused launch cancels the announcement, so the voice
  never contradicts the recovery alert.

The session is `.playback` with `.mixWithOthers`. `.ambient` would be the politer
category, but it is silenced by the Ring/Silent switch — the Control Centre
toggle on an iPad — which mutes both sounds and looks exactly like the feature
being broken. These are sounds the user asked for and can switch off in
Settings, so they play on their own terms while still never interrupting
anything already playing. The announcement is suppressed while VoiceOver is
running, which is already describing the tap.

The tick reaches `AVAudioPlayer` as a self-contained WAV built in memory by
`HoloClick.wavData()` — finished bytes are far less to go wrong than an engine
graph for a 60 ms sound, and the container is checked byte for byte in tests.
Everything is best-effort: a device that cannot play simply stays quiet.

---

## Accessibility

- Reduce Motion swaps the continuous depth curve for a single scale step, stops
  the shimmer, scan-line drift and particle field, and shortens the launch
  ceremony.
- Every tile is a labelled button with a hint that says whether a tap will
  centre it or open it, plus a matching custom action.
- Left and right arrow keys move the selection; Return and Space open the
  centred app.

---

## Deterministic launch arguments

Used by the UI tests; a build installed from the App Store or TestFlight cannot
receive them, so the shipping app always takes the production path.

| Argument               | Effect                                            |
| ---------------------- | ------------------------------------------------- |
| `-uiTesting`           | Silent feedback, non-persisted selection          |
| `-inMemoryStore`       | SwiftData store held in memory only               |
| `-seedDemoApps`        | Replace the library with the five demo tiles      |
| `-seedEmpty`           | Empty library, to exercise the empty state        |
| `-disableAnimations`   | Stop continuous effects, shorten the loading screen |
| `-mockLaunchSuccess`   | `AppLaunching` reports success without switching  |
| `-mockLaunchFailure`   | `AppLaunching` reports failure                    |

---

## Tests

```bash
# Unit tests
xcodebuild test -project Holograph.xcodeproj -scheme Holograph \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:HolographTests

# UI tests
xcodebuild test -project Holograph.xcodeproj -scheme Holograph \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:HolographUITests
```

CI (`.github/workflows/ci.yml`) picks whichever iPad simulator the runner has,
so it does not depend on a particular device name.

---

## Shipping to TestFlight

`.github/workflows/testflight.yml` is manual (**Actions → TestFlight → Run
workflow**). It runs the test suite, archives with automatic signing via the App
Store Connect API, exports and uploads. It needs four repository secrets:

| Secret                           | Where it comes from                                  |
| -------------------------------- | ---------------------------------------------------- |
| `APPLE_TEAM_ID`                  | App Store Connect → Membership                        |
| `APP_STORE_CONNECT_KEY_ID`       | Users and Access → Integrations → App Store Connect API |
| `APP_STORE_CONNECT_ISSUER_ID`    | Same page, above the key list                         |
| `APP_STORE_CONNECT_PRIVATE_KEY`  | The `.p8` file's contents, pasted whole               |

The `.p8` is written to the runner with mode 600, never printed, and deleted
afterwards. Nothing is uploaded unless the archive and tests are green.

### The signing certificate

Those four secrets authenticate to Apple. They are not, on their own, enough to
*sign*: signing needs a distribution certificate's **private key**, and Apple
never releases one after it is created. A hosted runner starts with an empty
keychain, so it has to be handed a key or be allowed to create its own. Take
either route.

**A key that can create its own.** Generate the App Store Connect API key under
the **App Manager** role (Users and Access → Integrations). Xcode's cloud
signing then creates and manages both the certificate and the App Store
provisioning profile, and nothing else is needed. A key's role is fixed when it
is generated, so a Developer-role key cannot be promoted — generate a new one
and update `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_PRIVATE_KEY`.
A key without this role fails at export with `Cloud signing permission error`.

**Or supply the certificate.** In Keychain Access on a Mac that already holds an
Apple Distribution certificate, export it as `.p12`, then add two more secrets:

| Secret                              | Value                                  |
| ----------------------------------- | -------------------------------------- |
| `APPLE_DISTRIBUTION_CERT_P12`       | `base64 -i cert.p12` — the whole string |
| `APPLE_DISTRIBUTION_CERT_PASSWORD`  | The password set during export          |

The workflow imports it into a throwaway keychain and deletes both the file and
the keychain when it finishes. This route also needs an **App Store provisioning
profile for `com.idlery.holograph`** to exist in the developer portal — a
read-only key can download a profile but cannot create one.

The workflow's first step reports what the key can actually see — certificates,
profiles, devices and bundle IDs, by count and by Apple's own error codes — so a
signing problem says which of these is missing instead of failing opaquely.

---

## Privacy

Everything stays on the iPad. No account, no iCloud, no analytics. The only
network call is optional: pasting an App Store link to borrow an app's name and
artwork, which hits Apple's public lookup endpoint. Declining it costs nothing —
type the details in by hand.
