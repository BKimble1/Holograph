# Holograph

An iPad-only holographic launcher, and a small environment of its own. One
immersive screen, a wall of your own tiles rendered behind cyan glass, and a tap
that opens an app, a website, or a folder holding either.

- **Product name** Holograph · **Display name** Holograph
- **Bundle identifier** `com.idlery.holograph` · **App Store Connect record** Holograph Launcher
- **Platform** iPadOS 17+, iPad only (`TARGETED_DEVICE_FAMILY = 2`)
- **Lifecycle** SwiftUI · **Language** Swift 6 · **Dependencies** none

Three kinds of tile, all with the same holographic treatment:

- **Apps** stay separate, installed apps. Tapping one plays a short portal
  animation and then hands the app's registered deep link to iPadOS. Nothing is
  embedded, nothing is enumerated.
- **Websites** open *inside* Holograph, in its own browser, and you keep your
  place on the wall.
- **Folders** open over the stage on a pane of dark glass, without leaving.

Optionally, the launcher follows roughly where your head is and shifts
perspective around it, and speaks each launch in a neural voice that runs
entirely on the iPad.

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
├── Models/               LauncherItem and its kind — the Sendable snapshot the UI sees
├── Persistence/          SwiftData model, repository protocol, two implementations
├── Services/             Launching, URL validation, camera, gestures, claps, speech
├── Features/
│   ├── Holographic/      Backdrop, glass treatment, pedestal, portal effect
│   ├── Launcher/         Carousel, layout maths, view model, page indicator
│   ├── Browser/          The in-app Holo Browser and its navigation policy
│   ├── Folders/          The glass plate a folder opens on
│   └── Settings/         Glass settings sheet and the add/edit form
├── Demo/                 Five programmatically drawn demo icons
├── Support/              Accessibility identifiers, preview host, launch stub
└── Resources/            Asset catalog, app icon
```

A few decisions worth knowing about:

- **The UI never touches SwiftData.** `LauncherRepository` hands out
  `LauncherItem` value types. `InMemoryLauncherRepository` implements the same
  contract, and both are run against the same test suite.
- **One item type, three kinds.** `LauncherItemKind` is `.app`, `.website` or
  `.folder`; `launchURL` is optional because a folder genuinely has nowhere to
  go. Ordering is per scope — the root wall and each folder number themselves
  from zero — so dragging inside a folder cannot disturb the wall behind it.
  Folders do not nest.
- **The stored type is still called `StoredLauncherApp`.** SwiftData derives the
  entity name from the class, so renaming it would orphan every record already
  on somebody's iPad. Kind and parent folder were added as *optional*
  attributes, which is what lets every existing store migrate with no versioned
  plan: a record written before this change reads back as exactly what it was —
  an app on the root wall, keeping its id, name, links, icon, order, demo flag
  and dates.
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
There is a short settling pause afterwards, so bringing your hand back and
setting up again counts for nothing. For a longer journey, put your fingertips
together and sweep: the wall comes with you, an app every couple of inches,
until you open your hand. Opening a tile is a **double clap**, not a gesture.

Nothing on an iPad reports a hand waving in mid-air: there is no proximity or
depth API for it, and ARKit body tracking is far heavier than the question
deserves. `VNDetectHumanHandPoseRequest` returns 21 landmarks per hand from an
ordinary camera frame, and at one to two feet the hand fills enough of the frame
that a 640×480 feed tracks it comfortably. The feed is deliberately small and
slow — VGA at roughly 18 readings a second, late frames discarded. The
connection is mirrored, so moving your hand right moves it right in the frame,
and kept upright as the iPad turns.

### Measured in hands, not in pixels

The same flick covers about twice as much of the frame at a foot as it does at
two, so a threshold in frame-fractions means a different gesture at every
distance. Every threshold here is instead expressed in **knuckle spans** — the
width of the hand across the index and little-finger knuckles, about three
inches, and the one measurement on a hand that barely changes as the fingers
move. A four-inch flick is 1.2 spans whether you are close or far.

The same ruler gives the burst: fingertip spread is measured in spans, so
gathered fingers read about 0.13 and a fully splayed hand about 0.69 — numbers
worth knowing, because a threshold set above what a hand can reach is a gesture
that never fires.

### A swipe needs knuckles, not fingertips

A hand mid-flick is motion-blurred, and fingertips are the first landmarks to
fall below confidence. Position and scale come from the wrist and knuckles
alone, and the fingertip spread is optional — a reading without it still drives
a swipe, and only the burst goes without.

### Position and scale are smoothed apart

`HandReading` carries `x` and `span` separately, and the detector never divides
one by the other until both have been smoothed. Dividing per frame folds the
noise in the *scale* estimate into the *position*: a span wobbling by eight per
cent moves a still hand by half a span — most of a flick — and that phantom
speed is what made one flick sometimes move two apps.

Position goes through a [1€ filter](https://gery.casiez.net/1euro/), whose
cutoff rises with speed: heavy smoothing while the hand is still, where jitter
is the whole problem, and almost none while it is moving, where lag is. At the
tuned settings it removes the jitter while giving back about ninety per cent of
a short flick's travel — plain smoothing would eat a quarter of it, and a
gesture only gets credit for the displacement that survives. The span is
smoothed hard on its own: a hand does not change width, so anything moving there
is measurement noise.

### One movement, one gesture

A threshold test fires the instant it is crossed and then re-arms on a timer, so
a single long sweep can trip it twice and the journey back can trip it again.
The detector is a state machine instead. A movement is a **stroke**: it opens
when the hand starts moving, yields at most one gesture, and does not re-arm
until the hand has come to rest. Starting and stopping use different speeds —
hysteresis — so a hand hovering near the threshold cannot chatter across it.

That single rule replaces every cooldown. The return stroke is silent because
the hand has not stopped yet; a deliberate second flick works immediately
because it has. And a stroke is measured from **where the hand was last still**,
not from where it happened to be when the speed gate opened — by then a third of
the flick has already happened, and the gesture reads as too small to count.

### Tuned by measurement, not by taste

A gesture threshold cannot be judged from one run: the same flick succeeds or
fails depending on which way the landmark noise happened to fall, and a single
lucky trial reads as proof. Every threshold here was chosen by running each
scenario over two hundred independent noise realisations and reading off the hit
rate.

That is how the current numbers were picked. Loosening the travel threshold buys
shorter flicks — a three-inch flick goes from 94% to 100% — until waving starts
registering as a gesture, which happens first and sets the floor. At the shipped
setting every intended gesture fires every time and every unintended one stays
silent every time.

It also caught a threshold that could not work: the speed counting as "stopped"
had been set *below* the speed a still hand appears to move at through landmark
noise, so the hand was sometimes never seen to stop, and the detector sat
refusing to fire again. The stillness test now takes the median of the last few
speeds, so one noisy frame cannot masquerade as the hand setting off.

The same scenarios are the unit tests, noise included.

The camera runs only while the launcher is on screen, the feature is on, and the
scene is active — never behind Settings, never in the background. Nothing is
recorded and no video leaves the device; frames are analysed and dropped, and the
only thing that leaves the detector is a gesture.

---

## Calibration

Every threshold above is an average of people. **Settings → Calibrate to You**
replaces the ones that vary most with measurements of you: three short
exercises, a minute in total, and nothing kept but a handful of numbers.

The design rule throughout is that a calibration must never be able to make the
launcher *worse*. Each exercise measures, takes a robust statistic rather than a
best or worst case, applies a safety margin in the forgiving direction, and
clamps the result to a range the detector is known to work in. A run that goes
badly — a hand out of frame, a quiet room, three claps that were really one —
lands on the clamp, which is roughly where the default already was.

| Exercise | What you do | What it measures | What it sets |
| --- | --- | --- | --- |
| **Hand** | Three flicks left and right, at your distance | Peak speed and travel of each flick | `flickStartSpeed`, `flickTravelSpans` |
| **Face** | Look around the screen — corner to corner | How far your head actually moves in frame | `headRange` |
| **Clap** | Three double claps, at your volume | Level of the quietest clap, widest gap between the pair | `clapLevel`, `clapMaximumGap` |

**Why medians, and why those margins.** A calibration set from your *fastest*
flick would refuse every ordinary one; set from your slowest it would fire on a
wave. The hand exercise therefore takes the **median** peak speed of the flicks
it saw and keeps **45%** of it, and the median travel and keeps **55%** — so an
average flick clears the bar with room to spare, and an unusually lazy one still
does. The clap exercise works from the **quietest** clap rather than the median,
because a threshold above your quietest clap is a threshold that misses claps,
and takes another **6 dB** off it; the gap between the two claps takes the
**widest** you produced and adds **35%**. Head range weights horizontal movement
over vertical (0.7 / 0.3, because that is the axis the effect is mostly built
from), halves it to a per-side figure, and keeps 80%.

Three flicks and three double claps is deliberate: enough for a median to mean
something, few enough that people actually finish. The flow simply keeps
listening until it has three good ones and shows each as it lands, so you can
see it working rather than guessing. The face exercise is different in kind — it
wants coverage, not repetitions — so it collects 45 readings while you look
around and takes the extent of where your head went.

The maths is pure and lives in `Calibration.swift` — `HandCalibrator`,
`HeadCalibrator`, `ClapCalibrator` — with no camera, microphone or UI anywhere
near it, which is why it is all directly unit tested, clamps included.
`CalibrationProfile` is a small `Codable` struct of optionals; anything not
measured keeps its default, and **Reset** removes the file. `applying(_:)` on
each detector's `Thresholds` is where a profile turns into behaviour, and it is
the only place that can, so there is exactly one thing to test.

Sensing during calibration goes through the same `HoloCameraSource` as
everything else, as a third consumer alongside gestures and head tracking, with
raw readings switched on for the duration. Nothing is recorded.

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
- **"Opening &lt;name&gt;" as an app or website opens**, in a local neural voice —
  see below. Folders are silent on purpose: opening one does not leave
  Holograph, and narrating it would make a movement inside the launcher sound
  like a departure from it. A refused launch cancels the announcement, so the
  voice never contradicts the recovery alert.

The session is `.playback` with `.mixWithOthers`, or `.playAndRecord` while
clap-to-open is listening — `HoloAudioSession` decides in one place rather than
letting whichever feature configured itself last win. `.ambient` would be the
politer category, but it is silenced by the Ring/Silent switch — the Control
Centre toggle on an iPad — which mutes both sounds and looks exactly like the
feature being broken. These are sounds the user asked for and can switch off in
Settings, so they play on their own terms while still never interrupting
anything already playing. The announcement is suppressed while VoiceOver is
running, which is already describing the tap.

Both reach `AVAudioPlayer` as self-contained WAVs built in memory by
`PCMWaveWriter` — finished bytes are far less to go wrong than an engine graph
for a sound this short, and the container is checked byte for byte in tests.
Everything is best-effort: a device that cannot play simply stays quiet.

### The launch voice

The voice speaks the moment Holograph is installed. Nothing is downloaded,
nothing is provisioned, and nothing has to be switched on — which is the whole
requirement, and the reason it is built in two layers rather than one.

`LayeredSpeech` holds a preferred engine and a fallback, prepares both, asks the
preferred one first, and drops to the fallback the instant it cannot answer —
not installed, failed to load, or simply nothing rendered for one awkward
phrase. Callers never learn which one spoke.

- **Preferred: Kokoro-82M**, an Apache-2.0 neural model run locally with Core
  ML, in Kokoro's British male **`bm_george`** at a speech rate of 0.94. It
  speaks whenever a build ships the model. It is a Holograph voice, not an
  impersonation of anybody.
- **Fallback: the system's own British voice.** `SystemVoiceCatalogue` picks
  the closest match to that register from what the iPad already has, in a ladder
  that cannot come up empty: the best-quality British male voice, else any
  British voice, else any English one, else the system default. On a stock iPad
  that is Daniel. Ties break on identifier, so the voice never changes between
  launches — a voice that did would sound like a fault.

The fallback renders through `AVSpeechSynthesizer.write(_:toBufferCallback:)`
rather than by speaking directly, so its samples travel the same path as every
other sound the launcher makes: the same caching, the same ducking, the same
silent-switch behaviour, and the same microphone hold-off that stops the
launcher's own voice being heard as a clap.

Settings reports a problem only when **nothing at all** can speak. A missing
neural model is not a state the user experiences while a voice is still
talking, and saying so would be describing our packaging rather than their
iPad.

Everything about synthesis is on-device by construction — both layers.
`KokoroSpeechEngine` reads a compiled model and a style vector from disk and
runs `MLModel`, and `AVSpeechSynthesizer` renders locally; there is no endpoint,
no key and no request, and a unit test scans those sources to make sure it stays
that way.

Latency is treated as the point rather than an afterthought:

- The engine is warmed **after** the launcher is usable, never during the
  loading screen.
- Each launch phrase is rendered once and cached, keyed by item id **and**
  current name — so renaming a tile re-renders it and the old name is dropped.
- The library's phrases are rendered opportunistically once it loads, so the
  first app opened is as quick as the tenth.
- Tapping never waits on synthesis. A cached phrase plays immediately; an
  uncached one is started and simply not waited for. The app opens on exactly
  its usual schedule either way.
- If the voice fails to load, the announcement is skipped and logged. It is a
  decoration and is never allowed to become a dependency.

**Model files.** `bm_george.bin`, the 510 × 256 style vector, *is* committed and
shipped in the bundle. The Core ML weights are not: `Kokoro.mlmodelc` is 160 MB
in the smallest useful precision, which is past GitHub's 100 MB per-file limit
and would have to be sharded and reassembled at build time. `KokoroModelStore`
looks in the app bundle first, then in `Application Support/Kokoro/`. Until the
model is provisioned the system voice speaks instead, which is why nothing about
this is visible to the user. See [`docs/KOKORO.md`](docs/KOKORO.md).

---

## Head-tracked 3D

Off by default, switched on under **Settings → Depth**. The launcher follows
roughly where your head is and shifts perspective around it, so the wall reads
as hanging behind the display rather than sitting on it. The background drifts
at a slower depth than the tiles, which is most of what sells it.

The hard part is not finding a head. A face bounding box jitters by a couple of
per cent every frame, and a window that trembles is worse than one that does not
move at all — so `HeadTracker` reuses the same 1€ filter the hand gestures
depend on, with a dead zone whose response starts from zero rather than stepping
at its edge, a hard clamp, and a fade rather than a snap when the viewer leaves.
Where you were sitting when the camera first saw you counts as straight on, so
using an iPad from an armchair off to one side does not mean a permanently
tilted scene.

**Why it used to look glitchy, and what fixed it.** The camera delivers about 30
frames a second; the display draws 60 to 120. No amount of filtering at the
source can fix that, because the source is simply not producing a value for
every frame drawn — the scene holds still, jumps, holds still, jumps, and reads
as stepping rather than moving. Each new reading is therefore handed to a short
critically-damped spring (0.14 s, no bounce) and the display interpolates
between readings instead of waiting for them. The filter removes the noise; the
spring removes the stair-step. They are two different problems and needed two
different fixes.

**And it moves further.** The range that counts as a full turn of the head came
down to 0.17 of the frame, so an ordinary shift in a chair reaches most of the
effect rather than a tenth of it, and the dead zone came down to 0.05 with it.
The wall itself travels 46 points and rotates up to 9°, with 5° of vertical
tilt; the background drifts 70 points at roughly a third of the depth, which is
what makes the two planes separate.

Reduce Motion does not switch it off; it takes the travel down to a quarter,
which keeps the depth while putting the movement well inside what Reduce Motion
is asking for. Under test it is off entirely, so screenshots never depend on a
face being in front of the runner.

### One camera, two features

Air gestures and head tracking attach to a single `HoloCameraSource`. It starts
when the first attaches and stops when the last lets go, runs only the Vision
requests something is actually using, and is off behind Settings, behind the
browser and in the background. Two `AVCaptureSession`s would be twice the power
for the same pictures, and on iPadOS the second to start simply loses.

---

## The Holo Browser

A website tile opens a `WKWebView` inside Holograph. That is the whole promise
of calling it a website tile: being thrown out to Safari would lose your place
on the wall.

- Back, forward, reload, the page or site name, and a close `×` — in the app's
  own glass, not stock browser chrome. Escape closes it on a hardware keyboard.
- `WKWebsiteDataStore.default()`, so a site you have signed into still knows you
  next time. That state belongs to WebKit and never touches the launcher's
  library.
- `target="_blank"` and `window.open` load in place rather than being lost.
- `HoloBrowserPolicy` decides what may be followed, and has no WebKit in it at
  all: `http` and `https` stay inside; `tel:`, `mailto:` and app schemes are
  handed to iPadOS, because a web view genuinely cannot answer them; and
  `javascript:`, `file:`, `data:` and `blob:` go nowhere.

Websites are validated more strictly than apps when they are added —
`WebsiteURLValidator` accepts only `http` and `https` — because a custom scheme
behind a tile that says "website" is a way to run something the user did not ask
for.

---

## Folders

A folder is an ordinary tile: same size, same glass, same depth treatment, same
caption behaviour, your own artwork or the monogram fallback. Activating it
lights a pane of dark glass over the wall and shows what is inside.

The contents are shown by the same carousel the root uses, which is deliberate:
snapping, keyboard control, VoiceOver, air gestures and clap-to-open all work
inside a folder without being written twice. The wall keeps its own selection,
so closing puts you back on the folder you came from. Escape closes it.

**A folder groups tiles; it does not take them off the wall.** Something in a
folder appears in both places, the way a song in a playlist is still in your
library. A folder is a second route to the same tile, never a place tiles
disappear to — so putting Mail in Work leaves Mail exactly where it was.

That is why each tile carries two positions: `sortOrder` for the wall and
`folderSortOrder` for inside its folder. The same tile can be third on the wall
and first in a folder, and reordering one scope cannot disturb the other.

Manage folders in Settings: create and name one, give it an icon, and use each
row's **Add To…** menu — *add*, not move. Opening a folder's own settings offers
everything not already in it. Removing something from a folder only removes the
grouping. **Deleting a folder never deletes what is in it**, and never even
moves it: its members were on the wall the whole time, so only the grouping
goes.

---

## Accessibility

- Reduce Motion swaps the continuous depth curve for a single scale step, stops
  the shimmer, scan-line drift and particle field, and shortens the launch
  ceremony.
- Every tile is a labelled button that names its kind — "CoreCredit, app",
  "GitHub, website", "Work, folder, 4 items" — with a hint that says whether a
  tap will centre it, open it, or open it inside Holograph, plus a matching
  custom action. Nothing else on a tile tells you whether activating it will
  leave the app.
- The browser's controls are labelled, and its title plate reads as
  "Showing &lt;page&gt;".
- Left and right arrow keys move the selection; Return and Space open the
  centred tile; Escape closes a folder or the browser.
- Neither air gestures nor head tracking is ever required. Touch and keyboard
  do everything.

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

Everything stays on the iPad. No account, no iCloud, no analytics.

- **The camera** is used only while the launcher is on screen and a camera
  feature is switched on. Frames are analysed and discarded. Holograph does not
  recognise faces or identify anyone — head tracking estimates a viewing
  position and nothing else — and no camera frame, face image, identity or
  embedding is ever stored or transmitted.
- **The microphone** is used only while clap-to-open is on and the launcher is
  on screen. Each moment of sound becomes a single loudness number and is thrown
  away; no audio is recorded or transmitted.
- **The launch voice** is synthesised on the device. No endpoint, no key, no
  request.
- **Websites** you open in the Holo Browser keep cookies and sessions in
  WebKit's own store, exactly as a browser would, separate from the launcher's
  library.
- **The only network call Holograph itself makes is optional**: pasting an App
  Store link to borrow an app's name and artwork, which hits Apple's public
  lookup endpoint. Declining it costs nothing — type the details in by hand.

---

## Third-party notices

- **Kokoro-82M** — Apache License 2.0. Used as a Core ML model for local speech
  synthesis. Weights are not distributed in this repository; see
  [`docs/KOKORO.md`](docs/KOKORO.md) for how they are provisioned and for the
  licence text that must ship with a build that bundles them.

Everything else in the app is first-party: no packages, no vendored source.
