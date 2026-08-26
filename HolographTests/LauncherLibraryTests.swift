import XCTest
@testable import Holograph

private func app(_ name: String, in folder: UUID? = nil, order: Int = 0) -> LauncherItem {
    LauncherItem(
        kind: .app,
        name: name,
        launchURL: URL(string: "idlery-demo-\(name.lowercased())://launch"),
        parentFolderID: folder,
        sortOrder: order
    )
}

private func website(_ name: String, in folder: UUID? = nil, order: Int = 0) -> LauncherItem {
    LauncherItem(
        kind: .website,
        name: name,
        launchURL: URL(string: "https://\(name.lowercased()).example.com"),
        parentFolderID: folder,
        sortOrder: order
    )
}

private func folder(_ name: String, order: Int = 0) -> LauncherItem {
    LauncherItem(kind: .folder, name: name, sortOrder: order)
}

/// The wall shows the root; a folder shows its own contents. Two scopes, and
/// nothing in one may leak into the other.
final class LauncherScopingTests: XCTestCase {
    func testTheWallHoldsEverything() {
        // A folder groups tiles; it does not take them off the wall. Being in
        // one is a second way to reach something, not a place it disappears to.
        let work = folder("Work")
        let items = [work, app("Mail"), app("Notes", in: work.id), website("Idlery", in: work.id)]

        XCTAssertEqual(Set(items.rootItems.map(\.name)), ["Work", "Mail", "Notes", "Idlery"])
    }

    func testAFolderHoldsOnlyItsOwn() {
        let work = folder("Work")
        let home = folder("Home")
        let items = [work, home, app("Notes", in: work.id), app("Recipes", in: home.id)]

        XCTAssertEqual(items.children(of: work.id).map(\.name), ["Notes"])
        XCTAssertEqual(items.children(of: home.id).map(\.name), ["Recipes"])
    }

    func testSomethingInAFolderIsInBothPlaces() {
        let work = folder("Work")
        let items = [work, app("Notes", in: work.id)]

        XCTAssertTrue(items.rootItems.contains { $0.name == "Notes" }, "still on the wall")
        XCTAssertEqual(items.children(of: work.id).map(\.name), ["Notes"], "and in the folder")
    }

    func testOnlyThingsNotAlreadyInAFolderCanBeAddedToIt() {
        let work = folder("Work")
        let home = folder("Home")
        let items = [work, home, app("Notes", in: work.id), app("Mail")]

        let addable = items.addableToFolder(work.id).map(\.name)
        XCTAssertEqual(addable, ["Mail"], "a folder cannot be added to a folder, nor a member re-added")
    }

    func testTheWallAndAFolderAreOrderedIndependently() {
        // The same tile can be last on the wall and first in its folder.
        let work = folder("Work", order: 0)
        var first = app("Alpha", in: work.id, order: 1)
        first.folderSortOrder = 1
        var second = app("Beta", in: work.id, order: 2)
        second.folderSortOrder = 0

        let items = [work, first, second]
        XCTAssertEqual(items.rootItems.map(\.name), ["Work", "Alpha", "Beta"])
        XCTAssertEqual(items.children(of: work.id).map(\.name), ["Beta", "Alpha"])
    }
}

/// What a tile does when it is activated. Pure, and worth testing on its own:
/// it is the single decision that separates leaving Holograph from staying in
/// it.
final class LauncherActivationTests: XCTestCase {
    func testAnAppLeavesHolograph() {
        let url = URL(string: "idlery-demo-mail://launch")!
        XCTAssertEqual(app("Mail").activation, .openExternally(url))
    }

    func testAWebsiteStaysInHolograph() {
        let url = URL(string: "https://idlery.example.com")!
        XCTAssertEqual(website("Idlery").activation, .openInHolograph(url))
    }

    func testAFolderGoesNowhere() {
        let work = folder("Work")
        XCTAssertEqual(work.activation, .openFolder(work.id))
    }

    func testARecordWithNoUsableLinkDoesNothing() {
        // A stored launch link that stopped parsing should be inert, not a
        // crash and not a silent no-op that looks like a broken tap.
        let broken = LauncherItem(kind: .app, name: "Gone", launchURL: nil)
        XCTAssertEqual(broken.activation, .unavailable)
    }
}

/// The persisted record is the thing users already have on their iPads, so its
/// mapping is where a migration mistake would actually show up.
final class StoredRecordMappingTests: XCTestCase {
    @MainActor
    func testARecordFromBeforeKindsExistedIsAnApp() {
        // Exactly what a store written by the previous version holds: no kind,
        // no parent.
        let record = StoredLauncherApp(
            name: "Truebearing",
            launchURLString: "idlery-demo-truebearing://launch",
            sortOrder: 3
        )
        record.kindRaw = nil
        record.parentFolderID = nil

        let item = record.item
        XCTAssertEqual(item?.kind, .app)
        XCTAssertNil(item?.parentFolderID)
        XCTAssertEqual(item?.name, "Truebearing")
        XCTAssertEqual(item?.launchURL?.absoluteString, "idlery-demo-truebearing://launch")
    }

    @MainActor
    func testEverythingElseAboutALegacyRecordSurvives() {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_000)
        let modified = Date(timeIntervalSince1970: 2_000)
        let record = StoredLauncherApp(
            identifier: id,
            name: "Aquify",
            launchURLString: "idlery-demo-aquify://launch",
            fallbackURLString: "https://example.com/aquify",
            sortOrder: 7,
            iconData: Data([1, 2, 3]),
            isDemo: true,
            createdAt: created,
            modifiedAt: modified
        )
        record.kindRaw = nil

        let item = record.item
        XCTAssertEqual(item?.id, id)
        XCTAssertEqual(item?.fallbackURL?.absoluteString, "https://example.com/aquify")
        XCTAssertEqual(item?.sortOrder, 7)
        XCTAssertEqual(item?.iconData, Data([1, 2, 3]))
        XCTAssertEqual(item?.isDemo, true)
        XCTAssertEqual(item?.createdAt, created)
        XCTAssertEqual(item?.modifiedAt, modified)
    }

    @MainActor
    func testAKindNobodyRecognisesReadsAsAnApp() {
        // A store written by a *later* version has to degrade to something the
        // launcher can still open rather than to nothing.
        let record = StoredLauncherApp(name: "Future", launchURLString: "x://y", sortOrder: 0)
        record.kindRaw = "hologram"
        XCTAssertEqual(record.item?.kind, .app)
    }

    @MainActor
    func testAFolderNeedsNoLink() {
        let record = StoredLauncherApp(kind: .folder, name: "Work", launchURLString: "", sortOrder: 0)
        let item = record.item
        XCTAssertEqual(item?.kind, .folder)
        XCTAssertNil(item?.launchURL)
    }

    @MainActor
    func testAnAppWithAnUnreadableLinkIsDropped() {
        // Unchanged behaviour: better a missing tile than one that cannot work.
        let record = StoredLauncherApp(name: "Broken", launchURLString: "", sortOrder: 0)
        XCTAssertNil(record.item)
    }

    @MainActor
    func testAFolderIsNeverInsideAnything() {
        let record = StoredLauncherApp(kind: .folder, name: "Work", launchURLString: "", sortOrder: 0)
        record.apply(
            LauncherItemDraft(kind: .folder, name: "Work", parentFolderID: UUID()),
            modifiedAt: .now
        )
        XCTAssertNil(record.parentFolderID, "folders do not nest, whatever a caller asks for")
    }
}

/// Both repositories are held to the same contract, because the in-memory one
/// stands in for the real store everywhere tests and previews run.
@MainActor
final class LauncherFolderRepositoryTests: XCTestCase {
    private func repositories() -> [(String, LauncherRepository)] {
        [("in-memory", InMemoryLauncherRepository())]
    }

    func testAddingPutsThingsAtTheEndOfBothScopes() throws {
        for (label, repository) in repositories() {
            let work = try repository.add(LauncherItemDraft(kind: .folder, name: "Work"))
            _ = try repository.add(draftApp("Mail"))
            _ = try repository.add(draftApp("Notes", in: work.id))
            _ = try repository.add(draftApp("Slides", in: work.id))

            let all = try repository.fetchAll()
            XCTAssertEqual(all.rootItems.map(\.name), ["Work", "Mail", "Notes", "Slides"], label)
            XCTAssertEqual(all.children(of: work.id).map(\.name), ["Notes", "Slides"], label)
        }
    }

    func testReorderingInsideAFolderLeavesTheWallAlone() throws {
        for (label, repository) in repositories() {
            let work = try repository.add(LauncherItemDraft(kind: .folder, name: "Work"))
            _ = try repository.add(draftApp("Mail"))
            _ = try repository.add(draftApp("Notes", in: work.id))
            _ = try repository.add(draftApp("Slides", in: work.id))
            let wallBefore = try repository.fetchAll().rootItems.map(\.name)

            try repository.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, in: work.id)

            let all = try repository.fetchAll()
            XCTAssertEqual(all.children(of: work.id).map(\.name), ["Slides", "Notes"], label)
            XCTAssertEqual(all.rootItems.map(\.name), wallBefore, "\(label): the wall is untouched")
        }
    }

    func testReorderingTheWallLeavesFoldersAlone() throws {
        for (label, repository) in repositories() {
            let work = try repository.add(LauncherItemDraft(kind: .folder, name: "Work"))
            _ = try repository.add(draftApp("Notes", in: work.id))
            _ = try repository.add(draftApp("Slides", in: work.id))

            try repository.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, in: nil)

            let all = try repository.fetchAll()
            XCTAssertEqual(all.children(of: work.id).map(\.name), ["Notes", "Slides"], label)
        }
    }

    func testAddingToAFolderKeepsItOnTheWall() throws {
        for (label, repository) in repositories() {
            let work = try repository.add(LauncherItemDraft(kind: .folder, name: "Work"))
            let mail = try repository.add(draftApp("Mail"))

            try repository.setParent(of: mail.id, to: work.id)
            XCTAssertEqual(try repository.fetchAll().children(of: work.id).map(\.name), ["Mail"], label)
            XCTAssertTrue(
                try repository.fetchAll().rootItems.contains { $0.name == "Mail" },
                "\(label): adding to a folder is not taking off the wall"
            )

            try repository.setParent(of: mail.id, to: nil)
            XCTAssertTrue(try repository.fetchAll().rootItems.contains { $0.name == "Mail" }, label)
            XCTAssertTrue(try repository.fetchAll().children(of: work.id).isEmpty, label)
        }
    }

    func testDeletingAFolderKeepsWhatWasInside() throws {
        for (label, repository) in repositories() {
            let work = try repository.add(LauncherItemDraft(kind: .folder, name: "Work"))
            _ = try repository.add(draftApp("Notes", in: work.id))
            _ = try repository.add(draftWebsite("Idlery", in: work.id))

            try repository.delete(id: work.id)

            let all = try repository.fetchAll()
            XCTAssertEqual(all.count, 2, "\(label): a folder is a grouping, not a shredder")
            XCTAssertEqual(Set(all.rootItems.map(\.name)), ["Notes", "Idlery"], label)
            XCTAssertTrue(all.allSatisfy { $0.parentFolderID == nil }, label)
        }
    }

    func testAFolderCannotBePutInsideAFolder() throws {
        for (label, repository) in repositories() {
            let outer = try repository.add(LauncherItemDraft(kind: .folder, name: "Outer"))
            let inner = try repository.add(LauncherItemDraft(kind: .folder, name: "Inner"))

            try repository.setParent(of: inner.id, to: outer.id)

            let all = try repository.fetchAll()
            XCTAssertTrue(all.children(of: outer.id).isEmpty, "\(label): folders do not nest")
        }
    }

    func testMovingSomewhereThatIsNotAFolderIsRefused() throws {
        for (label, repository) in repositories() {
            let mail = try repository.add(draftApp("Mail"))
            let notes = try repository.add(draftApp("Notes"))
            XCTAssertThrowsError(try repository.setParent(of: mail.id, to: notes.id), label)
        }
    }

    func testEditingSomethingIntoAFolderMovesIt() throws {
        for (label, repository) in repositories() {
            let work = try repository.add(LauncherItemDraft(kind: .folder, name: "Work"))
            let mail = try repository.add(draftApp("Mail"))

            var draft = mail.draft
            draft.parentFolderID = work.id
            try repository.update(id: mail.id, with: draft)

            XCTAssertEqual(try repository.fetchAll().children(of: work.id).map(\.name), ["Mail"], label)
        }
    }

    private func draftApp(_ name: String, in folder: UUID? = nil) -> LauncherItemDraft {
        LauncherItemDraft(
            kind: .app,
            name: name,
            launchURL: URL(string: "idlery-demo-\(name.lowercased())://launch"),
            parentFolderID: folder
        )
    }

    private func draftWebsite(_ name: String, in folder: UUID? = nil) -> LauncherItemDraft {
        LauncherItemDraft(
            kind: .website,
            name: name,
            launchURL: URL(string: "https://\(name.lowercased()).example.com"),
            parentFolderID: folder
        )
    }
}

/// A website tile promises the address opens in a web view, so what is allowed
/// behind that promise is narrower than what an app may use.
final class WebsiteURLValidatorTests: XCTestCase {
    func testHTTPSIsAccepted() {
        guard case .success(let url) = WebsiteURLValidator.validate("https://idlery.com/tools") else {
            return XCTFail("https should be accepted")
        }
        XCTAssertEqual(url.absoluteString, "https://idlery.com/tools")
    }

    func testPlainHTTPIsAccepted() {
        // Plenty of things on a local network are still http, and refusing them
        // would be a policy the launcher has no business having.
        guard case .success = WebsiteURLValidator.validate("http://example.com") else {
            return XCTFail("http should be accepted")
        }
    }

    func testABareDomainBecomesHTTPS() {
        guard case .success(let url) = WebsiteURLValidator.validate("idlery.com") else {
            return XCTFail("a bare domain should be accepted")
        }
        XCTAssertEqual(url.scheme, "https")
    }

    func testAnAppSchemeIsNotAWebsite() {
        guard case .failure(let error) = WebsiteURLValidator.validate("idler-offrent://launch") else {
            return XCTFail("a custom scheme is not a website")
        }
        XCTAssertEqual(error, .notWeb("idler-offrent"))
    }

    func testWaysOfRunningSomethingAreRefused() {
        // The dangerous ones, and the reason this validator exists at all: each
        // of these is a way to execute something rather than to visit a page.
        for raw in ["javascript:alert(1)", "data:text/html,<script>x</script>", "file:///etc/passwd"] {
            guard case .failure = WebsiteURLValidator.validate(raw) else {
                return XCTFail("\(raw) should not be usable as a website")
            }
        }
    }

    func testSomethingWithNoDomainIsRefused() {
        guard case .failure(let error) = WebsiteURLValidator.validate("https://localhost") else {
            return XCTFail("a host with no dot is refused")
        }
        XCTAssertEqual(error, .missingHost)
    }

    func testAnEmptyAddressIsRefused() {
        guard case .failure(.empty) = WebsiteURLValidator.validate("   ") else {
            return XCTFail("empty is empty")
        }
    }

    func testAppSchemesAreStillValidForApps() {
        // The other validator is unchanged; websites being stricter must not
        // have narrowed what an app may use.
        guard case .success = LaunchURLValidator.validate("idler-offrent://launch") else {
            return XCTFail("app schemes must keep working")
        }
    }
}
