/// The core cannot bind the shortcut to anything.
struct BrowserShortcutInvalid: BrowserShortcutAssignmentResult {
    // MARK: - Actions - Settings

    @MainActor
    func apply(
        to model: BrowserShortcutSettingsModel, recording shortcut: BrowserShortcut, for command: ShortcutCommand,
        isAlternate: Bool
    ) {
        model.validationIssue = .invalidShortcut
    }
}
