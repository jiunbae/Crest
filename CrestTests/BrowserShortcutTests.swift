import AppKit
import XCTest

@testable import Crest

final class BrowserShortcutTests: XCTestCase {
    @MainActor
    func testNativeDispatchUsesCurrentOverridesAndLeavesDisabledCommandsToTheResponder() throws {
        let store = BrowserShortcutStore()
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
                characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        XCTAssertEqual(store.command(for: event, isEnabled: { _ in true }), .toggleDeveloperToolbar)
        XCTAssertNil(store.command(for: event, isEnabled: { _ in false }))
        store.clearShortcut(for: .toggleDeveloperToolbar)
        XCTAssertNil(store.command(for: event, isEnabled: { _ in true }))
        XCTAssertTrue(
            store.assign(BrowserShortcut(key: .character("i"), modifiers: [.command, .shift]), to: .newTab)
                is BrowserShortcutAssigned)
        XCTAssertEqual(store.command(for: event, isEnabled: { _ in true }), .newTab)
    }

    @MainActor
    func testAlternateDispatchKeepsPrimaryAndUsesThePressedChordPolicy() throws {
        let store = BrowserShortcutStore()
        let primary = BrowserShortcut(key: .character("["), modifiers: [.command, .shift])
        let alternate = special(.upArrow, [.command, .option])
        XCTAssertTrue(store.assign(primary, to: .previousTab) is BrowserShortcutAssigned)
        XCTAssertTrue(store.assignAlternate(alternate, to: .previousTab) is BrowserShortcutAssigned)
        XCTAssertEqual(store.command(for: primary, isEnabled: { _ in true }), .previousTab)
        XCTAssertEqual(store.command(for: alternate, isEnabled: { _ in true }), .previousTab)
        XCTAssertNil(store.command(for: alternate, isEnabled: { _ in false }))
        store.clearAlternateShortcut(for: .previousTab)
        XCTAssertNil(store.command(for: alternate, isEnabled: { _ in true }))
        XCTAssertEqual(store.command(for: primary, isEnabled: { _ in true }), .previousTab)

        let undo = BrowserShortcut(key: .character("z"), modifiers: .command)
        let function = special(.f12, [])
        XCTAssertTrue(store.assign(undo, to: .showHistory) is BrowserShortcutAssigned)
        XCTAssertTrue(store.assignAlternate(function, to: .showHistory) is BrowserShortcutAssigned)
        store.choose(.preferCrest, for: .showHistory)
        let editing = try XCTUnwrap(store.match(for: undo, isEnabled: { _ in true }))
        let other = try XCTUnwrap(store.match(for: function, isEnabled: { _ in true }))
        XCTAssertTrue(editing.yieldsToTextEditing)
        XCTAssertEqual(editing.preference, .preferWebsite)
        XCTAssertFalse(other.yieldsToTextEditing)
        XCTAssertEqual(other.preference, .preferCrest)
    }

    @MainActor
    func testConfirmingAnAlternateConflictNeverReplacesThePrimary() {
        let store = BrowserShortcutStore()
        let model = BrowserShortcutSettingsModel(shortcuts: store, searchProvider: BrowserShortcutPresentationCatalog())
        let alternate = special(.f12, [])
        _ = store.assignAlternate(alternate, to: .previousTab)
        let primary = store.shortcut(for: .nextTab)
        model.record(alternate, for: .nextTab, isAlternate: true)
        XCTAssertTrue(model.pendingConflict?.isAlternate == true)
        model.replacePendingConflict()
        XCTAssertEqual(store.shortcut(for: .nextTab), primary)
        XCTAssertEqual(store.alternateShortcut(for: .nextTab), alternate)
        XCTAssertNil(store.alternateShortcut(for: .previousTab))
    }

    private func special(
        _ key: ShortcutSpecialKey,
        _ modifiers: ShortcutModifiers
    ) -> BrowserShortcut {
        BrowserShortcut(key: .special(key), modifiers: modifiers)
    }
}
