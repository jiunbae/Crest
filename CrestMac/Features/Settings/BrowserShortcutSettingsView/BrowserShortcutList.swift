import SwiftUI

struct BrowserShortcutList: View {
    let model: BrowserShortcutSettingsModel
    @Environment(\.browserSettingsTabState) private var tabState
    @State private var standaloneScroll = BrowserNativeScrollState()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.commandGroups) { group in
                    Section {
                        ForEach(group.commands) { command in
                            BrowserShortcutRow(
                                command: command,
                                shortcut: model.shortcut(for: command),
                                alternate: model.alternateShortcut(for: command),
                                isCustomized: model.isCustomized(command),
                                preference: model.choosesPreference(command) ? model.preference(for: command) : nil,
                                record: { model.record($0, for: command) },
                                recordAlternate: { model.record($0, for: command, isAlternate: true) },
                                choose: { model.choose($0, for: command) },
                                reset: { model.reset(command) },
                                reportInvalidShortcut:
                                    model.reportInvalidShortcut
                            )
                        }
                    } header: {
                        Text(group.section.title)
                    }
                }

            }
            .browserNativeListScrollState(tabState?.scroll(for: .shortcuts) ?? standaloneScroll)
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.commandGroups.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .accessibilityIdentifier(
                BrowserShortcutSettingsAccessibilityID.list
            )
        }
    }

}

private struct BrowserShortcutRow: View {
    @Environment(\.locale) private var locale

    let command: ShortcutCommand
    let shortcut: BrowserShortcut?
    let alternate: BrowserShortcut?
    let isCustomized: Bool
    /// Who answers the keys while a focused page uses them too, or nil for a
    /// command that keeps its own.
    let preference: ShortcutPreference?
    let record: (BrowserShortcut?) -> Void
    let recordAlternate: (BrowserShortcut?) -> Void
    let choose: (ShortcutPreference) -> Void
    let reset: () -> Void
    let reportInvalidShortcut: () -> Void

    var body: some View {
        HStack(spacing: BrowserShortcutSettingsMetrics.rowSpacing) {
            Text(command.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isCustomized {
                Text(BrowserShortcutSettingsPresentation.custom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .trailing) {
                recorder(shortcut, title: command.title(locale: locale), identifier: command.name, record: record)
                HStack {
                    Text("Alternate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    recorder(
                        alternate, title: String(localized: "Alternate shortcut for \(command.title(locale: locale))"),
                        identifier: command.name + "-alternate", record: recordAlternate)
                }
            }

            Menu {
                Group {
                    Button(
                        BrowserShortcutSettingsPresentation.clearShortcut,
                        systemImage: "delete.left"
                    ) {
                        record(nil)
                    }
                    .disabled(shortcut == nil)
                    Button("Clear Alternate Shortcut", systemImage: "delete.left") { recordAlternate(nil) }
                        .disabled(alternate == nil)
                    Button(
                        BrowserShortcutSettingsPresentation.resetToDefault,
                        systemImage: "arrow.counterclockwise",
                        action: reset
                    )
                    .disabled(!isCustomized)
                    if let preference { preferenceSection(preference) }
                }
                .crestMenuActionLabelStyle()
            } label: {
                Image(systemName: "ellipsis")
                    .frame(
                        width: BrowserShortcutSettingsMetrics.actionSize,
                        height: BrowserShortcutSettingsMetrics.actionSize
                    )
                    .contentShape(.rect)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .crestMenuActionLabelStyle()
            .fixedSize()
            .help(Text(BrowserShortcutSettingsPresentation.shortcutActions))
            .accessibilityLabel(
                Text(
                    BrowserShortcutSettingsPresentation
                        .actionsAccessibilityLabel(
                            title: command.title(locale: locale)
                        )
                )
            )
        }
        .padding(
            .vertical,
            BrowserShortcutSettingsMetrics.rowVerticalPadding
        )
        .accessibilityElement(children: .contain)
    }

    private func recorder(
        _ shortcut: BrowserShortcut?, title: String, identifier: String,
        record: @escaping (BrowserShortcut?) -> Void
    ) -> some View {
        BrowserShortcutRecorder(
            identifier: identifier, title: title, shortcut: shortcut, record: record,
            reportInvalidShortcut: reportInvalidShortcut
        )
        .frame(
            width: BrowserShortcutSettingsMetrics.recorderWidth,
            height: BrowserShortcutSettingsMetrics.recorderHeight)
    }

    /// The menu's choice of who answers the keys while a focused page uses
    /// them too.
    private func preferenceSection(_ preference: ShortcutPreference) -> some View {
        Section(BrowserShortcutSettingsPresentation.whenWebsiteUsesKeys) {
            Picker(
                BrowserShortcutSettingsPresentation.whenWebsiteUsesKeys,
                selection: Binding(get: { preference }, set: choose)
            ) {
                ForEach(ShortcutPreference.all, id: \.self) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
