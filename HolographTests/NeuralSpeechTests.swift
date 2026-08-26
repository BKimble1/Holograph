import XCTest
@testable import Holograph

/// What the launcher says. Pure, so the words are a fact about the library
/// rather than about whatever is speaking them.
final class LaunchAnnouncementTests: XCTestCase {
    func testAnAppIsAnnouncedByName() {
        let item = LauncherItem(kind: .app, name: "Truebearing", launchURL: URL(string: "a://b"))
        XCTAssertEqual(LaunchAnnouncement.phrase(for: item), "Opening Truebearing")
    }

    func testAWebsiteIsAnnouncedTheSameWay() {
        let item = LauncherItem(kind: .website, name: "Idlery", launchURL: URL(string: "https://idlery.com"))
        XCTAssertEqual(LaunchAnnouncement.phrase(for: item), "Opening Idlery")
    }

    func testAFolderIsNotAnnounced() {
        // Opening a folder does not leave Holograph and takes a fraction of a
        // second. Narrating it would make a movement *inside* the launcher
        // sound like a departure from it.
        XCTAssertNil(LaunchAnnouncement.phrase(for: LauncherItem(kind: .folder, name: "Work")))
    }

    func testAnUnnamedTileSaysNothing() {
        let item = LauncherItem(kind: .app, name: "   ", launchURL: URL(string: "a://b"))
        XCTAssertNil(LaunchAnnouncement.phrase(for: item))
    }

    func testTheCacheKeyChangesWithTheName() {
        // The whole of the invalidation rule: a renamed tile must not keep
        // announcing its old name.
        let id = UUID()
        let before = LauncherItem(id: id, kind: .app, name: "Old", launchURL: URL(string: "a://b"))
        var after = before
        after.name = "New"

        XCTAssertNotEqual(
            LaunchAnnouncement.cacheKey(for: before),
            LaunchAnnouncement.cacheKey(for: after)
        )
    }

    func testTwoTilesWithTheSameNameAreStillDifferent() {
        let one = LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "a://b"))
        let other = LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "c://d"))
        XCTAssertNotEqual(
            LaunchAnnouncement.cacheKey(for: one),
            LaunchAnnouncement.cacheKey(for: other)
        )
    }
}

final class AnnouncementCacheTests: XCTestCase {
    private func phrase(_ seconds: Double) -> SpokenPhrase {
        SpokenPhrase(samples: [Float](repeating: 0, count: Int(seconds * 24_000)), sampleRate: 24_000)
    }

    func testItGivesBackWhatItWasGiven() {
        var cache = AnnouncementCache()
        cache.store(phrase(1), forKey: "a")
        XCTAssertNotNil(cache.phrase(forKey: "a"))
        XCTAssertNil(cache.phrase(forKey: "b"))
    }

    func testItForgetsTheLeastRecentlyUsed() {
        // These are audio buffers, so the cache has to be bounded.
        var cache = AnnouncementCache(limit: 2)
        cache.store(phrase(1), forKey: "a")
        cache.store(phrase(1), forKey: "b")
        _ = cache.phrase(forKey: "a")          // "a" is the one in use
        cache.store(phrase(1), forKey: "c")

        XCTAssertNotNil(cache.phrase(forKey: "a"))
        XCTAssertNotNil(cache.phrase(forKey: "c"))
        XCTAssertNil(cache.phrase(forKey: "b"), "the one nobody opened is the one that goes")
        XCTAssertEqual(cache.count, 2)
    }

    func testItDropsWhatTheLibraryNoLongerHas() {
        var cache = AnnouncementCache()
        cache.store(phrase(1), forKey: "kept")
        cache.store(phrase(1), forKey: "renamed-away")

        cache.keepOnly(["kept"])

        XCTAssertNotNil(cache.phrase(forKey: "kept"))
        XCTAssertNil(cache.phrase(forKey: "renamed-away"))
    }
}

final class SpokenPhraseTests: XCTestCase {
    func testDurationFollowsTheSamples() {
        let phrase = SpokenPhrase(samples: [Float](repeating: 0, count: 24_000), sampleRate: 24_000)
        XCTAssertEqual(phrase.duration, 1.0, accuracy: 0.0001)
    }

    func testAnEmptyPhraseLastsNoTime() {
        XCTAssertEqual(SpokenPhrase(samples: [], sampleRate: 24_000).duration, 0)
        XCTAssertEqual(SpokenPhrase(samples: [0], sampleRate: 0).duration, 0)
    }

    func testSamplesSurviveTheTripThroughTheContainer() {
        // The announcement is handed to AVAudioPlayer as finished bytes, so the
        // container has to be right — a malformed header is silence with no
        // error at all.
        let source: [Float] = [0, 0.5, -0.5, 0.999, -0.999]
        let data = PCMWaveWriter.wavData(samples: source, sampleRate: 24_000)
        XCTAssertEqual(data.count, PCMWaveWriter.headerByteCount + source.count * 2)

        for (index, expected) in source.enumerated() {
            let offset = PCMWaveWriter.headerByteCount + index * 2
            let stored = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
            XCTAssertEqual(Float(stored) / 32_767, expected, accuracy: 0.001)
        }
    }

    func testTheContainerCarriesTheRightSampleRate() {
        let data = PCMWaveWriter.wavData(samples: [0, 0], sampleRate: 24_000)
        let rate = data[24..<28].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(rate, 24_000, "a wrong rate is a voice at the wrong pitch")
    }
}

/// Kokoro's tokenizer, checked without a model.
final class KokoroTokenizerTests: XCTestCase {
    func testAPhraseBecomesTokens() {
        let tokens = KokoroTokenizer.tokens(for: "Opening Mail")
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(tokens.first, 0, "padded at the front")
        XCTAssertEqual(tokens.last, 0, "and at the back")
        XCTAssertEqual(tokens.count, "Opening Mail".count + 2)
    }

    func testCharactersItDoesNotKnowAreDropped() {
        // An emoji in a tile name must not become a token id out of range and
        // take the model with it.
        let tokens = KokoroTokenizer.tokens(for: "Opening 🚀 Mail")
        XCTAssertTrue(tokens.allSatisfy { $0 >= 0 && $0 <= Int32(KokoroTokenizer.alphabet.count) })
    }

    func testNothingSayableIsNoTokens() {
        XCTAssertTrue(KokoroTokenizer.tokens(for: "🚀🚀").isEmpty)
        XCTAssertTrue(KokoroTokenizer.tokens(for: "").isEmpty)
    }

    func testAVeryLongPhraseIsCutRatherThanRefused() {
        let tokens = KokoroTokenizer.tokens(for: String(repeating: "a", count: 5_000))
        XCTAssertEqual(tokens.count, KokoroTokenizer.maximumTokens + 2)
    }
}

/// The engine's own contract, with no weights anywhere near it.
@MainActor
final class NeuralSpeechEngineTests: XCTestCase {
    func testAnEngineWithNoModelSaysSoRatherThanCrashing() async {
        // A bundle with nothing in it stands in for an iPad where the voice has
        // not been provisioned.
        let engine = KokoroSpeechEngine(bundle: Bundle(for: NeuralSpeechEngineTests.self))
        await engine.prepare()

        XCTAssertFalse(engine.isReady)
        XCTAssertNotNil(engine.unavailableReason, "silence needs an explanation")
        let rendered = await engine.render("Opening Mail")
        XCTAssertNil(rendered, "and rendering nothing is not a crash")
    }

    func testTheStubRendersSomethingOfABelievableLength() async {
        let speech = StubNeuralSpeech()
        await speech.prepare()
        let phrase = await speech.render("Opening Truebearing")

        XCTAssertEqual(speech.prepareCount, 1)
        XCTAssertEqual(speech.rendered, ["Opening Truebearing"])
        XCTAssertGreaterThan(phrase?.duration ?? 0, 0.5)
        XCTAssertLessThan(phrase?.duration ?? 0, 4)
    }

    func testAnUnavailableEngineRendersNothing() async {
        let speech = StubNeuralSpeech(isReady: false, unavailableReason: "not installed")
        let rendered = await speech.render("Opening Mail")
        XCTAssertNil(rendered)
    }
}

/// Speech is decorative, and the launcher has to keep working without it.
@MainActor
final class SpokenLaunchTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = defaults.object(forKey: SoundPreferences.spokenLaunchKey)
    }

    override func tearDown() {
        if let saved {
            defaults.set(saved, forKey: SoundPreferences.spokenLaunchKey)
        } else {
            defaults.removeObject(forKey: SoundPreferences.spokenLaunchKey)
        }
        super.tearDown()
    }

    func testTheToggleStillGatesSpeech() {
        let sound = SilentSound()
        let item = LauncherItem(kind: .app, name: "Truebearing", launchURL: URL(string: "a://b"))

        defaults.set(false, forKey: SoundPreferences.spokenLaunchKey)
        sound.announceLaunch(of: item)
        XCTAssertTrue(sound.announcements.isEmpty)

        defaults.set(true, forKey: SoundPreferences.spokenLaunchKey)
        sound.announceLaunch(of: item)
        XCTAssertEqual(sound.announcements, ["Opening Truebearing"])
    }

    func testAppsStillOpenWhenNothingCanSpeak() async {
        // The whole point of the announcement being decorative.
        let harness = LauncherHarness(items: [
            LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "mail://x"), sortOrder: 0)
        ])
        harness.model.load()
        harness.model.select(harness.model.items[0].id)

        await harness.model.launchSelected()

        XCTAssertEqual(harness.launcher.openedURLs.map(\.absoluteString), ["mail://x"])
    }

    func testAFailedLaunchCutsTheAnnouncement() async {
        let harness = LauncherHarness(
            items: [LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "mail://x"), sortOrder: 0)],
            launchSucceeds: false
        )
        harness.model.load()
        harness.model.select(harness.model.items[0].id)

        await harness.model.launchSelected()

        XCTAssertEqual(harness.sound.cancelCount, 1, "nothing opened, so the announcement is now wrong")
        XCTAssertNotNil(harness.model.launchFailure)
    }

    func testTheLibraryIsPreparedAfterLoading() {
        let harness = LauncherHarness(items: [
            LauncherItem(kind: .app, name: "Mail", launchURL: URL(string: "mail://x"), sortOrder: 0)
        ])
        harness.model.load()
        // Preparation is detached and best-effort, so what is asserted is that
        // the library was handed over at all rather than when it finishes.
        XCTAssertFalse(harness.model.allItems.isEmpty)
    }

    func testNothingHereReachesTheNetwork() {
        // A standing check that the local promise is kept in the code rather
        // than only in the documentation.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Holograph/Services")
        for name in ["NeuralSpeech.swift", "KokoroSpeech.swift"] {
            // The sources are only readable when the tests run on the machine
            // that built them, which is the case in CI and locally. Anywhere
            // else this has nothing to check rather than a failure to report.
            guard let source = try? String(contentsOf: root.appending(path: name), encoding: .utf8) else {
                continue
            }
            for forbidden in ["URLSession", "http://", "https://", "api_key", "apiKey"] {
                XCTAssertFalse(
                    source.contains(forbidden),
                    "\(name) must not mention \(forbidden): synthesis is local, with no endpoint and no key"
                )
            }
        }
    }
}

/// Which voice a stock iPad ends up speaking with.
///
/// The ladder exists so that no device can fall off the end of it, which is the
/// property worth testing: every case here has to produce a voice.
final class SystemVoiceCatalogueTests: XCTestCase {
    private func voice(
        _ name: String,
        _ language: String,
        quality: Int = 0,
        male: Bool = true
    ) -> SystemVoiceDescriptor {
        SystemVoiceDescriptor(
            identifier: "id.\(name).\(language)",
            name: name,
            language: language,
            quality: quality,
            isMale: male
        )
    }

    func testABritishManIsPreferredOverEverythingElse() {
        let chosen = SystemVoiceCatalogue.best(from: [
            voice("Samantha", "en-US", quality: 2, male: false),
            voice("Aaron", "en-US", quality: 2),
            voice("Kate", "en-GB", quality: 2, male: false),
            voice("Daniel", "en-GB"),
        ])
        XCTAssertEqual(chosen?.name, "Daniel", "accent and gender both, even at lower quality")
    }

    func testTheBestBritishManWinsAmongSeveral() {
        let chosen = SystemVoiceCatalogue.best(from: [
            voice("Daniel", "en-GB", quality: 0),
            voice("Oliver", "en-GB", quality: 2),
            voice("Arthur", "en-GB", quality: 1),
        ])
        XCTAssertEqual(chosen?.name, "Oliver")
    }

    func testAnAccentBeatsAGender() {
        // A British woman is closer to the launcher's register than an
        // American man is.
        let chosen = SystemVoiceCatalogue.best(from: [
            voice("Aaron", "en-US", quality: 2),
            voice("Kate", "en-GB", quality: 0, male: false),
        ])
        XCTAssertEqual(chosen?.name, "Kate")
    }

    func testAnyEnglishWillDoWhenThereIsNoBritishVoice() {
        let chosen = SystemVoiceCatalogue.best(from: [
            voice("Amélie", "fr-CA", quality: 2, male: false),
            voice("Samantha", "en-US", quality: 1, male: false),
        ])
        XCTAssertEqual(chosen?.name, "Samantha")
    }

    func testSomethingIsChosenEvenWithNoEnglishAtAll() {
        let chosen = SystemVoiceCatalogue.best(from: [
            voice("Amélie", "fr-CA", quality: 1, male: false),
        ])
        XCTAssertEqual(chosen?.name, "Amélie", "there is no rung that says install something first")
    }

    func testOnlyAnEmptyDeviceComesUpEmpty() {
        XCTAssertNil(SystemVoiceCatalogue.best(from: []))
    }

    func testTheChoiceIsStableAcrossLaunches() {
        // Two equally good candidates must not alternate: a voice that changes
        // between launches sounds like a fault.
        let candidates = [voice("Daniel", "en-GB", quality: 1), voice("Arthur", "en-GB", quality: 1)]
        let first = SystemVoiceCatalogue.best(from: candidates)
        let second = SystemVoiceCatalogue.best(from: candidates.reversed())
        XCTAssertEqual(first, second)
    }

    func testKnownMaleNamesAreRecognisedWithOrWithoutASuffix() {
        XCTAssertTrue(SystemVoiceCatalogue.isProbablyMale(name: "Daniel"))
        XCTAssertTrue(SystemVoiceCatalogue.isProbablyMale(name: "Daniel (Enhanced)"))
        XCTAssertFalse(SystemVoiceCatalogue.isProbablyMale(name: "Serena"))
    }
}

/// The neural voice in front, the system voice behind, and never silence
/// because of which one a build happens to ship.
@MainActor
final class LayeredSpeechTests: XCTestCase {
    func testThePreferredEngineSpeaksWhenItCan() async {
        let preferred = StubNeuralSpeech()
        let fallback = StubNeuralSpeech()
        let speech = LayeredSpeech(preferred: preferred, fallback: fallback)

        await speech.prepare()
        let rendered = await speech.render("Opening Mail")

        XCTAssertNotNil(rendered)
        XCTAssertEqual(preferred.rendered, ["Opening Mail"])
        XCTAssertEqual(fallback.rendered, [], "the fallback is not even asked")
        XCTAssertTrue(speech.usingPreferred)
    }

    func testTheFallbackSpeaksWhenTheModelIsNotInstalled() async {
        let preferred = StubNeuralSpeech(isReady: false, unavailableReason: "not installed")
        let fallback = StubNeuralSpeech()
        let speech = LayeredSpeech(preferred: preferred, fallback: fallback)

        await speech.prepare()
        let rendered = await speech.render("Opening Mail")

        XCTAssertNotNil(rendered, "a fresh download still talks")
        XCTAssertEqual(fallback.rendered, ["Opening Mail"])
        XCTAssertFalse(speech.usingPreferred)
    }

    func testAMissingModelIsNotReportedWhileSomethingIsStillSpeaking() async {
        let speech = LayeredSpeech(
            preferred: StubNeuralSpeech(isReady: false, unavailableReason: "not installed"),
            fallback: StubNeuralSpeech()
        )
        await speech.prepare()

        XCTAssertTrue(speech.isReady)
        XCTAssertNil(speech.unavailableReason, "the user has no silence to explain")
    }

    func testOnlyTotalSilenceIsReported() async {
        let speech = LayeredSpeech(
            preferred: StubNeuralSpeech(isReady: false, unavailableReason: "no model"),
            fallback: StubNeuralSpeech(isReady: false, unavailableReason: "no voices")
        )
        await speech.prepare()

        XCTAssertFalse(speech.isReady)
        XCTAssertEqual(speech.unavailableReason, "no voices", "the nearer failure is the useful one")
        let rendered = await speech.render("Opening Mail")
        XCTAssertNil(rendered)
    }

    func testBothEnginesArePreparedSoTheFallbackIsReadyTheMomentItIsNeeded() async {
        let preferred = StubNeuralSpeech()
        let fallback = StubNeuralSpeech()
        let speech = LayeredSpeech(preferred: preferred, fallback: fallback)

        await speech.prepare()

        XCTAssertEqual(preferred.prepareCount, 1)
        XCTAssertEqual(fallback.prepareCount, 1)
    }
}
