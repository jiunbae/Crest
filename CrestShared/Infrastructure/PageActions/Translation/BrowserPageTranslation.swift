import Foundation
import NaturalLanguage
import Observation
@preconcurrency import Translation

/// One live document owns its offer, model work, and restoration token. Nothing
/// here is persisted or shared between pages, Spaces, profiles, or private sessions.
@Observable @MainActor
final class BrowserPageTranslation {
    /// The unsupported-language notice speaks for Detect Language only; a
    /// source the person picks from the menu is one Apple translates.
    var sourceID = "" {
        didSet {
            guard let unsupportedSourceID, sourceID != oldValue else { return }
            let notice = unsupportedNotice(for: unsupportedSourceID)
            if sourceID.isEmpty {
                status = notice
            } else if status == notice {
                status = ""
            }
        }
    }
    var targetID = ""
    private(set) var languages: [Locale.Language] = []
    @ObservationIgnored private var supportedLanguages = BrowserTranslationPreference.Languages.unloaded
    private(set) var installedLanguageIDs: Set<String> = []
    private(set) var downloadRevision = 0
    @ObservationIgnored private var languageLoadTask: Task<BrowserTranslationPreference.Languages, Never>?
    /// Apple's languages and installed models belong to the system, not to a
    /// page, so every page reads one answer. Each `LanguageAvailability`
    /// query costs Apple's framework several milliseconds on the main thread,
    /// and checking every pair on each tab switch stalled the window.
    private static var sharedLanguageLoad: Task<BrowserTranslationPreference.Languages, Never>?
    private static var installedLanguageCache: [String: (ids: Set<String>, checkedAt: ContinuousClock.Instant)] = [:]
    /// Scans under way, by language pair and generation. A scan belongs to
    /// the system's answer, not to the page that started it: leaving the
    /// page no longer throws away the questions already asked, so a person
    /// moving between pages pays for one scan instead of a fresh partial one
    /// on every visit.
    private static var installedLanguageScans: [String: (id: UUID, task: Task<Set<String>, Never>)] = [:]
    /// Advances whenever installed models may have changed, which makes every
    /// page check again and drops answers from scans already under way.
    private static var installedLanguageGeneration = 0
    /// Models installed outside Crest, in System Settings, show up after this.
    private static let installedLanguageCacheLifetime: Duration = .seconds(600)

    var downloadedLanguages: [Locale.Language] {
        languages.filter { installedLanguageIDs.contains($0.minimalIdentifier) }
    }
    var otherLanguages: [Locale.Language] { languages.filter { !installedLanguageIDs.contains($0.minimalIdentifier) } }
    var languageStatusID: String { "\(sourceID)|\(targetID)|\(downloadRevision)" }
    private(set) var configuration: TranslationSession.Configuration?
    private(set) var documentRevision = 0
    private(set) var isOffered = false
    private(set) var isDismissed = false
    private(set) var isWorking = false
    private(set) var isTranslated = false
    private(set) var status = ""
    /// The page's language when Apple cannot translate it, which no menu
    /// offers as a source.
    private(set) var unsupportedSourceID: String?
    var showsInformation = false

    @ObservationIgnored private var document: BrowserTranslationDocument?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var activeHostID: UUID?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var session: TranslationSession?
    @ObservationIgnored private var hasDetected = false
    @ObservationIgnored private var automaticAttempted = false
    @ObservationIgnored private var isAutomaticOperation = false
    @ObservationIgnored private var detectedInstalledPair: String?
    @ObservationIgnored private var lastConfiguration: TranslationSession.Configuration?
    @ObservationIgnored private var restorationTask: Task<Void, Error>?
    private var translatedSourceID = ""
    private var translatedTargetID = ""
    private var languageRules: [TranslationRule] = []
    private var automaticallyTranslates = false
    private var offersTranslation = true
    private var isManuallyPresented = false

    var hasSelectedTranslation: Bool {
        isTranslated && sourceID == translatedSourceID && targetID == translatedTargetID
    }

    /// Whether Translate can run: a target is chosen, and the source is one
    /// Apple translates. A page in a language Apple does not translate waits
    /// for the person to choose a source language themselves.
    var canTranslate: Bool {
        !targetID.isEmpty && (unsupportedSourceID == nil || !sourceID.isEmpty)
    }

    var showsToolbar: Bool {
        isOffered && !isDismissed
            && (isManuallyPresented || (offersTranslation && !automaticallyTranslates))
    }

    func updatePreferences(
        automaticallyTranslates: Bool, offersTranslation: Bool,
        languageRules: [TranslationRule] = []
    ) {
        if languageRules != self.languageRules {
            if isAutomaticOperation { cancel() }
            self.languageRules = languageRules
            automaticAttempted = false
        }
        if automaticallyTranslates && !self.automaticallyTranslates {
            automaticAttempted = false
            isDismissed = false
            isManuallyPresented = false
        }
        // Each page visit reapplies the same preferences; an equal assignment
        // would still redraw the translation toolbar.
        if self.automaticallyTranslates != automaticallyTranslates {
            self.automaticallyTranslates = automaticallyTranslates
        }
        if self.offersTranslation != offersTranslation { self.offersTranslation = offersTranslation }
    }
    var targetName: String { languageName(targetID) }

    func languageName(_ identifier: String) -> String {
        guard !identifier.isEmpty else { return String(localized: "Detect Language") }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Apple's low-latency models where they cover the pair, and Apple's
    /// default model for a language they leave out, such as Swedish.
    private func usesLowLatency(from source: String, to target: String) -> Bool {
        supportedLanguages.usesLowLatency(from: source, to: target)
    }

    private func availability(from source: String, to target: String) -> LanguageAvailability {
        BrowserTranslationPreference.languageAvailability(lowLatency: usesLowLatency(from: source, to: target))
    }

    private func unsupportedNotice(for identifier: String) -> String {
        String(localized: "Apple Translation doesn’t support \(languageName(identifier)).")
    }

    /// Whole-page translation rewrites the live DOM of `document`, the page's
    /// main document on whichever engine shows it.
    func setActive(_ active: Bool, in document: BrowserTranslationDocument, hostID: UUID? = nil) {
        // Reparenting a live page can mount its next host before the previous
        // host disappears. Only the current host may end that presentation.
        if !active, let hostID, activeHostID != hostID { return }
        activeHostID = active ? hostID : nil
        self.document = document
        isActive = active
        if !active { cancel() }
    }

    /// Detects the page's language once it settles. The page's host cancels
    /// detection when the page starts loading again and runs it anew.
    func detect() async {
        guard isActive, !hasDetected, !isWorking, let document else { return }
        let revision = documentRevision
        do {
            for attempt in 0..<3 {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 1500 : 1000))
                guard isActive, revision == documentRevision, !isWorking else { return }
                let sample = try await document.sample()
                let detected = await Task.detached(priority: .utility) { Self.detectedLanguage(in: sample) }.value
                try Task.checkCancellation()
                guard isActive, revision == documentRevision, !isWorking else { return }
                guard let detected else { continue }
                hasDetected = true
                sourceID = detected
                await loadLanguages()
                guard isActive, revision == documentRevision, !isWorking, !Task.isCancelled else { return }
                let detectedLanguage = Locale.Language(identifier: detected)
                let supported =
                    languages.first { $0.minimalIdentifier == detectedLanguage.minimalIdentifier }
                    ?? languages.first {
                        $0.languageCode == detectedLanguage.languageCode && $0.script == detectedLanguage.script
                    }
                // Apple lists every language it translates, so one missing from
                // a loaded list is not offered and cannot be chosen. A page in
                // the person's own language says so too, for when they open
                // translation themselves.
                if supported == nil, !languages.isEmpty {
                    sourceID = ""
                    unsupportedSourceID = detected
                    status = unsupportedNotice(for: detected)
                    return
                }
                sourceID = supported?.minimalIdentifier ?? detected
                let preferred = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
                guard
                    languageRules.decision(for: detected)?.target != nil
                        || preferred.languageCode != detectedLanguage.languageCode
                else { return }
                if let target = languageRules.decision(for: sourceID)?.target, automaticallyTranslates {
                    targetID = target
                }
                let availability = await availability(from: sourceID, to: targetID).status(
                    from: .init(identifier: sourceID), to: .init(identifier: targetID))
                guard isActive, revision == documentRevision, !isWorking, !Task.isCancelled else { return }
                isOffered = availability != .unsupported
                detectedInstalledPair = availability == .installed ? "\(sourceID)|\(targetID)" : nil
                return
            }
            hasDetected = true
        } catch {
            // Detection never interrupts navigation or requests a model download.
        }
    }

    nonisolated static func detectedLanguage(in sample: BrowserTranslationDocument.Sample) -> String? {
        guard sample.text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample.text)
        let dominant = recognizer.dominantLanguage
        let confidence = dominant.map { recognizer.languageHypotheses(withMaximum: 1)[$0, default: 0] } ?? 0
        if sample.text.count >= 80, confidence >= 0.8 { return dominant?.rawValue }
        // Search pages and other mixed-language interfaces can have a weak
        // statistical result while explicitly declaring the document language.
        let declared = Locale.Language(identifier: sample.declaredLanguage)
        if !sample.declaredLanguage.isEmpty, let code = declared.languageCode?.identifier, code != "und" {
            return declared.minimalIdentifier
        }
        return sample.text.count >= 20 && confidence >= 0.6 ? dominant?.rawValue : nil
    }

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        let load =
            languageLoadTask
            ?? Self.sharedLanguageLoad
            ?? Task { await BrowserTranslationPreference.languages() }
        languageLoadTask = load
        Self.sharedLanguageLoad = load
        let loaded = await load.value
        // An empty answer may be Apple's service not yet ready; ask again later.
        if loaded.all.isEmpty, Self.sharedLanguageLoad == load { Self.sharedLanguageLoad = nil }
        supportedLanguages = loaded
        languages = loaded.all.sorted {
            languageName($0.minimalIdentifier).localizedStandardCompare(languageName($1.minimalIdentifier))
                == .orderedAscending
        }
        languageLoadTask = nil
        guard targetID.isEmpty else { return }
        let preferred = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        targetID = BrowserTranslationPreference.preferredTarget(in: languages, preferred: preferred).minimalIdentifier
    }

    func refreshInstalledLanguages(force: Bool = false) async {
        await loadLanguages()
        // A page already left keeps any scan it joined, but starts none.
        guard !Task.isCancelled else { return }
        // The shared answer, while fresh, replaces asking Apple again; it
        // expires so models changed outside Crest appear on a later visit.
        let generation = Self.installedLanguageGeneration
        let check = "\(languageStatusID)|\(generation)"
        let cacheKey = "\(sourceID)|\(targetID)"
        if !force, let cached = Self.installedLanguageCache[cacheKey],
            cached.checkedAt.duration(to: .now) < Self.installedLanguageCacheLifetime
        {
            // Assigning an equal set still invalidates every view reading it.
            if installedLanguageIDs != cached.ids { installedLanguageIDs = cached.ids }
            return
        }
        let scanKey = "\(cacheKey)|\(generation)"
        let scan: Task<Set<String>, Never>
        if !force, let running = Self.installedLanguageScans[scanKey] {
            scan = running.task
        } else {
            // A forced scan replaces the one under way, whose answer is older.
            Self.installedLanguageScans[scanKey]?.task.cancel()
            let scanID = UUID()
            let identifiers = languages.map(\.minimalIdentifier)
            // Apple reports installed pairs. A positive result confirms both
            // languages; unsupported/supported pairs do not prove either is absent.
            var pairs = identifiers.map { [$0, targetID] }
            if !sourceID.isEmpty { pairs += identifiers.map { [sourceID, $0] } }
            let supported = supportedLanguages
            scan = Task {
                let installed = await Self.installedLanguages(in: pairs, supported: supported)
                // Only the scan still registered for this pair speaks for it;
                // a replaced or cancelled one returns a partial, older answer.
                guard Self.installedLanguageScans[scanKey]?.id == scanID else { return installed }
                Self.installedLanguageScans[scanKey] = nil
                if !Task.isCancelled, generation == Self.installedLanguageGeneration {
                    Self.installedLanguageCache[cacheKey] = (installed, .now)
                }
                return installed
            }
            Self.installedLanguageScans[scanKey] = (scanID, scan)
        }
        let installed = await scan.value
        guard !Task.isCancelled, !scan.isCancelled,
            check == "\(languageStatusID)|\(Self.installedLanguageGeneration)"
        else { return }
        if installedLanguageIDs != installed { installedLanguageIDs = installed }
    }

    /// Asks Apple about each pair in turn, pausing between questions. Apple
    /// answers each one with ~13 ms of work on the main queue; asked four at a
    /// time, those answers landed in bursts that stalled tab switches. Asking
    /// one at a time spaces that work out; it does not guarantee every frame.
    private nonisolated static func installedLanguages(
        in pairs: [[String]], supported: BrowserTranslationPreference.Languages
    ) async -> Set<String> {
        var installed: Set<String> = []
        // One availability per model for the whole scan: each new one makes
        // Apple rebuild its supported pairs on the main queue.
        let general = BrowserTranslationPreference.languageAvailability(lowLatency: false)
        let lowLatencyAvailability = BrowserTranslationPreference.languageAvailability(lowLatency: true)
        for (index, pair) in pairs.enumerated() {
            if index > 0 { try? await Task.sleep(for: installedLanguagePause) }
            guard !Task.isCancelled else { break }
            guard !pair[0].isEmpty, !pair[1].isEmpty else { continue }
            let lowLatency = supported.usesLowLatency(from: pair[0], to: pair[1])
            let status = await (lowLatency ? lowLatencyAvailability : general).status(
                from: .init(identifier: pair[0]), to: .init(identifier: pair[1]))
            if status == .installed { installed.formUnion(pair) }
        }
        return installed
    }

    private nonisolated static let installedLanguagePause: Duration = .milliseconds(24)

    func present() {
        isManuallyPresented = true
        isOffered = true
        isDismissed = false
        Task { await loadLanguages() }
    }

    func automaticallyTranslateIfAvailable(enabled: Bool) async {
        if !enabled, isAutomaticOperation { cancel() }
        guard enabled, isActive, hasDetected, !isDismissed,
            !automaticAttempted, !isWorking, !isTranslated, !sourceID.isEmpty
        else { return }
        let revision = documentRevision
        let source = Locale.Language(identifier: sourceID)
        guard let mappedTarget = languageRules.decision(for: sourceID)?.target else { return }
        let target = Locale.Language(identifier: mappedTarget)
        let confirmedPair = detectedInstalledPair == "\(sourceID)|\(target.minimalIdentifier)"
        let availability: LanguageAvailability.Status
        if confirmedPair {
            availability = .installed
        } else {
            availability = await self.availability(from: sourceID, to: target.minimalIdentifier).status(
                from: source, to: target)
        }
        guard !Task.isCancelled, isActive, revision == documentRevision,
            source == Locale.Language(identifier: sourceID),
            languageRules.decision(for: sourceID)?.target == mappedTarget,
            !isWorking, !isTranslated,
            !automaticAttempted, !isDismissed
        else { return }
        automaticAttempted = true
        targetID = target.minimalIdentifier
        guard availability == .installed else {
            status = String(localized: "Download languages to translate automatically. Tap Translate to continue.")
            return
        }
        #if !targetEnvironment(simulator)
            targetID = target.minimalIdentifier
            isWorking = true
            isAutomaticOperation = true
            status = String(localized: "Automatically translating to \(targetName)…")
            // This session cannot request downloads or present consent UI.
            let installedSession: TranslationSession
            if #available(iOS 26.4, macOS 26.4, *), usesLowLatency(from: sourceID, to: target.minimalIdentifier) {
                installedSession = TranslationSession(
                    installedSource: source, target: target, preferredStrategy: .lowLatency)
            } else {
                installedSession = TranslationSession(installedSource: source, target: target)
            }
            await run(using: installedSession, configuration: nil)
        #endif
    }

    func setToolbarVisible(_ visible: Bool) {
        guard visible != showsToolbar else { return }
        if visible { present() } else { dismiss() }
    }

    func toggleToolbarVisibility() {
        setToolbarVisible(!showsToolbar)
    }

    func dismiss() {
        automaticAttempted = true
        isDismissed = true
        // Hiding chrome must not cancel a running page translation.
    }

    func start() {
        guard isActive, !isWorking, canTranslate else { return }
        isManuallyPresented = true
        automaticAttempted = true
        isAutomaticOperation = false
        isOffered = true
        isDismissed = false
        #if targetEnvironment(simulator)
            status = String(
                localized: "Apple Translation requires a physical device. It is not available in Simulator.")
            showsInformation = true
        #else
            isWorking = true
            status = String(localized: "Preparing translation…")
            var next = lastConfiguration ?? .init()
            next.source = sourceID.isEmpty ? nil : .init(identifier: sourceID)
            next.target = .init(identifier: targetID)
            if #available(iOS 26.4, macOS 26.4, *) {
                next.preferredStrategy = usesLowLatency(from: sourceID, to: targetID) ? .lowLatency : .highFidelity
            }
            next.invalidate()
            lastConfiguration = next
            configuration = next
        #endif
    }

    func run(using session: TranslationSession, configuration expected: TranslationSession.Configuration?) async {
        guard expected != nil || isAutomaticOperation,
            expected == configuration, isActive, isWorking, let document
        else { return }
        let automatic = isAutomaticOperation
        self.session = session
        let revision = documentRevision
        let operation = UUID().uuidString
        token = operation
        defer {
            if token == operation {
                isWorking = false
                configuration = nil
                self.session = nil
                isAutomaticOperation = false
                downloadRevision &+= 1
                // A finished download can install a model any page lists.
                Self.installedLanguageCache.removeAll()
                for scan in Self.installedLanguageScans.values { scan.task.cancel() }
                Self.installedLanguageScans.removeAll()
                Self.installedLanguageGeneration &+= 1
            }
        }
        do {
            if automatic {
                let ready = await session.isReady
                try validate(operation, revision: revision)
                guard ready else {
                    status = String(localized: "Automatic translation is unavailable. Tap Translate to try manually.")
                    return
                }
            }
            let capture = try await document.capture(token: operation)
            try validate(operation, revision: revision)
            isTranslated = false
            guard !capture.texts.isEmpty else {
                status = String(
                    localized:
                        "No supported page text was found. Editable fields, embedded pages, and images are excluded.")
                return
            }
            // Only an explicit Translate action reaches the framework's model
            // download consent UI. Auto-detection never prepares a session.
            if !automatic { try await session.prepareTranslation() }
            try validate(operation, revision: revision)
            var applied = 0
            var completed = 0
            try await Self.translate(capture.texts, using: session) { updates in
                try self.validate(operation, revision: revision)
                applied += try await document.apply(updates, token: operation)
                try self.validate(operation, revision: revision)
                completed += updates.count
                self.isTranslated = applied > 0
                self.status =
                    automatic
                    ? String(localized: "Automatically translating… \(completed) of \(capture.texts.count)")
                    : String(localized: "Translating… \(completed) of \(capture.texts.count)")
            }
            translatedSourceID = sourceID
            translatedTargetID = targetID
            if capture.isLimited || applied < capture.texts.count {
                status =
                    automatic
                    ? String(
                        localized:
                            "Automatically translated available text to \(targetName). Some content was too large or changed during translation."
                    )
                    : String(
                        localized:
                            "Translated available text. Some content was too large or changed during translation.")
            } else {
                status =
                    automatic
                    ? String(localized: "Automatically translated to \(targetName)")
                    : String(localized: "Translated to \(targetName)")
            }
        } catch {
            guard token == operation, revision == documentRevision else { return }
            try? await document.restore(token: operation)
            guard token == operation, revision == documentRevision else { return }
            isTranslated = false
            status =
                error is CancellationError
                ? String(localized: "Translation cancelled. Original text restored.")
                : String(localized: "Translation could not finish. \(error.localizedDescription)")
        }
    }

    // Build requests and consume responses away from the UI executor. Repeated
    // text is translated once, and the first result reaches the page immediately.
    private nonisolated static func translate(
        _ texts: [String], using session: TranslationSession,
        receive: @MainActor @Sendable ([BrowserTranslationDocument.Update]) async throws -> Void
    ) async throws {
        let indices = Dictionary(grouping: texts.indices, by: { texts[$0] })
        var seen: Set<String> = []
        let requests = texts.enumerated().compactMap { index, text -> TranslationSession.Request? in
            guard seen.insert(text).inserted else { return nil }
            return TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        var pending: [BrowserTranslationDocument.Update] = []
        var lastDelivery: ContinuousClock.Instant?
        for try await response in session.translate(batch: requests) {
            try Task.checkCancellation()
            guard let identifier = response.clientIdentifier, let index = Int(identifier), texts.indices.contains(index)
            else { continue }
            pending += (indices[texts[index]] ?? []).map { .init(index: $0, text: response.targetText) }
            let now = ContinuousClock.now
            if lastDelivery == nil || pending.count >= 8 || lastDelivery!.duration(to: now) >= .milliseconds(60) {
                try await receive(pending)
                pending.removeAll(keepingCapacity: true)
                lastDelivery = now
            }
        }
        if !pending.isEmpty { try await receive(pending) }
    }

    private func validate(_ operation: String, revision: Int) throws {
        try Task.checkCancellation()
        guard isActive, token == operation, documentRevision == revision else { throw CancellationError() }
    }

    func suspend() {
        activeHostID = nil
        isActive = false
        cancel()
    }

    func showOriginal() {
        automaticAttempted = true
        cancel(restoringCompleted: true)
    }

    func cancel(restoringCompleted: Bool = false) {
        guard isWorking || restoringCompleted else { return }
        session?.cancel()
        session = nil
        configuration = nil
        isWorking = false
        isAutomaticOperation = false
        let previous = token
        token = nil
        isTranslated = false
        status = String(localized: "Original page")
        if let previous, let document {
            let revision = documentRevision
            let restoration = Task { try await document.restore(token: previous) }
            restorationTask = restoration
            Task {
                do { try await restoration.value } catch {
                    guard token == nil, revision == documentRevision else { return }
                    status = String(localized: "The page could not be restored. Reload to show the original document.")
                }
            }
        }
    }

    func prepareForReaderMode() async throws {
        reset()
        try await restorationTask?.value
    }

    func documentURLDidChange(from previous: URL?, to next: URL?) {
        // In-document anchors retain their translation; a new route does not.
        guard
            previous?.absoluteString.split(separator: "#", maxSplits: 1).first
                != next?.absoluteString.split(separator: "#", maxSplits: 1).first
        else { return }
        reset()
    }

    func reset() {
        cancel(restoringCompleted: true)
        documentRevision &+= 1
        hasDetected = false
        automaticAttempted = false
        detectedInstalledPair = nil
        sourceID = ""
        unsupportedSourceID = nil
        isOffered = false
        isManuallyPresented = false
        isDismissed = false
        showsInformation = false
        status = ""
    }
}
