import Foundation
import Observation

@Observable
@MainActor
final class BrowserShortcutSettingsModel {
    private let shortcuts: BrowserShortcutStore

    var searchText = ""
    var validationIssue: BrowserShortcutValidationIssue?
    var pendingConflict: BrowserShortcutPendingConflict?

    @ObservationIgnored private var searchProvider: any BrowserShortcutSearchProviding

    init(
        shortcuts: BrowserShortcutStore,
        searchProvider: any BrowserShortcutSearchProviding
    ) {
        self.shortcuts = shortcuts
        self.searchProvider = searchProvider
    }

    var isPresentingConflict: Bool {
        get { pendingConflict != nil }
        set {
            if !newValue {
                pendingConflict = nil
            }
        }
    }

    var hasCrestCustomizations: Bool {
        shortcuts.hasCustomizations
    }

    func shortcut(
        for command: ShortcutCommand
    ) -> BrowserShortcut? {
        shortcuts.shortcut(for: command)
    }

    func alternateShortcut(for command: ShortcutCommand) -> BrowserShortcut? {
        shortcuts.alternateShortcut(for: command)
    }

    func isCustomized(_ command: ShortcutCommand) -> Bool {
        shortcuts.isCustomized(command)
    }

    func preference(for command: ShortcutCommand) -> ShortcutPreference {
        shortcuts.preference(for: command)
    }

    func choosesPreference(_ command: ShortcutCommand) -> Bool {
        shortcuts.choosesPreference(command)
    }

    func choose(_ preference: ShortcutPreference, for command: ShortcutCommand) {
        shortcuts.choose(preference, for: command)
    }

    var commandGroups: [BrowserShortcutCommandGroup] {
        let matches = shortcuts.offeredCommands.filter { command in
            searchProvider.matches(
                command,
                currentShortcut: shortcuts.shortcut(for: command),
                query: searchText
            )
                || (shortcuts.alternateShortcut(for: command).map { alternate in
                    searchProvider.matches(command, currentShortcut: alternate, query: searchText)
                } ?? false)
        }
        return ShortcutSection.all.compactMap { section in
            let commands = matches.filter { $0.section == section }
            guard !commands.isEmpty else { return nil }
            return BrowserShortcutCommandGroup(
                section: section,
                commands: commands
            )
        }
    }

    func updateSearchProvider(
        _ searchProvider: any BrowserShortcutSearchProviding
    ) {
        self.searchProvider = searchProvider
    }

    func record(
        _ shortcut: BrowserShortcut?,
        for command: ShortcutCommand, isAlternate: Bool = false
    ) {
        guard let shortcut else {
            if isAlternate {
                shortcuts.clearAlternateShortcut(for: command)
            } else {
                shortcuts.clearShortcut(for: command)
            }
            validationIssue = nil
            return
        }

        let result =
            isAlternate
            ? shortcuts.assignAlternate(shortcut, to: command) : shortcuts.assign(shortcut, to: command)
        result.apply(to: self, recording: shortcut, for: command, isAlternate: isAlternate)
    }

    func replacePendingConflict() {
        guard let pendingConflict else { return }
        if pendingConflict.isAlternate {
            _ = shortcuts.reassignAlternate(pendingConflict.shortcut, to: pendingConflict.command)
        } else {
            _ = shortcuts.reassign(pendingConflict.shortcut, to: pendingConflict.command)
        }
        self.pendingConflict = nil
        validationIssue = nil
    }

    func cancelPendingConflict() {
        pendingConflict = nil
    }

    func reset(_ command: ShortcutCommand) {
        shortcuts.reset(command)
        validationIssue = nil
    }

    func resetAllCrestShortcuts() {
        shortcuts.resetAll()
        validationIssue = nil
    }

    func reportInvalidShortcut() {
        validationIssue = .invalidShortcut
    }

}
