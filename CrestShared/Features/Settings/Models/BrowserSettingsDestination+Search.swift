import Foundation

extension BrowserSettingsDestination {
    /// The concrete localized haystack used only while filtering Settings.
    /// Presentation remains deferred through ``LocalizedStringResource``.
    private func searchIndex(locale: Locale) -> String {
        [title, navigationTitle, subtitle, searchTerms]
            .map { resource in
                var localizedResource = resource
                localizedResource.locale = locale
                return String(localized: localizedResource)
            }
            .joined(separator: " ")
    }

    func matchesSearchQuery(_ query: String, locale: Locale) -> Bool {
        searchIndex(locale: locale).range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        ) != nil
    }
}

extension BrowserSettingsDestination {
    /// Every settings page as the command palette offers it: by its name,
    /// with its title and the words a person might type to find it.
    /// Built once: SwiftUI bodies rebuild the palette registry on every
    /// update, and localizing every page each time showed up on Space switches.
    static let palettePages: [PaletteSettingsPage] = makePalettePages()

    private static func makePalettePages() -> [PaletteSettingsPage] {
        all.map {
            PaletteSettingsPage(
                name: $0.name, title: String(localized: $0.title),
                terms: [String(localized: $0.subtitle), String(localized: $0.searchTerms)].joined(separator: " "))
        }
    }
}
