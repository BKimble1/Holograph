import SwiftData
import XCTest
@testable import IdleryLauncher

/// The same contract is run against both repository implementations so previews
/// and tests can trust the in-memory one to behave like the real store.
@MainActor
final class LauncherRepositoryTests: XCTestCase {
    private func makeRepositories() throws -> [(String, LauncherRepository)] {
        let container = try makeContainer()
        return [
            ("in-memory", InMemoryLauncherRepository()),
            ("SwiftData", SwiftDataLauncherRepository(context: container.mainContext))
        ]
    }

    private func makeContainer() throws -> ModelContainer {
        guard case .ready(let container) = ModelContainerFactory.make(inMemory: true) else {
            throw XCTSkip("An in-memory model container should always be available")
        }
        return container
    }

    func testAddAssignsIncreasingSortOrder() throws {
        for (label, repository) in try makeRepositories() {
            try repository.add(TestFixtures.draft(name: "One"))
            try repository.add(TestFixtures.draft(name: "Two"))
            try repository.add(TestFixtures.draft(name: "Three"))

            let items = try repository.fetchAll()
            XCTAssertEqual(items.map(\.name), ["One", "Two", "Three"], label)
            XCTAssertEqual(items.map(\.sortOrder), [0, 1, 2], label)
        }
    }

    func testUpdateReplacesEveryEditableField() throws {
        for (label, repository) in try makeRepositories() {
            let added = try repository.add(TestFixtures.draft(name: "Before"))
            let iconData = TestFixtures.pngData(width: 40, height: 40)

            try repository.update(
                id: added.id,
                with: LauncherItemDraft(
                    name: "After",
                    launchURL: try XCTUnwrap(URL(string: "idlery-after://go")),
                    fallbackURL: URL(string: "https://example.com"),
                    iconData: iconData,
                    isDemo: false
                )
            )

            let item = try XCTUnwrap(repository.fetchAll().first, label)
            XCTAssertEqual(item.name, "After", label)
            XCTAssertEqual(item.launchURL.absoluteString, "idlery-after://go", label)
            XCTAssertEqual(item.fallbackURL?.absoluteString, "https://example.com", label)
            XCTAssertEqual(item.iconData, iconData, label)
        }
    }

    func testUpdatingAMissingIdentifierThrows() throws {
        for (label, repository) in try makeRepositories() {
            XCTAssertThrowsError(
                try repository.update(id: UUID(), with: TestFixtures.draft(name: "Ghost")),
                label
            ) { error in
                XCTAssertEqual(error as? LauncherRepositoryError, .notFound, label)
            }
        }
    }

    func testDeleteRemovesAndRenumbers() throws {
        for (label, repository) in try makeRepositories() {
            try repository.add(TestFixtures.draft(name: "A"))
            let b = try repository.add(TestFixtures.draft(name: "B"))
            try repository.add(TestFixtures.draft(name: "C"))

            try repository.delete(id: b.id)

            let items = try repository.fetchAll()
            XCTAssertEqual(items.map(\.name), ["A", "C"], label)
            XCTAssertEqual(items.map(\.sortOrder), [0, 1], label)
        }
    }

    func testMoveReordersAndPersistsNewPositions() throws {
        for (label, repository) in try makeRepositories() {
            for name in ["A", "B", "C", "D"] {
                try repository.add(TestFixtures.draft(name: name))
            }

            // Move "D" to the front.
            try repository.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)

            let items = try repository.fetchAll()
            XCTAssertEqual(items.map(\.name), ["D", "A", "B", "C"], label)
            XCTAssertEqual(items.map(\.sortOrder), [0, 1, 2, 3], label)
        }
    }

    func testMoveDownUsesSwiftUIOffsetSemantics() throws {
        for (label, repository) in try makeRepositories() {
            for name in ["A", "B", "C"] {
                try repository.add(TestFixtures.draft(name: name))
            }

            // SwiftUI's "move down one" is toOffset: index + 2.
            try repository.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)

            XCTAssertEqual(try repository.fetchAll().map(\.name), ["B", "A", "C"], label)
        }
    }

    func testRemoveAllEmptiesTheStore() throws {
        for (label, repository) in try makeRepositories() {
            try repository.add(TestFixtures.draft(name: "A"))
            try repository.add(TestFixtures.draft(name: "B"))

            try repository.removeAll()

            XCTAssertTrue(try repository.fetchAll().isEmpty, label)
        }
    }

    func testReplaceAllSwapsTheWholeLibraryInOrder() throws {
        for (label, repository) in try makeRepositories() {
            try repository.add(TestFixtures.draft(name: "Old"))

            try repository.replaceAll(with: [
                TestFixtures.draft(name: "New A"),
                TestFixtures.draft(name: "New B")
            ])

            let items = try repository.fetchAll()
            XCTAssertEqual(items.map(\.name), ["New A", "New B"], label)
            XCTAssertEqual(items.map(\.sortOrder), [0, 1], label)
        }
    }

    func testIconDataSurvivesAReadBack() throws {
        for (label, repository) in try makeRepositories() {
            let iconData = TestFixtures.pngData(width: 64, height: 64)
            try repository.add(TestFixtures.draft(name: "Icon", iconData: iconData))

            let item = try XCTUnwrap(repository.fetchAll().first, label)
            XCTAssertEqual(item.iconData, iconData, label)
        }
    }

    func testUnreadableLaunchURLIsSkippedRatherThanCrashing() throws {
        let context = try makeContainer().mainContext
        context.insert(
            StoredLauncherApp(name: "Broken", launchURLString: "", sortOrder: 0)
        )
        context.insert(
            StoredLauncherApp(name: "Fine", launchURLString: "idlery-fine://launch", sortOrder: 1)
        )
        try context.save()

        let repository = SwiftDataLauncherRepository(context: context)
        XCTAssertEqual(try repository.fetchAll().map(\.name), ["Fine"])
    }
}
