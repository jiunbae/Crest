import AppKit

extension BrowserShortcutStore {
    /// Resolve live assignments before dispatch, including unassigned defaults.
    /// Disabled commands leave the event available to the focused native control.
    func command(for event: NSEvent, isEnabled: (ShortcutCommand) -> Bool) -> ShortcutCommand? {
        match(for: event, isEnabled: isEnabled)?.command
    }

    func command(for shortcut: BrowserShortcut, isEnabled: (ShortcutCommand) -> Bool) -> ShortcutCommand? {
        resolvedMatch(for: shortcut, isEnabled: isEnabled)?.command
    }

    func match(for event: NSEvent, isEnabled: (ShortcutCommand) -> Bool) -> BrowserShortcutMatch? {
        guard event.type == .keyDown, let shortcut = BrowserShortcut(event: event) else { return nil }
        return resolvedMatch(for: shortcut, isEnabled: isEnabled)
    }

    private func resolvedMatch(for shortcut: BrowserShortcut, isEnabled: (ShortcutCommand) -> Bool)
        -> BrowserShortcutMatch?
    {
        guard shortcut.isValid else { return nil }
        if !commands(assignedTo: shortcut).isEmpty { return match(for: shortcut, isEnabled: isEnabled) }
        // Match AppKit's implicit Shift for the default plus key equivalent.
        if [.character("="), .character("+")].contains(shortcut.key),
            shortcut.modifiers == .command || shortcut.modifiers == [.command, .shift],
            self.shortcut(for: .zoomIn) == ShortcutCommand.zoomIn.defaultShortcut,
            isEnabled(.zoomIn)
        {
            return self.shortcut(for: .zoomIn).flatMap { match(for: $0, isEnabled: isEnabled) }
        }
        return nil
    }
}
