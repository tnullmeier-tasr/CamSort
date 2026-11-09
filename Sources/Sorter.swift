import Foundation
import AVFoundation
import AppKit
import ImageIO

// MARK: - Rückfragen

enum DupChoice { case skip, keepBoth, replace }

final class DuplicateRequest: Identifiable {
    let id = UUID()
    let name: String
    let folder: String
    let continuation: CheckedContinuation<(DupChoice, Bool), Never>
    init(name: String, folder: String, continuation: CheckedContinuation<(DupChoice, Bool), Never>) {
        self.name = name; self.folder = folder; self.continuation = continuation
    }
}

final class CameraRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let hint: String
    let suggestion: String
    let signature: String
    let signatureLabel: String
    let continuation: CheckedContinuation<String?, Never>
    init(fileName: String, hint: String, suggestion: String, signature: String, signatureLabel: String,
         continuation: CheckedContinuation<String?, Never>) {
        self.fileName = fileName; self.hint = hint; self.suggestion = suggestion
        self.signature = signature; self.signatureLabel = signatureLabel; self.continuation = continuation
    }
}

final class ExtensionRequest: Identifiable {
    let id = UUID()
    let extensions: [(ext: String, example: String, count: Int)]
    let continuation: CheckedContinuation<[String: FileCategory]?, Never>
    init(extensions: [(ext: String, example: String, count: Int)], continuation: CheckedContinuation<[String: FileCategory]?, Never>) {
        self.extensions = extensions; self.continuation = continuation
    }
}

/// Rückfrage vor dem Lauf (erweiterbar: weitere Fragen einfach als PreRunQuestion ergänzen)
struct QuestionOption: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
}

/// Optionales Textfeld in einer Rückfrage (z. B. Projektname). Wird nur bei Optionen angezeigt, deren id mit `showFor` beginnt.
struct QuestionField: Identifiable, Hashable {
    let id: String
    let label: String
    let value: String
    var showFor: String = ""
}

final class QuestionRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let icon: String
    let options: [QuestionOption]
    let fields: [QuestionField]
    /// Konkretes Beispiel aus genau diesem Ordner (echter Dateiname → Zielpfad)
    var example: String? = nil
    /// Empfohlene Option (nur hervorgehoben, nie automatisch übernommen) und kurzer Grund
    var recommended: String? = nil
    var reason: String? = nil
    /// Vorschau der Ordnerstruktur (Übersicht)
    var tree: [String] = []
    /// Beschriftung des Merken-Hakens (Standard: „Antwort merken“)
    var rememberLabel: String? = nil
    /// „Zurück“ möglich (Fragenrunde vor dem ersten Verschieben, nicht bei der ersten Frage)
    var canGoBack = false
    /// Vorbelegung nach „Zurück“
    var prefill: String? = nil
    var prefillFields: [String: String] = [:]
    var prefillRemember = false
    let continuation: CheckedContinuation<(String, Bool)?, Never>
    init(title: String, message: String, icon: String, options: [QuestionOption], fields: [QuestionField] = [],
         continuation: CheckedContinuation<(String, Bool)?, Never>) {
        self.title = title; self.message = message; self.icon = icon; self.options = options; self.fields = fields; self.continuation = continuation
    }
}

/// Eine Frage, die vor dem Verschieben ausgewertet wird. `preset` = schon feststehende Antwort
/// (gemerkt oder aus vorhandener Ordnerstruktur) → dann wird nicht gefragt.
struct PreRunQuestion {
    let key: String
    let title: String
    let message: String
    let icon: String
    let options: [QuestionOption]
    let preset: String?
    let remember: (String) -> Void
    /// Optionale Textfelder; Antworten landen in resolve() unter "<key>.<feld-id>"
    var fields: [QuestionField] = []
    /// Echtes Beispiel aus diesem Ordner, z. B. „C0042.MP4 → Pitbike/E1/50 fps/Hochkant“
    var example: String? = nil
    /// Empfohlene Option + Grund (nur hervorgehoben, nie automatisch übernommen)
    var recommended: String? = nil
    var reason: String? = nil
    var tree: [String] = []
    var rememberLabel: String? = nil
}

/// Eine beantwortete Frage der Fragenrunde (für „Zurück“: wird beim Neuberechnen still wiederholt)
struct LoggedAnswer {
    let key: String
    let answer: String
    let fields: [String: String]
    let remember: Bool
}

/// Ergebnis eines Rückgängig-Laufs für die Anzeige
struct UndoResultInfo: Identifiable {
    let id = UUID()
    let title: String
    let report: UndoReport
}

/// Was nach einem erfolgreichen Verschieben gezählt wird
enum MoveCounter { case video(String?, String), side(String), photo }

enum Phase { case idle, scanning, sorting, done, cancelled }

/// Momentaufnahme der Sortier-Einstellungen zu Beginn eines Laufs. Das Einstellungs-Fenster ist in jeder Phase
/// erreichbar; was dort während eines Laufs geändert wird, wirkt erst beim nächsten Lauf (keine halb-alte/halb-neue Struktur).
struct RunSettings {
    var compactLayout: Bool
    var ownCameraFolders: Bool
    var includeSubfolders: Bool
    var nestLevels: Bool
    var autoGyro: Bool
    var levels: [String]
    var sortByLens: Bool
    var droneBySpeed: Bool
    var standMin: Double
    var standMax: Double
    var moveMin: Double
    var moveMax: Double
    var lengthThreshold: Double
    var lengthShort: String
    var lengthLong: String
    var sceneGapMinutes: Double
    var gyroSuffixList: [String]

    @MainActor init(_ s: LearnedStore) {
        compactLayout = s.compactLayout; ownCameraFolders = s.ownCameraFolders; includeSubfolders = s.includeSubfolders
        nestLevels = s.nestLevels; autoGyro = s.autoGyro; levels = s.levels
        sortByLens = s.sortByLens; droneBySpeed = s.droneBySpeed
        standMin = s.standMin; standMax = s.standMax; moveMin = s.moveMin; moveMax = s.moveMax
        lengthThreshold = s.lengthThreshold; lengthShort = s.lengthShort; lengthLong = s.lengthLong
        sceneGapMinutes = s.sceneGapMinutes; gyroSuffixList = s.gyroSuffixList
    }
}

private struct Job {
    let dir: URL      // Ordner, in dem die Datei liegt – dort wird einsortiert
    let url: URL
    let cat: FileCategory
    let ext: String
}

/// Ergebnis der Kamera-Erkennung
private struct Detection {
    var name: String?        // sicher erkannter Name (z. B. "Sony Alpha 1")
    var signature: String    // Schlüssel zum Lernen
    var label: String        // woran erkannt (für die Anzeige)
    var hint: String         // Text für die Rückfrage
}

// MARK: - Sortierer

@MainActor
final class Sorter: ObservableObject {
    @Published var folders: [URL] = []
    @Published var phase: Phase = .idle
    @Published var total = 0
    @Published var processed = 0
    @Published var currentFile = ""
    @Published var counts: [String: Int] = [:]
    @Published var sideCounts: [String: Int] = [:]
    @Published var cameras: [String: Int] = [:]
    @Published var lenses: [String: Int] = [:]
    @Published var speeds: [String: Int] = [:]
    @Published var skipped = 0
    @Published var ignored = 0
    @Published var problems: [String] = []
    @Published var hints: [String] = []
    @Published var pendingDuplicate: DuplicateRequest?
    /// Gefundene Final-Cut-Mediatheken (nach dem Sortieren: Hinweis zum Neu-Verknüpfen)
    @Published var fcpLibraries: [URL] = []
    @Published var movedVideos = 0
    @Published var pendingCamera: CameraRequest?
    @Published var pendingExtensions: ExtensionRequest?
    @Published var pendingQuestion: QuestionRequest?
    // MARK: Datensicherheit
    /// Protokoll des laufenden bzw. letzten Laufs
    var journal: RunJournal?
    /// Protokolldatei des letzten Laufs mit Änderungen (Knopf „Rückgängig machen“ im Fertig-Bildschirm)
    @Published var lastJournal: URL?
    @Published var lastJournalUndone = false
    @Published var undoResult: UndoResultInfo?
    /// Protokolle, die in den eingeworfenen Ordnern liegen (Startbildschirm: „Sortiert am … – Rückgängig machen“)
    @Published var folderRuns: [String: [RunInfo]] = [:]
    /// Speicherkarte → zum Import wechseln (ContentView öffnet den Import mit dieser Quelle)
    @Published var importRequest: URL?
    /// Übersicht bestätigt bzw. erstes Verschieben erfolgt → ab hier keine „Zurück“-Navigation mehr
    private(set) var executionConfirmed = false
    private var safetyStop = false
    private var cancelledInQuestion = false
    private var goImport = false
    private var answerLog: [LoggedAnswer] = []
    private var replay: [LoggedAnswer] = []
    private var prefillNext: LoggedAnswer?
    private var backRequested = false
    /// „Antwort merken“ wird erst beim Start (Übersicht bestätigt) dauerhaft gespeichert
    private var pendingRemembers: [(apply: (String) -> Void, value: String)] = []
    private var pendingLearn: [() -> Void] = []
    /// In der Fragenrunde beantwortete Dateitypen (gelten für den ganzen Lauf)
    private var sessionExt: [String: FileCategory] = [:]
    private var originalFolders: [URL] = []
    /// Projekt-Trennung: geplant in Phase 1, ausgeführt erst nach allen Fragen
    fileprivate var splitPlans: [SplitPlan] = []
    private var plannedFolders: [URL] = []
    /// Layout-Dateien, die erst nach der Übersicht geschrieben werden
    private var layoutWrites: [(LayoutSig, URL)] = []
    /// Aufnahmezeiten je gewähltem Ordner (für „Datum in den Ordnernamen“)
    private var drehStarts: [String: [Date]] = [:]
    /// Modus „Meine Kameraordner“: Ergebnis je Kameraordner
    @Published var folderStats: [CamFolderStat] = []
    /// Clips mit Gyrodaten nach dem Sortieren (Angebot im Fertig-Bildschirm)
    @Published var gyroOffer: [URL] = []
    @Published var gyroOfferByCamera: [String: Int] = [:]
    /// Projekte (bei langer Drehpause getrennt) – Zusammenfassung für den Fertig-Bildschirm
    @Published var projectSummaries: [ProjectSummary] = []
    /// In diesem Lauf wird nach Projektordnern gearbeitet (Datumsfrage dann je Projekt)
    var projectRoots: [URL] = []
    /// Textfeld-Antworten der zuletzt beantworteten Rückfrage
    var lastFieldAnswers: [String: String] = [:]

    let store: LearnedStore
    /// Einstellungen, eingefroren beim Start eines Laufs – Änderungen im Einstellungs-Fenster gelten ab dem nächsten Lauf.
    private(set) var cfg: RunSettings

    nonisolated static let videoExt: Set<String> = ["mp4", "mov", "m4v", "insv", "mts", "m2ts", "avi", "mkv", "3gp", "mxf"]
    nonisolated static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "hif", "tif", "tiff", "raw",
                                        "cr2", "cr3", "nef", "raf", "orf", "rw2", "insp", "webp", "gif", "srw", "pef"]
    nonisolated static let musicExt: Set<String> = ["mp3", "wav", "aac", "m4a", "aif", "aiff", "flac", "ogg", "opus", "wma", "caf"]
    nonisolated static let archiveExt: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz"]
    nonisolated static let projectExt: Set<String> = ["fcpbundle", "fcpxml", "fcpxmld", "fcpxd"]
    nonisolated static let sideExt: Set<String> = ["gyroflow", "xml", "lrf", "srt", "thm", "aae", "xmp", "bim", "lrv"]
    nonisolated static let alwaysIgnore: Set<String> = ["ds_store", "db", "ini", "localized"]
    static var fixedOutput: Set<String> { FolderNames.outputNames.union(["Musik", "ZIP", "FCP", "Hochkant", "Quer", "Quadratisch", FolderNames.square, "Stabilisiert", "Original", "Gyroflow-Projekte"]) }

    private var dupForAll: DupChoice?
    @Published var skipAsking = false   // „Lernen überspringen“ für diesen Durchlauf
    private var askedCameras: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var videosRootCache: [String: URL] = [:]
    private let fm = FileManager.default

    init(store: LearnedStore) { self.store = store; self.cfg = RunSettings(store); FolderNames.load() }

    /// Läuft gerade ein Lauf (Einlesen, Sortieren, Gyroflow-Trennung)?
    var isRunning: Bool { phase == .scanning || phase == .sorting }

    var progress: Double { total == 0 ? 0 : Double(processed) / Double(total) }
    var movedTotal: Int { counts.values.reduce(0, +) + sideCounts.values.reduce(0, +) }

    func addFolders(_ urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, !folders.contains(u) { folders.append(u) }
        }
        refreshFolderRuns()
    }

    /// true, solange das Finder-Fenster zur Ordnerwahl offen ist (Startbildschirm pausiert dann seine Animation)
    @Published var pickingFolder = false
    /// Einstellungs-Sheet (ein gemeinsames für alle Phasen, im Header)
    @Published var showSettings = false

    /// Ordnerwahl ohne runModal: Das Finder-Fenster läuft seit macOS 15+ in einem eigenen Prozess und
    /// bleibt beim Laden hängen, wenn die App währenddessen dauerhaft animiert. Daher begin { } (nicht blockierend),
    /// App vorher aktivieren und den zuletzt benutzten Ordner vorwählen.
    func chooseFolders() {
        guard !pickingFolder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Auswählen"
        panel.message = "Welche Ordner sollen sortiert werden?"
        if let last = UserDefaults.standard.string(forKey: "lastPickDir"), fm.fileExists(atPath: last) {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        pickingFolder = true
        NSApp.activate()
        panel.begin { [weak self] resp in
            Task { @MainActor in
                guard let self else { return }
                self.pickingFolder = false
                guard resp == .OK, !panel.urls.isEmpty else { return }
                if let first = panel.urls.first {
                    UserDefaults.standard.set(first.deletingLastPathComponent().path, forKey: "lastPickDir")
                }
                self.addFolders(panel.urls)
            }
        }
    }

    func reset() {
        folders = []; phase = .idle; total = 0; processed = 0; currentFile = ""
        clearResults()
    }

    private func clearResults() {
        counts = [:]; sideCounts = [:]; cameras = [:]; lenses = [:]; speeds = [:]; skipped = 0; ignored = 0
        problems = []; hints = []; movedVideos = 0; videosRootCache = [:]; folderStats = []; gyroOffer = []; gyroOfferByCamera = [:]; drehStarts = [:]; projectSummaries = []; projectRoots = []; dupForAll = nil; skipAsking = false; askedCameras = [:]; gyroMoved = 0
    }

    /// Lauf in zwei Phasen: 1) Fragenrunde + Planung (keine einzige Dateioperation), 2) Ausführen mit Protokoll.
    func start() {
        guard !folders.isEmpty else { return }
        FolderNames.load()
        cfg = RunSettings(store)
        originalFolders = folders
        Self.selectedBases = Set(folders.map { $0.standardizedFileURL.path })
        clearResults(); processed = 0
        beginJournal("Sortieren")
        phase = .scanning
        task = Task {
            while true {
                backRequested = false
                await flow()
                // „Zurück“ in der Fragenrunde: Phase 1 neu berechnen, bisherige Antworten still wiederholen
                if backRequested && !hasOps && !Task.isCancelled {
                    let keepCams = askedCameras, keepExt = sessionExt, keepSkip = skipAsking
                    folders = originalFolders
                    Self.selectedBases = Set(folders.map { $0.standardizedFileURL.path })
                    cfg = RunSettings(store)
                    clearResults(); processed = 0
                    askedCameras = keepCams; sessionExt = keepExt; skipAsking = keepSkip
                    answerLog = []
                    splitPlans = []; plannedFolders = []; layoutWrites = []
                    executionConfirmed = false; cancelledInQuestion = false
                    phase = .scanning
                    continue
                }
                break
            }
            finishRun()
        }
    }

    private func flow() async {
        guard await cardCheck() else { phase = .cancelled; stepLabel = ""; return }
        guard await suggestOwnCameraFolders() else { phase = .cancelled; stepLabel = ""; return }
        stepLabel = "Projekte prüfen …"
        guard await splitProjects() else { phase = .cancelled; stepLabel = ""; return }
        stepLabel = "Dateien prüfen …"
        guard await preAsk() else { phase = .cancelled; stepLabel = ""; return }
        if !splitPlans.isEmpty {
            guard await executeSplits() else { phase = .cancelled; stepLabel = ""; return }
        }
        stepLabel = cfg.ownCameraFolders ? "Meine Kameraordner: Hochkant / Quer"
                  : alreadySorted ? "Ordner schon sortiert – suche neue Dateien" : "Schritt 1: Sortieren"
        if cfg.ownCameraFolders { await runOwnCameraFolders() } else { await run() }
        guard phase != .cancelled, !Task.isCancelled, !safetyStop else { return }
        await renameDrehFolders()
        guard phase != .cancelled, !Task.isCancelled, !safetyStop else { return }
        if cfg.autoGyro { await runGyro(auto: true) }
        stepLabel = ""
        phase = Task.isCancelled || safetyStop ? .cancelled : .done
    }

    // MARK: Datensicherheit – Protokoll, Fragenrunde, Übersicht

    var hasOps: Bool { !(journal?.isEmpty ?? true) }

    private func beginJournal(_ title: String) {
        journal?.close()
        journal = RunJournal(title: title, bases: folders)
        lastJournal = nil; lastJournalUndone = false
        executionConfirmed = false; safetyStop = false; cancelledInQuestion = false; goImport = false
        answerLog = []; replay = []; prefillNext = nil; backRequested = false
        pendingRemembers = []; pendingLearn = []; sessionExt = [:]
        splitPlans = []; plannedFolders = []; layoutWrites = []
    }

    private var j: RunJournal {
        if let x = journal { return x }
        let x = RunJournal(title: "Sortieren", bases: folders)
        journal = x
        return x
    }

    /// Ab hier wird ausgeführt: gemerkte Antworten jetzt dauerhaft speichern
    private func confirmExecution() {
        executionConfirmed = true
        for r in pendingRemembers { r.apply(r.value) }
        for l in pendingLearn { l() }
        pendingRemembers = []; pendingLearn = []
    }

    private func finishRun() {
        stepLabel = ""
        currentFile = ""
        if safetyStop { phase = .cancelled }
        if phase == .done { confirmExecution() } else { pendingRemembers = []; pendingLearn = [] }
        // Abbruch in einer Rückfrage, nachdem schon verschoben wurde (nur nach einer Projekt-Trennung möglich) → automatisch zurück
        if phase == .cancelled && cancelledInQuestion && hasOps && !safetyStop, let j = journal {
            j.close()
            let r = UndoService.undoApp(j.appURL)
            hints.insert("Abgebrochen – die schon angelegten Projektordner wurden automatisch zurückgesetzt (\(plural(r.restored, "Datei", "Dateien")) zurück).", at: 0)
            problems += r.skipped
            lastJournalUndone = true
        }
        journal?.close()
        if hasOps, let j = journal { lastJournal = j.appURL }
        if goImport { phase = .idle; goImport = false }
        refreshFolderRuns()
    }

    /// Sofort stoppen (z. B. wenn eine Prüfung nach dem Verschieben fehlschlägt)
    private func stopForSafety(_ msg: String) {
        safetyStop = true
        problems.insert(msg, at: 0)
        task?.cancel()
    }

    /// „Zurück“ in der Fragenrunde: vorige Frage mit ihrer Antwort vorbelegt zeigen, Folgefragen neu berechnen
    func goBack() {
        guard let p = pendingQuestion, !answerLog.isEmpty, !hasOps else { return }
        prefillNext = answerLog.last
        replay = Array(answerLog.dropLast())
        backRequested = true
        pendingQuestion = nil
        p.continuation.resume(returning: nil)
    }

    /// Protokolle in den gewählten Ordnern lesen (Startbildschirm)
    func refreshFolderRuns() {
        var m: [String: [RunInfo]] = [:]
        for f in folders {
            let r = JournalStore.folderRuns(f)
            if !r.isEmpty { m[f.path] = r }
        }
        folderRuns = m
    }

    /// Letzten Lauf rückgängig machen (Fertig-Bildschirm)
    func undoLastRun() {
        guard let u = lastJournal, !isRunning else { return }
        let r = UndoService.undoApp(u)
        lastJournalUndone = true
        applyUndo(r, title: "Lauf rückgängig gemacht")
    }

    /// Lauf aus dem Protokoll im Ordner rückgängig machen (Startbildschirm, auch Wochen später)
    func undoFolderRun(_ info: RunInfo) {
        guard !isRunning else { return }
        let r = UndoService.undoFolder(info)
        if let nr = r.newRoot {
            folders = folders.map { $0.standardizedFileURL.path == info.root.standardizedFileURL.path ? nr : $0 }
        }
        applyUndo(r, title: "Lauf rückgängig gemacht")
    }

    private func applyUndo(_ r: UndoReport, title: String) {
        if let nr = r.newRoot, let first = folders.first, folders.count == 1, !FileManager.default.fileExists(atPath: first.path) { folders = [nr] }
        fcpLibraries = r.fcpLibraries
        undoResult = UndoResultInfo(title: title, report: r)
        refreshFolderRuns()
    }

    /// Speicherkarte eingeworfen? Erst kopieren (Import) empfehlen. false = nicht sortieren.
    private func cardCheck() async -> Bool {
        for f in folders where Safety.isMemoryCard(f) {
            let clip = (fm.enumerator(at: f, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? [])
                .first { Self.videoExt.contains($0.pathExtension.lowercased()) }
            let q = PreRunQuestion(
                key: "card", title: "Das ist eine Speicherkarte",
                message: "„\(f.lastPathComponent)“ liegt auf einer Speicherkarte bzw. einem Wechseldatenträger. Erst kopieren (Import) und die Kopie sortieren?",
                icon: "sdcard",
                options: [QuestionOption(id: "import", label: "Zum Import", detail: "Tage wählen, kopieren, per Prüfsumme kontrollieren, dann die Kopie sortieren"),
                          QuestionOption(id: "here", label: "Trotzdem hier sortieren", detail: "Dateien werden auf der Karte verschoben"),
                          QuestionOption(id: "cancel", label: "Abbrechen", detail: "Nichts passiert")],
                preset: nil, remember: { _ in },
                example: clip.map { "\($0.lastPathComponent) bleibt auf der Karte – sortiert wird die Kopie" },
                recommended: "import", reason: "Die Karte bleibt unverändert; Kamera-Software findet ihre Clips weiter.")
            guard let a = await resolve([q]) else { return false }
            switch a["card"] {
            case "import": importRequest = f; goImport = true; return false
            case "here": continue
            default: cancelledInQuestion = true; return false
            }
        }
        return true
    }

    /// Fragenrunde vor dem ersten Verschieben: unbekannte Dateitypen und Kameras über alle Ordner hinweg. false = abgebrochen.
    private func preAsk() async -> Bool {
        var unknown: [String: (example: String, count: Int)] = [:]
        var all: [(dir: URL, url: URL, ext: String)] = []
        for base in folders { all += collect(base) ?? [] }
        for f in all where category(for: f.ext) == nil {
            let cur = unknown[f.ext]
            unknown[f.ext] = (cur?.example ?? f.url.lastPathComponent, (cur?.count ?? 0) + 1)
        }
        guard let ext = await askUnknown(unknown) else { return false }
        let videos = all.filter { (category(for: $0.ext) ?? ext[$0.ext]) == .video }
        guard !cfg.ownCameraFolders else { return true }
        // Kamera-Rückfragen vorziehen: Antworten werden je Kamera-Signatur gemerkt und beim Sortieren ohne neue Frage benutzt
        var sibCache: [URL: Set<String>] = [:]
        for v in videos {
            if Task.isCancelled { return false }
            if skipAsking { break }
            currentFile = v.url.lastPathComponent
            var sib = sibCache[v.dir] ?? Set((try? fm.contentsOfDirectory(atPath: v.dir.path)) ?? [])
            sibCache[v.dir] = sib
            if cfg.compactLayout, let x = sidecar(v.url.deletingPathExtension().lastPathComponent, exts: ["M01.XML", "M01.xml"], near: v.dir) { sib.insert(x.lastPathComponent) }
            guard await camera(for: v.url, asset: AVURLAsset(url: v.url), siblings: sib) != nil else { return false }
        }
        currentFile = ""
        return true
    }

    /// Ordnerpfad zur Anzeige: „<gewählter Ordner>/<relativer Pfad>“
    func relPath(_ u: URL) -> String {
        let p = u.standardizedFileURL.path
        if let b = Self.selectedBases.filter({ p == $0 || p.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            let name = (b as NSString).lastPathComponent
            return p == b ? name : name + "/" + String(p.dropFirst(b.count + 1))
        }
        return u.lastPathComponent
    }

    /// Vorschau der Zielstruktur: obere Ebenen + Anzahl Dateien je Ordner
    func treePreview(_ dirs: [URL]) -> [String] {
        var c: [String: Int] = [:]
        for d in dirs { c[relPath(d).split(separator: "/").prefix(4).joined(separator: "/"), default: 0] += 1 }
        var lines: [String] = []
        for k in c.keys.sorted() {
            let parts = k.split(separator: "/")
            let indent = String(repeating: "   ", count: max(0, parts.count - 1))
            lines.append("\(indent)\(parts.last ?? "")/  · \(plural(c[k] ?? 0, "Datei", "Dateien"))")
        }
        if lines.count > 16 { let more = lines.count - 15; lines = Array(lines.prefix(15)) + ["… und \(more) weitere Ordner"] }
        return lines
    }

    /// Kurze Übersicht vor dem ersten Verschieben (abschaltbar). false = abgebrochen.
    private func confirmOverview(_ moves: [(URL, URL)], note: String = "") async -> Bool {
        let real = moves.filter { $0.0.deletingLastPathComponent().standardizedFileURL.path != $0.1.standardizedFileURL.path }
        guard !real.isEmpty, !executionConfirmed else { return true }
        if !store.showOverview { confirmExecution(); return true }
        var newDirs = Set<String>()
        for m in real {
            var cur = m.1.standardizedFileURL
            while !fm.fileExists(atPath: cur.path) {
                newDirs.insert(cur.path)
                let p = cur.deletingLastPathComponent()
                if p.path == cur.path { break }
                cur = p
            }
        }
        let q = PreRunQuestion(
            key: "overview", title: "Bereit zum Verschieben",
            message: "\(plural(real.count, "Datei wird", "Dateien werden")) verschoben, \(plural(newDirs.count, "Ordner", "Ordner")) angelegt – nichts wird verändert oder gelöscht. Rückgängig jederzeit möglich." + note,
            icon: "checkmark.shield",
            options: [QuestionOption(id: "start", label: "Start", detail: "Jeder Schritt wird protokolliert"),
                      QuestionOption(id: "cancel", label: "Abbrechen", detail: "Keine Datei wird bewegt")],
            preset: nil,
            remember: { [weak self] a in if a == "start" { self?.store.showOverview = false } },
            example: real.first.map { "\($0.0.lastPathComponent) → \(relPath($0.1))" },
            recommended: "start", reason: "Alle Fragen sind beantwortet; jeder Schritt lässt sich rückgängig machen.",
            tree: treePreview(real.map { $0.1 }), rememberLabel: "Übersicht nicht mehr anzeigen")
        guard let a = await resolve([q]), a["overview"] == "start" else { cancelledInQuestion = true; return false }
        confirmExecution()
        return true
    }

    private func tally(_ c: MoveCounter) {
        switch c {
        case .video(let o, let cam): movedVideos += 1; counts[o ?? "Video", default: 0] += 1; cameras[cam, default: 0] += 1
        case .side(let k): sideCounts[k, default: 0] += 1
        case .photo: counts["Fotos", default: 0] += 1
        }
    }

    /// Eigene Kameraordner (z. B. A1, E1, Avata) im eingeworfenen Ordner erkannt, Modus „Meine Kameraordner“ aber aus →
    /// einmal vorschlagen. false = abgebrochen.
    private func suggestOwnCameraFolders() async -> Bool {
        guard !cfg.ownCameraFolders, cfg.compactLayout, UserDefaults.standard.string(forKey: "ownCamSuggest") != "no" else { return true }
        var names: [String] = []
        for base in folders where !Self.looksSorted(base) {
            let kids = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            if kids.contains(where: { fm.fileExists(atPath: base.appendingPathComponent($0).appendingPathComponent(Self.projectMarker).path) }) { continue }
            let cams = kids.filter { Self.isCameraLikeFolder(base.appendingPathComponent($0)) }
            if cams.count >= 2 { names += cams }
        }
        guard let first = names.first else { return true }
        var sampleClip: (clip: String, cam: String)? = nil
        for base in folders where sampleClip == nil {
            for n in names where sampleClip == nil {
                let d = base.appendingPathComponent(n)
                if let en = fm.enumerator(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    while let u = en.nextObject() as? URL {
                        if Self.videoExt.contains(u.pathExtension.lowercased()) { sampleClip = (u.lastPathComponent, "\(base.lastPathComponent)/\(n)"); break }
                    }
                }
            }
        }
        let shown = names.count > 4 ? names.prefix(3).joined(separator: ", ") + " …" : names.joined(separator: ", ")
        let normal = wantsVideosFolder ? "Dreh/\(FolderNames.videos)/Kamera/…" : "Dreh/Kamera/…"
        let q = PreRunQuestion(
            key: "owncams", title: "Eigene Kameraordner erkannt",
            message: "Sieht aus wie eigene Kameraordner (\(shown)). Modus „Meine Kameraordner“ verwenden?",
            icon: "camera.on.rectangle",
            options: [QuestionOption(id: "yes", label: "Ja, Meine Kameraordner", detail: "\(first)/Hochkant, \(first)/Quer"),
                      QuestionOption(id: "no", label: "Nein, normal sortieren", detail: normal)],
            preset: nil,
            remember: { [weak self] a in
                if a == "yes" { self?.store.ownCameraFolders = true } else { UserDefaults.standard.set("no", forKey: "ownCamSuggest") }
            },
            example: sampleClip.map { "\($0.clip) → \($0.cam)/Hochkant bzw. \($0.cam)/Quer" },
            recommended: "yes",
            reason: "\(names.count) Unterordner enthalten jeweils Clips genau einer Kamera.")
        guard let a = await resolve([q]) else { return false }
        if a["owncams"] == "yes" { cfg.ownCameraFolders = true }
        return true
    }

    /// Schritt 2: nach Gyroflow stabilisierte und unstabilisierte Clips trennen.
    @Published var stepLabel = ""
    @Published var gyroMoved = 0
    private var alreadySorted: Bool { folders.contains(where: Self.looksSorted) }

    /// Wurde dieser Ordner schon von CamSort sortiert? (Videos-Ordner oder – ohne Videos-Sammelordner – Ebenen-Ordner direkt darin)
    static func looksSorted(_ base: URL) -> Bool {
        let fm = FileManager.default
        if FolderNames.videoAliases.contains(where: { fm.fileExists(atPath: base.appendingPathComponent($0).path) }) { return true }
        let kids = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { !$0.hasPrefix(".") }
        return kids.contains { isSortedTree(base.appendingPathComponent($0)) }
    }

    func startGyro() {
        guard !folders.isEmpty else { return }
        FolderNames.load()   // eigene Ordnernamen auch ohne vorheriges Sortieren
        cfg = RunSettings(store)
        clearResults(); processed = 0
        phase = .scanning
        Self.selectedBases = Set(folders.map { $0.standardizedFileURL.path })
        beginJournal("Gyroflow trennen")
        task = Task {
            stepLabel = "Gyroflow-Dateien trennen"; await runGyro(auto: false); stepLabel = ""
            phase = Task.isCancelled || safetyStop ? .cancelled : .done
            finishRun()
        }
    }

    private func runGyro(auto: Bool) async {
        let suffixes = cfg.gyroSuffixList
        func isStabilized(_ u: URL) -> Bool {
            let stem = u.deletingPathExtension().lastPathComponent.lowercased()
            return suffixes.contains { stem.contains($0) }
        }
        let skipDirs: Set<String> = ["Stabilisiert", "Original", "Gyroflow-Projekte"]
        var byDir: [URL: [URL]] = [:]
        for base in folders {
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                problems.append("\(base.lastPathComponent): kein Zugriff auf den Ordner"); continue
            }
            while let u = en.nextObject() as? URL {
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if v?.isDirectory == true {
                    if skipDirs.contains(u.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                guard v?.isRegularFile == true else { continue }
                let ext = u.pathExtension.lowercased()
                if Self.videoExt.contains(ext) || ext == "gyroflow" { byDir[u.deletingLastPathComponent(), default: []].append(u) }
            }
        }
        // Nur Ordner, in denen Gyroflow wirklich etwas erzeugt hat
        var jobs: [(URL, String)] = []
        var untouched = 0
        for (_, files) in byDir {
            let videos = files.filter { $0.pathExtension.lowercased() != "gyroflow" }
            guard videos.contains(where: isStabilized) else {
                if !videos.isEmpty { untouched += 1 }
                continue
            }
            for f in files {
                let target = f.pathExtension.lowercased() == "gyroflow" ? "Gyroflow-Projekte"
                           : isStabilized(f) ? "Stabilisiert" : "Original"
                jobs.append((f, target))
            }
        }
        if auto && jobs.isEmpty { return }
        if !auto && untouched > 0 && !jobs.isEmpty {
            hints.append("\(untouched) Ordner ohne stabilisierte Clips – unverändert gelassen")
        }
        if !auto {
            guard await confirmOverview(jobs.map { ($0.0, $0.0.deletingLastPathComponent().appendingPathComponent($0.1)) }) else { phase = .cancelled; return }
        }
        stepLabel = "Schritt 2: Gyroflow-Dateien trennen"
        total = jobs.count; processed = 0
        phase = .sorting
        for (f, target) in jobs.sorted(by: { $0.0.path < $1.0.path }) {
            if Task.isCancelled || safetyStop { phase = .cancelled; return }
            currentFile = f.lastPathComponent
            if await move(f, to: f.deletingLastPathComponent().appendingPathComponent(target)) {
                sideCounts[target, default: 0] += 1
                gyroMoved += 1
            }
            processed += 1
        }
        currentFile = ""
        if total == 0 && problems.isEmpty && !auto {
            hints.append("Keine stabilisierten Clips gefunden. Endungen in den Einstellungen prüfen: \(store.gyroSuffixes)")
        }
    }

    func cancel() {
        if pendingQuestion != nil || pendingExtensions != nil || pendingCamera != nil { cancelledInQuestion = true }
        task?.cancel()
        if let p = pendingDuplicate { pendingDuplicate = nil; p.continuation.resume(returning: (.skip, false)) }
        if let p = pendingCamera { pendingCamera = nil; p.continuation.resume(returning: nil) }
        if let p = pendingExtensions { pendingExtensions = nil; p.continuation.resume(returning: nil) }
        if let p = pendingQuestion { pendingQuestion = nil; p.continuation.resume(returning: nil) }
    }

    func answerQuestion(_ option: String?, remember: Bool, fields: [String: String] = [:]) {
        guard let p = pendingQuestion else { return }
        pendingQuestion = nil
        lastFieldAnswers = fields
        p.continuation.resume(returning: option.map { ($0, remember) })
    }

    /// Fragen nacheinander klären. Ergebnis: key → Antwort; nil = abgebrochen.
    /// „Antwort merken“ gilt erst beim Start (Übersicht bestätigt); vorher nur vorgemerkt. Nach „Zurück“ werden die
    /// früheren Antworten still wiederholt, bis die Frage kommt, zu der zurückgesprungen wurde (vorbelegt).
    func resolve(_ questions: [PreRunQuestion]) async -> [String: String]? {
        var out: [String: String] = [:]
        for q in questions {
            if let p = q.preset { out[q.key] = p; continue }
            let ans: LoggedAnswer
            if let r = replay.first, r.key == q.key, r.answer != "", q.options.contains(where: { $0.id == r.answer }) {
                replay.removeFirst()
                ans = r
            } else {
                replay = []
                let pre = prefillNext?.key == q.key ? prefillNext : nil
                prefillNext = nil
                lastFieldAnswers = [:]
                let canBack = !answerLog.isEmpty && !hasOps && !executionConfirmed
                let a: (String, Bool)? = await withCheckedContinuation { c in
                    let r = QuestionRequest(title: q.title, message: q.message, icon: q.icon, options: q.options,
                                            fields: q.fields, continuation: c)
                    r.example = q.example; r.recommended = q.recommended; r.reason = q.reason
                    r.tree = q.tree; r.rememberLabel = q.rememberLabel; r.canGoBack = canBack
                    if let pre, q.options.contains(where: { $0.id == pre.answer }) {
                        r.prefill = pre.answer; r.prefillFields = pre.fields; r.prefillRemember = pre.remember
                    }
                    pendingQuestion = r
                }
                guard let a, !Task.isCancelled else {
                    if !backRequested { cancelledInQuestion = true }
                    return nil
                }
                var f: [String: String] = [:]
                for fl in q.fields { f[fl.id] = lastFieldAnswers[fl.id] ?? fl.value }
                ans = LoggedAnswer(key: q.key, answer: a.0, fields: f, remember: a.1)
            }
            answerLog.append(ans)
            if ans.remember {
                if executionConfirmed { q.remember(ans.answer) } else { pendingRemembers.append((apply: q.remember, value: ans.answer)) }
            }
            out[q.key] = ans.answer
            for fl in q.fields { out[q.key + "." + fl.id] = ans.fields[fl.id] ?? fl.value }
        }
        return out
    }

    /// Frage „Auch nach Datum sortieren?“ – nur relevant, wenn die Clips von mehreren Tagen stammen.
    /// existing: vorhandene Tagesordner-Struktur ("top"/"under") → gleiche Struktur weiterführen, nicht fragen.
    func dateQuestion(starts: [Date], existing: String?, example: (top: String, under: String), sample: String? = nil) -> PreRunQuestion? {
        if let e = existing {
            return PreRunQuestion(key: "date", title: "", message: "", icon: "", options: [], preset: e, remember: { _ in })
        }
        let days = Array(Set(starts.map { store.dayString($0) })).sorted()
        guard days.count > 1 else { return nil }
        let preset: String? = store.dateMode == "ask" ? nil : store.dateMode
        let df = DateFormatter(); df.dateFormat = "dd.MM."
        let shown = Array(Set(starts.map { store.nightToPrevDay ? $0.addingTimeInterval(-4 * 3600) : $0 }
            .map { Calendar.current.startOfDay(for: $0) })).sorted().map { df.string(from: $0) }
        let list = shown.count > 6 ? shown.prefix(5).joined(separator: ", ") + " …" : shown.joined(separator: ", ")
        return PreRunQuestion(
            key: "date", title: "Auch nach Datum sortieren?",
            message: "Die Aufnahmen stammen von \(days.count) Tagen (\(list)).",
            icon: "calendar",
            options: [QuestionOption(id: "top", label: "Ja, Tagesordner oben", detail: example.top),
                      QuestionOption(id: "under", label: "Ja, Tagesordner unter der Kamera", detail: example.under),
                      QuestionOption(id: "off", label: "Nein", detail: "Alle Tage zusammen")],
            preset: preset, remember: { [weak self] a in self?.store.dateMode = a },
            example: sample, recommended: "under",
            reason: "Clips von \(days.count) Tagen – so bleibt die Kamera oben und jeder Tag ist schnell gefunden.")
    }

    func answerDuplicate(_ choice: DupChoice, forAll: Bool) {
        guard let p = pendingDuplicate else { return }
        pendingDuplicate = nil
        p.continuation.resume(returning: (choice, forAll))
    }

    func answerCamera(_ name: String?, remember: Bool) {
        guard let p = pendingCamera else { return }
        pendingCamera = nil
        let clean = name.map { Self.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
        if let c = clean, remember {
            let st = store, sig = p.signature, lab = p.signatureLabel
            if executionConfirmed { st.learn(signature: sig, label: lab, camera: c) }
            else { pendingLearn.append { st.learn(signature: sig, label: lab, camera: c) } }
        }
        p.continuation.resume(returning: clean)
    }

    /// Nicht mehr nachfragen – Rest nach bisherigem Wissen sortieren.
    func skipLearning() {
        skipAsking = true
        if let p = pendingCamera {
            pendingCamera = nil
            p.continuation.resume(returning: p.suggestion.isEmpty ? nil : p.suggestion)
        }
    }

    func answerExtensions(_ map: [String: FileCategory]?, remember: Bool) {
        guard let p = pendingExtensions else { return }
        pendingExtensions = nil
        if let m = map, remember {
            let st = store
            if executionConfirmed { for (e, c) in m { st.learnExtension(e, as: c) } }
            else { pendingLearn.append { for (e, c) in m { st.learnExtension(e, as: c) } } }
        }
        p.continuation.resume(returning: map)
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting(folders) }

    // MARK: Kategorien

    private func category(for ext: String) -> FileCategory? {
        if let learned = store.extensions[ext] { return learned }
        if Self.videoExt.contains(ext) { return .video }
        if Self.photoExt.contains(ext) { return .photo }
        if Self.musicExt.contains(ext) { return .music }
        if Self.archiveExt.contains(ext) { return .archive }
        if Self.projectExt.contains(ext) { return .project }
        if Self.sideExt.contains(ext) { return .side }
        if Self.alwaysIgnore.contains(ext) || ext.isEmpty { return .ignore }
        return nil
    }

    /// Ordnernamen, die CamSort selbst anlegt – dort wird nicht erneut sortiert.
    private var outputNames: Set<String> {
        var s = Self.fixedOutput
        for e in Self.sideExt { s.insert(e.uppercased()) }
        for (e, c) in store.extensions where c == .side { s.insert(e.uppercased()) }
        return s
    }

    // MARK: Einlesen

    private func collect(_ base: URL) -> [(dir: URL, url: URL, ext: String)]? {
        var out: [(dir: URL, url: URL, ext: String)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        let outNames = outputNames

        func consider(_ u: URL) -> Bool {   // true = Ordner weiter durchsuchen
            let v = try? u.resourceValues(forKeys: Set(keys))
            let ext = u.pathExtension.lowercased()
            if v?.isDirectory == true {
                if Self.projectExt.contains(ext) || v?.isPackage == true {
                    if Self.projectExt.contains(ext) && !FCPLibraryBuilder.isOwnOutput(u) { out.append((u.deletingLastPathComponent(), u, ext)) }
                    return false
                }
                // Schon Einsortiertes (unter „Videos“) wird nicht neu eingelesen – „Neu ordnen“ holt es bei Bedarf gezielt (layoutCompact)
                if cfg.compactLayout && FolderNames.isVideos(u.lastPathComponent) { return false }
                // ohne Videos-Sammelordner sortierte Ebenen (Dreh/Kamera/Quer …) nicht erneut einlesen → zweiter Lauf verschiebt nichts
                if cfg.compactLayout && Self.isSortedTree(u) { return false }
                return !outNames.contains(u.lastPathComponent)
            }
            if v?.isRegularFile == true { out.append((u.deletingLastPathComponent(), u, ext)) }
            return false
        }

        if cfg.includeSubfolders {
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
            while let u = en.nextObject() as? URL {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let descend = consider(u)
                if isDir && !descend { en.skipDescendants() }
            }
        } else {
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return nil }
            for u in items { _ = consider(u) }
        }
        return out
    }

    // MARK: Ablauf

    private func run() async {
        var found: [(dir: URL, url: URL, ext: String)] = []
        for base in folders {
            guard let items = collect(base) else {
                problems.append("\(base.lastPathComponent): kein Zugriff auf den Ordner – bitte unter Systemeinstellungen › Datenschutz & Sicherheit erlauben")
                continue
            }
            found += items
        }
        var siblings: [URL: Set<String>] = [:]
        for f in found { siblings[f.dir, default: []].insert(f.url.lastPathComponent) }
        fcpLibraries = found.filter { $0.ext == "fcpbundle" }.map(\.url) + FCPLibraryBuilder.ownLibraries(in: folders)   // eigene Mediathek (CamSort) mit Neu-Verknüpfen-Hinweis

        // Unbekannte Dateitypen erfragen
        var unknown: [String: (example: String, count: Int)] = [:]
        for f in found where category(for: f.ext) == nil {
            let cur = unknown[f.ext]
            unknown[f.ext] = (cur?.example ?? f.url.lastPathComponent, (cur?.count ?? 0) + 1)
        }
        guard let sessionExt = await askUnknown(unknown) else { phase = .cancelled; return }

        var videos: [Job] = [], others: [Job] = []
        for f in found {
            let cat = category(for: f.ext) ?? sessionExt[f.ext] ?? .ignore
            let job = Job(dir: f.dir, url: f.url, cat: cat, ext: f.ext)
            switch cat {
            case .video: videos.append(job)
            case .ignore: if !Self.alwaysIgnore.contains(f.ext) { ignored += 1 }
            default: others.append(job)
            }
        }

        if cfg.compactLayout {
            total = videos.count + others.count
            phase = .sorting
            // Ziele der übrigen Dateien vorab berechnen (für die Übersicht vor dem ersten Verschieben)
            var oPlan: [(url: URL, target: URL, counter: MoveCounter)] = []
            for job in others where fm.fileExists(atPath: job.url.path) {
                let dreh = Self.drehRoot(job.dir)
                switch job.cat {
                case .side: oPlan.append((job.url, dreh.appendingPathComponent(FolderNames.side), .side(job.ext.uppercased())))
                case .photo: oPlan.append((job.url, dreh.appendingPathComponent(FolderNames.photos), .photo))
                case .music, .archive, .project:
                    let folder = job.cat.folder ?? "Sonstiges"
                    oPlan.append((job.url, dreh.appendingPathComponent(FolderNames.extras).appendingPathComponent(folder), .side(folder)))
                default: break
                }
            }
            guard await layoutCompact(videos, siblings: siblings, extra: oPlan.map { ($0.url, $0.target) }) else { phase = .cancelled; return }
            for o in oPlan {
                if Task.isCancelled || safetyStop { phase = .cancelled; return }
                currentFile = o.url.lastPathComponent
                if fm.fileExists(atPath: o.url.path), await move(o.url, to: o.target) { tally(o.counter) }
                processed += 1
            }
            currentFile = ""
            return
        }

        let jobs = videos + others
        total = jobs.count
        phase = .sorting

        // Phase 1: Ziele berechnen (Kameras sind schon vorab erfragt) – noch nichts verschieben
        var plan: [(url: URL, target: URL, counter: MoveCounter)] = []
        for job in jobs {
            if Task.isCancelled { phase = .cancelled; return }
            currentFile = job.url.lastPathComponent
            guard fm.fileExists(atPath: job.url.path) else { continue }

            switch job.cat {
            case .video:
                let asset = AVURLAsset(url: job.url)
                let o = await orientation(of: asset)
                guard let cam = await camera(for: job.url, asset: asset, siblings: siblings[job.dir] ?? []) else {
                    phase = .cancelled; return
                }
                if cam.hasPrefix(LearnedStore.folderPrefix) {
                    let f = String(cam.dropFirst(LearnedStore.folderPrefix.count))
                    plan.append((job.url, job.dir.appendingPathComponent(f), .side(f)))
                    continue
                }
                var target = job.dir.appendingPathComponent("Videos").appendingPathComponent(cam)
                if cfg.sortByLens {
                    if let lens = await lensName(for: job.url, asset: asset, siblings: siblings[job.dir] ?? []) {
                        target = target.appendingPathComponent(lens)
                        lenses[lens, default: 0] += 1
                    } else {
                        target = target.appendingPathComponent("Objektiv unbekannt")
                        lenses["Objektiv unbekannt", default: 0] += 1
                    }
                }
                if cfg.droneBySpeed {
                    let stem = job.url.deletingPathExtension().lastPathComponent
                    let srt = [stem + ".SRT", stem + ".srt"].first { (siblings[job.dir] ?? []).contains($0) }
                    if let srt {
                        switch SRTSpeed.analyze(job.dir.appendingPathComponent(srt)) {
                        case .speed(let kmh):
                            let folder: String
                            if kmh >= cfg.standMin && kmh <= cfg.standMax { folder = "Stand" }
                            else if kmh >= cfg.moveMin && kmh <= cfg.moveMax { folder = "Fahrt" }
                            else { folder = "Dazwischen" }
                            target = target.appendingPathComponent(folder)
                            speeds[folder, default: 0] += 1
                            hints.append(String(format: "%@: Ø %.1f km/h → %@", job.url.lastPathComponent, kmh, folder))
                        case .noGPS:
                            target = target.appendingPathComponent("Ohne GPS")
                            speeds["Ohne GPS", default: 0] += 1
                            hints.append("\(job.url.lastPathComponent): SRT enthält keine GPS-Position – Geschwindigkeit nicht berechenbar → Ohne GPS")
                        case .unreadable:
                            hints.append("\(job.url.lastPathComponent): SRT-Datei nicht lesbar")
                        }
                    }
                }
                if let o { target = target.appendingPathComponent(o) }
                else { hints.append("\(job.url.lastPathComponent): Ausrichtung nicht lesbar – liegt direkt in Videos/\(cam)") }
                plan.append((job.url, target, .video(o, cam)))
            case .side:
                let key = job.ext.uppercased()
                plan.append((job.url, job.dir.appendingPathComponent(key), .side(key)))
            case .photo:
                plan.append((job.url, job.dir.appendingPathComponent("Fotos"), .photo))
            case .music, .archive, .project:
                let folder = job.cat.folder ?? "Sonstiges"
                plan.append((job.url, job.dir.appendingPathComponent(folder), .side(folder)))
            case .ignore: break
            }
        }
        currentFile = ""
        // Phase 2: Übersicht, dann verschieben
        guard await confirmOverview(plan.map { ($0.url, $0.target) }) else { phase = .cancelled; return }
        total = plan.count; processed = 0
        for st in plan {
            if Task.isCancelled || safetyStop { phase = .cancelled; return }
            currentFile = st.url.lastPathComponent
            if fm.fileExists(atPath: st.url.path), await move(st.url, to: st.target) { tally(st.counter) }
            processed += 1
        }
        currentFile = ""
    }

    /// Unbekannte Dateitypen einmal abfragen. nil = abgebrochen.
    private func askUnknown(_ unknown: [String: (example: String, count: Int)]) async -> [String: FileCategory]? {
        let rest = unknown.filter { sessionExt[$0.key] == nil }   // in der Fragenrunde schon beantwortet → nicht erneut fragen
        guard !rest.isEmpty else { return sessionExt }
        let list = rest.map { (ext: $0.key, example: $0.value.example, count: $0.value.count) }.sorted { $0.ext < $1.ext }
        let answer: [String: FileCategory]? = await withCheckedContinuation { c in
            pendingExtensions = ExtensionRequest(extensions: list, continuation: c)
        }
        if Task.isCancelled { return nil }
        for (k, v) in answer ?? [:] { sessionExt[k] = v }
        return sessionExt
    }

    // MARK: Kompakte Struktur

    static let cardMarkers: Set<String> = ["DCIM", "PRIVATE", "M4ROOT", "CLIP", "AVCHD", "MP_ROOT", "100MEDIA", "101MEDIA"]

    /// Dreh-Ordner: über „Videos“ bzw. über Kartenordnern (DCIM, PRIVATE …), sonst der Ordner selbst.
    static func drehRoot(_ dir: URL) -> URL {
        let c = dir.pathComponents
        var root = dir
        if let i = c.firstIndex(where: FolderNames.isVideos) { root = URL(fileURLWithPath: NSString.path(withComponents: Array(c[..<i]))) }
        else if let i = c.firstIndex(where: { cardMarkers.contains($0.uppercased()) }) {
            root = URL(fileURLWithPath: NSString.path(withComponents: Array(c[..<i])))
        } else {
            // Clips lose in einem Kameraordner (z. B. „Pitbike/E1/C0001.MP4“ neben „A1“, „Avata“) → Dreh = Elternordner
            return cameraParent(dir) ?? dir
        }
        // Ordner, der nur eine Kartenkopie enthält (z. B. „Karte A/PRIVATE“) → der Dreh ist eine Ebene höher.
        // Lose Nicht-Mediendateien der Karte (z. B. SONYCARD.IND, Thumbs.db) zählen nicht als eigener Inhalt.
        let inside = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
        let hasCard = inside.contains { cardish.contains($0.uppercased()) }
        let onlyCardOrOutput = inside.allSatisfy { n in
            if cardish.contains(n.uppercased()) || fixedOutput.contains(n) { return true }
            let ext = (n as NSString).pathExtension.lowercased()
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: root.appendingPathComponent(n).path, isDirectory: &isDir)
            return !isDir.boolValue && !videoExt.contains(ext) && !photoExt.contains(ext)
        }
        let isProject = FileManager.default.fileExists(atPath: root.appendingPathComponent(projectMarker).path)
        if hasCard && onlyCardOrOutput && !isProject { root = root.deletingLastPathComponent() }
        else if !isProject, let p = cameraParent(root) { root = p }
        return root
    }

    /// Die in diesem Lauf gewählten Ordner (Standard-Pfade) – drehRoot steigt nie über sie hinaus.
    static var selectedBases: Set<String> = []

    /// Ist `dir` ein Kameraordner (wie „E1“ neben „A1“, „Avata“) innerhalb eines gewählten Ordners? Dann ist der Elternordner der Dreh.
    static func cameraParent(_ dir: URL) -> URL? {
        let me = dir.standardizedFileURL.path
        let parent = dir.deletingLastPathComponent()
        let pp = parent.standardizedFileURL.path
        guard !selectedBases.contains(me),
              selectedBases.contains(where: { pp == $0 || pp.hasPrefix($0 + "/") }),
              !FileManager.default.fileExists(atPath: dir.appendingPathComponent(projectMarker).path),
              isCameraLikeFolder(dir) else { return nil }
        let sibs = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != dir.lastPathComponent }
        return sibs.contains(where: { isCameraLikeFolder(parent.appendingPathComponent($0)) }) ? parent : nil
    }

    /// Sieht aus wie EINE Kamera: Videos (eine Dateinamen-Familie) oder Kartenstruktur direkt darin,
    /// keine eigenen Unterordner außer Karten-/CamSort-Ordnern, nichts schon Sortiertes.
    static func isCameraLikeFolder(_ u: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let name = u.lastPathComponent
        if fixedOutput.contains(name) || cardish.contains(name.uppercased()) || FolderNames.isVideos(name)
            || projectExt.contains(u.pathExtension.lowercased()) || isSortedTree(u) { return false }
        let kids = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { !$0.hasPrefix(".") }
        var media = false
        var families = Set<String>()
        for k in kids {
            let ku = u.appendingPathComponent(k)
            let ext = ku.pathExtension.lowercased()
            var d: ObjCBool = false
            _ = fm.fileExists(atPath: ku.path, isDirectory: &d)
            if d.boolValue && !projectExt.contains(ext) {
                if cardish.contains(k.uppercased()) { media = true; continue }
                if fixedOutput.contains(k) { continue }
                return false   // eigener Unterordner → eher ein Dreh oder Projekt als eine Kamera
            }
            if videoExt.contains(ext) { media = true; families.insert(LearnedStore.prefix(of: k)) }
        }
        return media && families.count <= 1
    }

    /// Von CamSort ohne Videos-Sammelordner angelegter Ebenen-Ordner? (enthält Ausrichtungs-, FPS- oder Szenen-Ordner,
    /// bzw. heißt selbst so – auch zusammengesetzt wie „Sony · Quer“), keine Kartenstruktur.
    static func isSortedTree(_ u: URL, depth: Int = 6) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let name = u.lastPathComponent
        if cardish.contains(name.uppercased()) || FolderNames.isVideos(name) { return false }
        if FolderNames.hasOrientationPart(name) || FolderNames.hasFpsPart(name) || FolderNames.isSceneFolder(name) { return true }
        guard depth > 0 else { return false }
        let kids = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { !$0.hasPrefix(".") }
        if kids.contains(where: { cardish.contains($0.uppercased()) }) { return false }
        return kids.contains { isSortedTree(u.appendingPathComponent($0), depth: depth - 1) }
    }

    /// Wurzel der Video-Ebenen eines Drehs: „Dreh/Videos“ oder – Videos-Sammelordner aus – der Dreh selbst.
    /// Bestehende Drehs werden nie umgebaut: vorhandener Videos-Ordner bleibt in Gebrauch, ebenso eine vorhandene Struktur ohne.
    func videosRoot(_ dreh: URL) -> URL {
        let key = dreh.standardizedFileURL.path
        if let c = videosRootCache[key] { return c }
        let withVideos = dreh.appendingPathComponent(FolderNames.videos)
        let kids = ((try? fm.contentsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.hasPrefix(".") }
        let r: URL
        if kids.contains(where: FolderNames.isVideos) { r = withVideos }
        else if !FolderNames.useVideosFolder {
            // ohne Ausrichtung/FPS/Szene wäre beim nächsten Lauf nicht erkennbar, was schon sortiert ist
            let recognizable = cfg.levels.contains { ["orientation", "fps", "scene"].contains($0) }
            if recognizable { r = dreh }
            else {
                r = withVideos
                if !hints.contains(where: { $0.hasPrefix("Videos-Sammelordner trotzdem") }) {
                    hints.append("Videos-Sammelordner trotzdem angelegt: Ohne Ebene Ausrichtung, Framerate oder Szene wäre beim nächsten Lauf nicht erkennbar, was schon sortiert ist.")
                }
            }
        }
        else if kids.contains(where: { Self.isSortedTree(dreh.appendingPathComponent($0)) }) { r = dreh }
        else { r = withVideos }
        videosRootCache[key] = r
        return r
    }

    private func sidecar(_ stem: String, exts: [String], near dir: URL) -> URL? {
        let dreh = Self.drehRoot(dir)
        let dirs = [dir, dreh.appendingPathComponent(FolderNames.side), dreh.appendingPathComponent("Begleitdateien"), dreh.appendingPathComponent("SRT"), dreh.appendingPathComponent("XML")]
        for d in dirs { for e in exts {
            let u = d.appendingPathComponent(stem + e)
            if fm.fileExists(atPath: u.path) { return u }
        } }
        return nil
    }

    /// Ein analysierter Clip der kompakten Struktur. old = lag schon einsortiert (für „Neu ordnen“), sub = Stabilisiert/Original
    private struct CInfo {
        let job: Job; let cam: String; let lens: String?; let speed: String?; let orient: String?; let fps: String; let start: Date; let end: Date
        var old = false
        var sub: String? = nil
    }

    /// Analysiert einen Clip. fixedCam: Kamera schon bekannt (aus dem bisherigen Ordner) – dann keine Rückfrage. nil = abgebrochen.
    private func analyzeClip(_ job: Job, siblings: Set<String>, fixedCam: String?) async -> CInfo? {
        let asset = AVURLAsset(url: job.url)
        let props = await videoProps(of: asset)
        var sib = siblings
        let stem = job.url.deletingPathExtension().lastPathComponent
        if let x = sidecar(stem, exts: ["M01.XML", "M01.xml"], near: job.dir) { sib.insert(x.lastPathComponent) }
        let cam: String
        if let f = fixedCam { cam = f }
        else {
            guard let c = await camera(for: job.url, asset: asset, siblings: sib) else { return nil }
            cam = c
        }
        var lens: String? = nil
        if cfg.levels.contains("lens") { lens = await lensName(for: job.url, asset: asset, siblings: sib) ?? "Objektiv unbekannt" }
        var speed: String? = nil
        if cfg.levels.contains("speed"), let srt = sidecar(stem, exts: [".SRT", ".srt"], near: job.dir) {
            switch SRTSpeed.analyze(srt) {
            case .speed(let kmh):
                let sp = kmh >= cfg.standMin && kmh <= cfg.standMax ? "Stand"
                       : kmh >= cfg.moveMin && kmh <= cfg.moveMax ? "Fahrt" : "Dazwischen"
                speed = sp
                if fixedCam == nil { hints.append(String(format: "%@: Ø %.1f km/h → %@", job.url.lastPathComponent, kmh, sp)) }
            case .noGPS: speed = "Ohne GPS"
            case .unreadable: break
            }
        }
        let (st, en) = await recordingTime(asset, url: job.url)
        let fps = cam.hasPrefix(LearnedStore.folderPrefix) ? "" : fpsFolder(for: job.url, nominal: props.nominalFps)
        noteStart(st, for: job.url)
        return CInfo(job: job, cam: cam, lens: lens, speed: speed, orient: props.orient, fps: fps, start: st, end: en)
    }

    /// Kamera eines schon einsortierten Clips ohne Rückfrage: gelernte Regel bzw. erkannter Name, sonst „Unbekannt“
    private func quietCamera(_ url: URL, siblings: Set<String>) async -> String {
        let det = await detect(url: url, asset: AVURLAsset(url: url), siblings: siblings)
        return store.camera(for: det.signature) ?? det.name ?? "Unbekannt"
    }

    // MARK: Layout-Datei & Neu ordnen

    static let layoutMarker = ".camsort-layout"

    /// Welche Einstellungen haben die Struktur eines Drehs bestimmt? (unsichtbare Datei im Dreh-Ordner)
    struct LayoutSig: Codable, Equatable {
        var version: Int
        var useVideos: Bool
        var videosName: String
        var levels: [String]          // tatsächlich benutzte Ebenen (inkl. Rückfrage-Ergebnis Datum/FPS)
        var configLevels: [String]    // Ebenen laut Einstellungen
        var nest: Bool
        var separator: String
        var declined: String?         // „So lassen“ für genau diese Einstellungen → nicht erneut fragen
        var key: String { "\(useVideos)|\(videosName)|\(configLevels.joined(separator: ","))|\(nest)|\(separator)" }
    }

    /// Ohne Ausrichtung/FPS/Szene in den Ebenen bleibt der Videos-Ordner (sonst wäre Sortiertes nicht erkennbar)
    private var levelsRecognizable: Bool { cfg.levels.contains { ["orientation", "fps", "scene"].contains($0) } }
    private var wantsVideosFolder: Bool { FolderNames.useVideosFolder || !levelsRecognizable }
    private var currentKey: String {
        LayoutSig(version: 1, useVideos: wantsVideosFolder, videosName: FolderNames.videos, levels: [], configLevels: cfg.levels,
                  nest: cfg.nestLevels, separator: FolderNames.separator, declined: nil).key
    }

    func readLayout(_ dreh: URL) -> LayoutSig? {
        guard let d = try? Data(contentsOf: dreh.appendingPathComponent(Self.layoutMarker)) else { return nil }
        return try? JSONDecoder().decode(LayoutSig.self, from: d)
    }

    private func writeLayout(_ sig: LayoutSig, to dreh: URL) {
        guard let d = try? JSONEncoder().encode(sig) else { return }
        _ = writeLogged(d, to: dreh.appendingPathComponent(Self.layoutMarker))
    }

    /// CamSorts unsichtbare Markierungsdateien schreiben – mit Protokoll (vorheriger Inhalt für Rückgängig). Gleicher Inhalt → nichts tun.
    private func writeLogged(_ data: Data, to u: URL) -> Bool {
        let prev = try? Data(contentsOf: u)
        if prev == data { return true }
        let n = j.plan("markierung", u, nil, data: prev?.base64EncodedString())
        do { try data.write(to: u, options: .atomic); j.done(n); return true }
        catch { j.fail(n, error.localizedDescription); return false }
    }

    /// Schon einsortierte Clips eines Drehs (unter Videos bzw. in den Ebenen-Ordnern), inkl. Stabilisiert/Original
    private func sortedClips(in dreh: URL) -> [(url: URL, dir: URL, sub: String?)] {
        let kids = ((try? fm.contentsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.hasPrefix(".") }
        let roots = kids.filter(FolderNames.isVideos).map { dreh.appendingPathComponent($0) }
        let tops = roots.isEmpty ? kids.map { dreh.appendingPathComponent($0) }.filter { Self.isSortedTree($0) } : roots
        var out: [(url: URL, dir: URL, sub: String?)] = []
        for r in tops {
            guard let en = fm.enumerator(at: r, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                guard Self.videoExt.contains(u.pathExtension.lowercased()) else { continue }
                let parent = u.deletingLastPathComponent()
                let pn = parent.lastPathComponent
                if pn == "Gyroflow-Projekte" { continue }
                if pn == "Stabilisiert" || pn == "Original" { out.append((u, parent.deletingLastPathComponent(), pn)) }
                else { out.append((u, parent, nil)) }
            }
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    /// Kamera aus dem bisherigen Ordnerpfad (nicht neu abfragen). nil = nicht sicher ableitbar.
    private func oldCamera(_ dir: URL, dreh: URL, sig: LayoutSig?) -> String? {
        let dc = dir.standardizedFileURL.pathComponents
        var rc = dreh.standardizedFileURL.pathComponents
        if dc.count > rc.count, FolderNames.isVideos(dc[rc.count]) { rc.append(dc[rc.count]) }
        guard dc.count > rc.count, Array(dc.prefix(rc.count)) == rc else { return nil }
        let rel = Array(dc.dropFirst(rc.count))
        let sep = sig?.separator ?? FolderNames.separator
        let nested = sig?.nest ?? (rel.count > 1)
        let parts = nested ? rel : rel[0].components(separatedBy: sep)
        if let s = sig {
            guard let ci = s.levels.firstIndex(of: "camera"), ci < parts.count else { return nil }
            let optionalBefore = s.levels[..<ci].contains { ["scene", "speed", "orientation", "fps"].contains($0) }
            return (!optionalBefore || parts.count == s.levels.count) ? parts[ci] : nil
        }
        if parts.contains(where: FolderNames.isSceneFolder) { return nil }
        let levelWords: Set<String> = ["Stand", "Fahrt", "Dazwischen", "Ohne GPS", "Objektiv unbekannt", cfg.lengthShort, cfg.lengthLong]
        return parts.first { p in
            !(FolderNames.isOrientation(p) || FolderNames.isFpsFolder(p) || store.isDayFolder(p) || levelWords.contains(p)
              || p.range(of: #"^\d{2}\.\d{2}$"#, options: .regularExpression) != nil)
        }
    }

    /// Gyroflow-Projekte eines verschobenen Clips mitnehmen (gleicher Dateiname vorne), damit Gyroflow sie wiederfindet
    private func moveGyroCompanions(stem: String, from dir: URL, to target: URL) async {
        let g = dir.appendingPathComponent("Gyroflow-Projekte")
        guard let items = try? fm.contentsOfDirectory(atPath: g.path) else { return }
        for n in items where n.lowercased().hasPrefix(stem.lowercased()) && n.lowercased().hasSuffix(".gyroflow") {
            _ = await move(g.appendingPathComponent(n), to: target.appendingPathComponent("Gyroflow-Projekte"))
        }
    }

    /// Analysiert alle Videos je Dreh und legt nur die Ordner an, die sich dort unterscheiden.
    private func layoutCompact(_ videos: [Job], siblings: [URL: Set<String>], extra: [(URL, URL)] = []) async -> Bool {
        var lv = cfg.levels
        var infos: [CInfo] = []
        for job in videos {
            if Task.isCancelled { return false }
            currentFile = job.url.lastPathComponent
            guard let i = await analyzeClip(job, siblings: siblings[job.dir] ?? [], fixedCam: nil) else { return false }
            infos.append(i)
        }

        // Schon sortierte Drehs: mit anderen Einstellungen sortiert? → fragen, ob neu geordnet werden soll
        var check = Set(infos.map { Self.drehRoot($0.job.dir) })
        for b in folders {
            if Self.looksSorted(b) { check.insert(b) }
            for k in ((try? fm.contentsOfDirectory(atPath: b.path)) ?? []) where !k.hasPrefix(".") {
                let u = b.appendingPathComponent(k)
                if fm.fileExists(atPath: u.appendingPathComponent(Self.projectMarker).path) && Self.looksSorted(u) { check.insert(u) }
            }
        }
        let curKey = currentKey
        var reorder: [URL] = []       // Drehs, die neu geordnet werden
        var declined: [URL] = []      // Drehs, bei denen Tim „So lassen“ gewählt hat
        var oldInfos: [CInfo] = []
        let candidates = check.filter { d in
            guard Self.looksSorted(d) else { return false }
            guard let s = readLayout(d) else { return true }
            return s.key != curKey && s.declined != curKey
        }.sorted { $0.path < $1.path }
        var oldTops: [URL] = []       // bisherige Ebenen-Ordner (ohne Videos) – nach dem Neu-Ordnen leere entfernen
        for d in candidates {
            let sig = readLayout(d)
            for k in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []) where !k.hasPrefix(".") && Self.isSortedTree(d.appendingPathComponent(k)) {
                oldTops.append(d.appendingPathComponent(k))
            }
            for c in sortedClips(in: d) {
                if Task.isCancelled { return false }
                currentFile = c.url.lastPathComponent
                let sib = Set((try? fm.contentsOfDirectory(atPath: c.dir.path)) ?? [])
                var cam = oldCamera(c.dir, dreh: d, sig: sig)
                if cam == nil { cam = await quietCamera(c.url, siblings: sib) }
                let job = Job(dir: c.dir, url: c.url, cat: .video, ext: c.url.pathExtension.lowercased())
                guard var i = await analyzeClip(job, siblings: sib, fixedCam: cam) else { return false }
                i.old = true; i.sub = c.sub
                oldInfos.append(i)
            }
        }

        let tf = DateFormatter(); tf.dateFormat = "HH.mm"
        func pk(_ u: URL) -> String { u.standardizedFileURL.path }
        /// Dreh eines Clips: schon sortierte Clips gehören zum (tiefsten) geprüften Dreh, neue über drehRoot
        func drehOf(_ i: CInfo) -> URL {
            if i.old, let d = candidates.filter({ pk(i.job.url).hasPrefix(pk($0) + "/") }).max(by: { pk($0).count < pk($1).count }) { return d }
            return Self.drehRoot(i.job.dir)
        }
        /// Zielordner je Clip (ohne Stabilisiert/Original-Unterordner) – gleiche Regeln für neue und schon sortierte Clips
        func plan(_ list: [CInfo], levels lv: [String], root: (URL) -> URL) -> [(info: CInfo, dreh: URL, target: URL)] {
            var drehURL: [String: URL] = [:]
            var byDreh: [String: [CInfo]] = [:]
            for i in list {
                let d = drehOf(i)
                if drehURL[pk(d)] == nil { drehURL[pk(d)] = d }
                byDreh[pk(d), default: []].append(i)
            }
            var out: [(info: CInfo, dreh: URL, target: URL)] = []
            for (dk, items) in byDreh.sorted(by: { $0.key < $1.key }) {
                guard let dreh = drehURL[dk] else { continue }
                // Szenen: chronologisch, neue Szene nach einer Pause > Schwelle (über alle Kameras hinweg)
                var sceneOf: [URL: String] = [:]
                if lv.contains("scene") {
                    let cams = items.filter { !$0.cam.hasPrefix(LearnedStore.folderPrefix) }.sorted { $0.start < $1.start }
                    var scenes: [[CInfo]] = []
                    var lastEnd = Date.distantPast
                    for c in cams {
                        if scenes.isEmpty || c.start.timeIntervalSince(lastEnd) > cfg.sceneGapMinutes * 60 { scenes.append([c]) }
                        else { scenes[scenes.count - 1].append(c) }
                        lastEnd = max(lastEnd, c.end)
                    }
                    for (n, sc) in scenes.enumerated() {
                        var camNames: [String] = []
                        for c in sc where !camNames.contains(c.cam) { camNames.append(c.cam) }
                        var nameParts = [String(format: "%@ %02d", FolderNames.sceneWord, n + 1)]
                        if FolderNames.sceneShowTime { nameParts.append(tf.string(from: sc[0].start)) }
                        if FolderNames.sceneShowCams { nameParts.append(camNames.joined(separator: " + ")) }
                        let name = nameParts.joined(separator: FolderNames.separator)
                        for c in sc { sceneOf[c.job.url] = Self.clean(name) }
                    }
                }
                for i in items {
                    let dur = i.end.timeIntervalSince(i.start)
                    var parts: [String] = []
                    for l in lv {
                        switch l {
                        case "scene": if let s = sceneOf[i.job.url] { parts.append(s) }
                        case "camera": parts.append(i.cam)
                        case "lens": if let x = i.lens { parts.append(x) }
                        case "length": parts.append(dur < cfg.lengthThreshold ? cfg.lengthShort : cfg.lengthLong)
                        case "orientation": if let o = i.orient { parts.append(o) }
                        case "speed": if let s = i.speed { parts.append(s) }
                        case "date": parts.append(store.dayString(i.start))
                        case "fps": if !i.fps.isEmpty { parts.append(i.fps) }
                        default: break
                        }
                    }
                    var target = root(dreh)
                    if cfg.nestLevels {
                        for p in parts { target = target.appendingPathComponent(Self.clean(p)) }
                    } else if !parts.isEmpty {
                        target = target.appendingPathComponent(Self.clean(parts.joined(separator: FolderNames.separator)))
                    }
                    if i.cam.hasPrefix(LearnedStore.folderPrefix) {   // eigener Ordner (Exporte, Bildschirmaufnahmen …)
                        target = dreh.appendingPathComponent(FolderNames.extras).appendingPathComponent(String(i.cam.dropFirst(LearnedStore.folderPrefix.count)))
                    }
                    out.append((info: i, dreh: dreh, target: target))
                }
            }
            return out
        }
        func finalDir(_ p: (info: CInfo, dreh: URL, target: URL)) -> URL {
            p.info.sub.map { p.target.appendingPathComponent($0) } ?? p.target
        }
        func here(_ i: CInfo) -> String { i.job.url.deletingLastPathComponent().standardizedFileURL.path }

        if !oldInfos.isEmpty {
            let wantV = wantsVideosFolder
            let newRoot: (URL) -> URL = { d in wantV ? d.appendingPathComponent(FolderNames.videos) : d }
            let preview = plan(oldInfos, levels: cfg.levels, root: newRoot)
            let changed = preview.filter { here($0.info) != finalDir($0).standardizedFileURL.path }
            var changedDrehs: [URL] = []
            for c in changed where !changedDrehs.contains(where: { pk($0) == pk(c.dreh) }) { changedDrehs.append(c.dreh) }
            // Struktur passt schon zu den Einstellungen → nur Layout-Datei schreiben, nicht fragen
            for d in candidates where !changedDrehs.contains(where: { pk($0) == pk(d) }) {
                layoutWrites.append((LayoutSig(version: 1, useVideos: videosRoot(d).standardizedFileURL.path != d.standardizedFileURL.path,
                                      videosName: FolderNames.videos, levels: cfg.levels, configLevels: cfg.levels,
                                      nest: cfg.nestLevels, separator: FolderNames.separator, declined: nil), d))
            }
            if !changed.isEmpty {
                func rel(_ u: URL, _ d: URL) -> String { String(u.standardizedFileURL.path.dropFirst(d.standardizedFileURL.path.count + 1)) }
                let ex = changed.prefix(2).map { "\(rel($0.info.job.url, $0.dreh))  →  \(rel(finalDir($0).appendingPathComponent($0.info.job.url.lastPathComponent), $0.dreh))" }
                let names = changedDrehs.map(\.lastPathComponent).sorted().joined(separator: ", ")
                let known = changedDrehs.contains { readLayout($0) != nil }
                let q = PreRunQuestion(
                    key: "reorder",
                    title: known ? "Dieser Ordner wurde mit anderen Einstellungen sortiert. Jetzt neu ordnen?" : "Mit aktuellen Einstellungen neu ordnen?",
                    message: "\(names): \(plural(changed.count, "Clip liegt", "Clips liegen")) anders, als die aktuellen Einstellungen es vorsehen. Es wird nur verschoben, nichts verändert oder überschrieben.\n" + ex.joined(separator: "\n"),
                    icon: "arrow.triangle.branch",
                    options: [QuestionOption(id: "reorder", label: "Neu ordnen", detail: ex.first ?? ""),
                              QuestionOption(id: "keep", label: "So lassen, nur neue Dateien einsortieren", detail: "Bisherige Struktur bleibt")],
                    preset: nil, remember: { _ in },
                    example: changed.first.map { "\($0.info.job.url.lastPathComponent) → \(relPath(finalDir($0)))" },
                    recommended: "reorder",
                    reason: "Dann ist alles einheitlich nach den aktuellen Einstellungen – es wird nur verschoben und ist rückgängig machbar.")
                guard let a = await resolve([q]) else { return false }
                if a["reorder"] == "reorder" {
                    reorder = changedDrehs
                    for d in reorder { videosRootCache[pk(d)] = newRoot(d) }
                    infos += oldInfos.filter { i in reorder.contains { pk($0) == pk(drehOf(i)) } }
                } else { declined = changedDrehs }
            }
        }

        // Rückfrage: mehrere Aufnahmetage → auch nach Datum sortieren?
        // Tagesordner: vorhandene Struktur weiterführen (außer beim Neu-Ordnen); sonst nur fragen, wenn neue Clips von mehreren Tagen dabei sind
        if !lv.contains("date") && !infos.isEmpty {
            var existing: String? = nil
            for d in infos.map(drehOf) where !reorder.contains(where: { pk($0) == pk(d) }) {
                let vr = videosRoot(d)
                if let e = existingDateLayout(vr, onlySorted: vr.standardizedFileURL.path == d.standardizedFileURL.path) { existing = e; break }
            }
            let hasNew = infos.contains { !$0.old }
            let day = store.dayString(Date())
            let vp = wantsVideosFolder ? "\(FolderNames.videos)/" : ""
            var choice: String? = existing
            let sample = infos.first { !$0.old } ?? infos.first
            let sampleText = sample.map { i in "\(i.job.url.lastPathComponent) (\(store.dayString(i.start))) → \(drehOf(i).lastPathComponent)/\(vp)\(i.cam)/\(store.dayString(i.start))/…" }
            if existing == nil && (hasNew || !reorder.isEmpty) && projectsNeedDate(infos.map { ($0.job.url, $0.start) }),
               let q = dateQuestion(starts: infos.map(\.start), existing: nil,
                                    example: ("\(vp)\(day)/Kamera/…", "\(vp)Kamera/\(day)/…"), sample: sampleText) {
                guard let a = await resolve([q]) else { return false }
                choice = a["date"]
            }
            switch choice {
            case "top": lv.insert("date", at: 0)
            case "under":
                if let ci = lv.firstIndex(of: "camera") { lv.insert("date", at: ci + 1) } else { lv.insert("date", at: min(1, lv.count)) }
            default: break
            }
        }
        // Rückfrage: verschiedene Frameraten → auch nach FPS sortieren? Vorhandene FPS-Ordner → ohne Frage weiterführen (außer beim Neu-Ordnen).
        if !lv.contains("fps") && !infos.isEmpty {
            let drehs = infos.map(drehOf).filter { d in !reorder.contains(where: { pk($0) == pk(d) }) }
            if drehs.contains(where: { hasFpsFolders(videosRoot($0)) }) {
                lv = LearnedStore.insertingFps(into: lv)
            } else {
                let fresh = infos.filter { !$0.fps.isEmpty }
                let ex = LearnedStore.insertingFps(into: lv).map { LevelBuilder.sample($0, store) }
                let fs = fresh.first { $0.fps != fresh.first?.fps } ?? fresh.first
                let fsText = fs.map { "\($0.job.url.lastPathComponent) → \(drehOf($0).lastPathComponent)/\(wantsVideosFolder ? FolderNames.videos + "/" : "")\($0.cam)/\($0.fps)/…" }
                if let q = fpsQuestion(fresh.map(\.fps), example: (wantsVideosFolder ? "\(FolderNames.videos)/" : "") + (cfg.nestLevels ? ex.joined(separator: "/") : ex.joined(separator: FolderNames.separator)) + "/…", sample: fsText) {
                    guard let a = await resolve([q]) else { return false }
                    if a["fps"] == "yes" { lv = LearnedStore.insertingFps(into: lv) }
                }
            }
        }

        // Verschieben – nur, was nicht schon am Ziel liegt. Vorher Übersicht (alle Fragen sind jetzt beantwortet).
        let steps = plan(infos, levels: lv, root: { d in self.videosRoot(d) })
        let moves: [(URL, URL)] = steps.filter { here($0.info) != finalDir($0).standardizedFileURL.path }.map { ($0.info.job.url, finalDir($0)) }
        guard await confirmOverview(moves + extra) else { return false }
        for (sig, d) in layoutWrites { writeLayout(sig, to: d) }
        layoutWrites = []
        total += oldInfos.isEmpty ? 0 : infos.filter(\.old).count
        var reordered = 0
        for p in steps {
            if Task.isCancelled || safetyStop { return false }
            let i = p.info
            currentFile = i.job.url.lastPathComponent
            var tags: [String] = [i.cam]
            if let l = i.lens { tags.append(l) }
            if let s = i.speed { tags.append(s) }
            if let o = i.orient { tags.append(o) }
            let dest = finalDir(p)
            var ok = here(i) == dest.standardizedFileURL.path
            if !ok {
                if !i.old { _ = TagRunner.addFinderTags(tags, to: i.job.url) }   // Was nicht im Ordnernamen steht, als Finder-Tag
                ok = await move(i.job.url, to: dest)
                if ok {
                    movedVideos += 1
                    if i.old {
                        reordered += 1
                        if i.sub != "Stabilisiert" { await moveGyroCompanions(stem: i.job.url.deletingPathExtension().lastPathComponent, from: i.job.dir, to: p.target) }
                    }
                }
            }
            if ok {
                counts[i.orient ?? "Video", default: 0] += 1
                cameras[i.cam, default: 0] += 1
                if let l = i.lens { lenses[l, default: 0] += 1 }
                if let s = i.speed { speeds[s, default: 0] += 1 }
            }
            processed += 1
        }
        if reordered > 0 {
            hints.insert("Neu geordnet: \(plural(reordered, "Clip", "Clips")) nach den aktuellen Einstellungen verschoben (Dateien unverändert)", at: 0)
            // Final-Cut-Mediatheken in den neu geordneten Drehs → Hinweis zum Neu-Verknüpfen
            for d in reorder {
                guard let en = fm.enumerator(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let u = en.nextObject() as? URL {
                    if u.pathExtension.lowercased() == "fcpbundle" && !fcpLibraries.contains(u) { fcpLibraries.append(u) }
                }
            }
        }

        // leer gewordene alte Unterordner unter „Videos“ bzw. in den Ebenen-Ordnern aufräumen (nie Tims eigene Ordner)
        var touched: [URL] = []
        for d in steps.map({ $0.dreh }) + reorder where !touched.contains(where: { pk($0) == pk(d) }) { touched.append(d) }
        func isIn(_ list: [URL], _ d: URL) -> Bool { list.contains { pk($0) == pk(d) } }
        for dreh in touched {
            let kids = ((try? fm.contentsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.hasPrefix(".") }
            for k in kids {
                let u = dreh.appendingPathComponent(k)
                if FolderNames.isVideos(k) || Self.isSortedTree(u) { removeEmptyDirs(u) }
            }
            if isIn(reorder, dreh) {   // ganz leer gewordene alte Videos-/Ebenen-Ordner entfernen (nur wirklich leer)
                let old = oldTops.filter { pk($0.deletingLastPathComponent()) == pk(dreh) }
                for u in kids.filter(FolderNames.isVideos).map({ dreh.appendingPathComponent($0) }) + old {
                    removeEmptyDirs(u)
                    removeEmptyDir(u)   // nur wenn wirklich leer (höchstens .DS_Store)
                }
            }
            // Layout-Datei: beschreibt, mit welchen Einstellungen dieser Dreh sortiert ist
            let useV = videosRoot(dreh).standardizedFileURL.path != dreh.standardizedFileURL.path
            if isIn(declined, dreh) {
                var s = readLayout(dreh) ?? LayoutSig(version: 1, useVideos: useV, videosName: FolderNames.videos, levels: lv, configLevels: ["?"],
                                                      nest: cfg.nestLevels, separator: FolderNames.separator, declined: nil)
                s.declined = curKey
                writeLayout(s, to: dreh)
            } else if isIn(reorder, dreh) || readLayout(dreh) == nil {
                writeLayout(LayoutSig(version: 1, useVideos: useV, videosName: FolderNames.videos, levels: lv, configLevels: cfg.levels,
                                      nest: cfg.nestLevels, separator: FolderNames.separator, declined: nil), to: dreh)
            }
        }
        for d in declined where !isIn(touched, d) {
            if var s = readLayout(d) { s.declined = curKey; writeLayout(s, to: d) }
            else { writeLayout(LayoutSig(version: 1, useVideos: videosRoot(d).standardizedFileURL.path != d.standardizedFileURL.path, videosName: FolderNames.videos, levels: [], configLevels: ["?"], nest: cfg.nestLevels, separator: FolderNames.separator, declined: curKey), to: d) }
        }
        return true
    }

    private func noteStart(_ d: Date, for url: URL) {
        let p = url.standardizedFileURL.path
        if let b = folders.filter({ p.hasPrefix($0.standardizedFileURL.path + "/") }).max(by: { $0.path.count < $1.path.count }) {
            drehStarts[b.standardizedFileURL.path, default: []].append(d)
        }
    }

    /// Pfad nach dem Umbenennen eines Ordners anpassen
    static func rewrite(_ u: URL, from old: URL, to new: URL) -> URL {
        let o = old.standardizedFileURL.path, p = u.standardizedFileURL.path
        if p == o { return new }
        guard p.hasPrefix(o + "/") else { return u }
        return URL(fileURLWithPath: new.standardizedFileURL.path + String(p.dropFirst(o.count)))
    }

    /// Nach erfolgreichem Sortieren: Datum der Aufnahme in den Namen des gewählten Ordners übernehmen (nur Ordner, keine Dateien).
    private func renameDrehFolders() async {
        guard store.renameMode != "off" else { return }
        // tiefste zuerst, damit verschachtelte Auswahl gültig bleibt
        for base in folders.sorted(by: { $0.path.count > $1.path.count }) {
            guard let cur = folders.first(where: { $0.standardizedFileURL.path == base.standardizedFileURL.path }) else { continue }
            let name = cur.lastPathComponent
            guard let dates = drehStarts[cur.standardizedFileURL.path], let a = dates.min(), let b = dates.max() else { continue }
            if store.hasDateInName(name) { continue }
            let isVol = (try? cur.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            if isVol || cur.pathComponents.count <= 3 && cur.path.hasPrefix("/Volumes/") || cur.path == NSHomeDirectory() { continue }
            let multi = store.dayString(a) != store.dayString(b)
            let rangeL = store.dateLabel(from: a, to: b, range: true), startL = store.dateLabel(from: a, to: b, range: false)
            var opts: [QuestionOption] = [QuestionOption(id: "front-start", label: "Ja, vorne", detail: "\(startL) \(name)")]
            if multi { opts.insert(QuestionOption(id: "front-range", label: "Ja, vorne mit Zeitraum", detail: "\(rangeL) \(name)"), at: 0) }
            opts.append(QuestionOption(id: "back-start", label: "Ja, hinten", detail: "\(name) \(startL)"))
            if multi { opts.append(QuestionOption(id: "back-range", label: "Ja, hinten mit Zeitraum", detail: "\(name) \(rangeL)")) }
            opts.append(QuestionOption(id: "off", label: "Nein", detail: "Name bleibt „\(name)“"))
            var preset: String? = store.renameMode == "ask" ? nil : store.renameMode
            if let p = preset, !multi { preset = p.replacingOccurrences(of: "-range", with: "-start") }
            let q = PreRunQuestion(key: "rename", title: "Datum in den Ordnernamen übernehmen?",
                                   message: "„\(name)“ hat noch kein Datum im Namen. Frühestes Aufnahmedatum der Clips: \(startL)." + (multi ? " Aufnahmen bis \(store.dayString(b))." : "") + " Nur der Ordner wird umbenannt, keine Datei.",
                                   icon: "calendar.badge.plus", options: opts, preset: preset,
                                   remember: { [weak self] v in self?.store.renameMode = v },
                                   example: "\(name) → \(multi ? rangeL : startL) \(name)",
                                   recommended: multi ? "front-range" : "front-start",
                                   reason: "Datum vorne sortiert die Drehs im Finder automatisch chronologisch.")
            guard let ans = await resolve([q]) else { phase = .cancelled; return }
            let choice = ans["rename"] ?? "off"
            guard choice != "off" else { continue }
            let label = choice.hasSuffix("range") ? rangeL : startL
            let newName = Self.clean(choice.hasPrefix("front") ? "\(label) \(name)" : "\(name) \(label)")
            let dst = cur.deletingLastPathComponent().appendingPathComponent(newName)
            if fm.fileExists(atPath: dst.path) {
                hints.append("„\(name)“ nicht umbenannt: „\(newName)“ gibt es dort schon"); continue
            }
            let n = j.plan("umbenennen", cur, dst)
            do { try fm.moveItem(at: cur, to: dst) }
            catch {
                j.fail(n, error.localizedDescription)
                problems.append("„\(name)“ konnte nicht in „\(newName)“ umbenannt werden (geöffnet, gesperrt oder schreibgeschützt?): \(error.localizedDescription)")
                continue
            }
            guard fm.fileExists(atPath: dst.path) && !fm.fileExists(atPath: cur.path) else {
                j.fail(n, "Prüfung nach dem Umbenennen fehlgeschlagen")
                stopForSafety("„\(name)“: Prüfung nach dem Umbenennen fehlgeschlagen – Lauf gestoppt")
                return
            }
            j.done(n)
            j.rebase(from: cur, to: dst)
            Self.selectedBases = Set(Self.selectedBases.map { Self.rewrite(URL(fileURLWithPath: $0), from: cur, to: dst).standardizedFileURL.path })
            hints.append("Ordner umbenannt: „\(name)“ → „\(newName)“")
            // alle gemerkten Pfade nachziehen
            folders = folders.map { Self.rewrite($0, from: cur, to: dst) }
            gyroOffer = gyroOffer.map { Self.rewrite($0, from: cur, to: dst) }
            fcpLibraries = fcpLibraries.map { Self.rewrite($0, from: cur, to: dst) }
            folderStats = folderStats.map { st in
                let np = Self.rewrite(URL(fileURLWithPath: st.path), from: cur, to: dst).path
                let isBase = URL(fileURLWithPath: st.path).standardizedFileURL.path == cur.standardizedFileURL.path
                var n = CamFolderStat(path: np, name: isBase ? newName : st.name); n.hochkant = st.hochkant; n.quer = st.quer; n.quadrat = st.quadrat; n.other = st.other; return n
            }
            var ds: [String: [Date]] = [:]
            for (k, v) in drehStarts { ds[Self.rewrite(URL(fileURLWithPath: k), from: cur, to: dst).standardizedFileURL.path] = v }
            drehStarts = ds
        }
    }

    /// Gibt es unter `root` schon Tagesordner? "top" = direkt darunter, "under" = eine Ebene tiefer bzw. im Namen hinten.
    /// onlySorted: nur CamSort-Ebenen-Ordner betrachten (ohne Videos-Sammelordner liegen daneben Tims eigene Ordner).
    func existingDateLayout(_ root: URL, onlySorted: Bool = false) -> String? {
        let kids = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
            .filter { !onlySorted || Self.isSortedTree(root.appendingPathComponent($0)) }
        func anyPartIsDay(_ n: String) -> Bool { n.components(separatedBy: FolderNames.separator).contains { store.isDayFolder($0) } }
        if kids.contains(where: { store.isDayFolder($0) }) { return "top" }
        if kids.contains(where: anyPartIsDay) { return "under" }
        for k in kids {
            let sub = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(k).path)) ?? [])
            if sub.contains(where: anyPartIsDay) { return "under" }
        }
        return nil
    }

    /// Aufnahmezeit: aus den Video-Metadaten, sonst Dateidatum minus Dauer.
    private func recordingTime(_ asset: AVURLAsset, url: URL) async -> (Date, Date) {
        let dur = (try? await asset.load(.duration))?.seconds ?? 0
        let d = dur.isFinite ? max(dur, 1) : 1
        if let item = try? await asset.load(.creationDate), let v = try? await item.load(.dateValue) {
            return (v, v.addingTimeInterval(d))
        }
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let end = rv?.contentModificationDate ?? rv?.creationDate ?? Date()
        return (end.addingTimeInterval(-d), end)
    }

    private func removeEmptyDirs(_ root: URL) {
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        var dirs: [URL] = []
        while let u = en.nextObject() as? URL { if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(u) } }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            removeEmptyDir(d)   // nur wirklich leere Ordner (höchstens .DS_Store), mit Protokoll
        }
    }

    // MARK: Verschieben

    /// Sicheres Verschieben: nur innerhalb desselben Laufwerks (atomares Umbenennen, nie Kopieren + Löschen),
    /// vorher/nachher protokolliert, danach geprüft (Ziel da, Größe gleich, Quelle weg) – sonst sofortiger Stopp.
    private func move(_ src: URL, to dir: URL) async -> Bool {
        let name = src.lastPathComponent
        if safetyStop { return false }
        guard Safety.sameVolume(src, dir) else {
            problems.append("\(name): Ziel liegt auf einem anderen Laufwerk – nicht verschoben (CamSort kopiert beim Sortieren nie)")
            return false
        }
        guard ensureDir(dir) else { problems.append("\(name): Zielordner konnte nicht angelegt werden"); return false }

        var dst = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) {
            if Safety.sameFile(src, dst) { return true }   // liegt schon dort (nur andere Groß-/Kleinschreibung)
            switch await askDuplicate(name: name, folder: dir.path) {
            case .skip: skipped += 1; return false
            case .keepBoth: dst = freeURL(in: dir, for: name)
            case .replace:
                guard trashLogged(dst) else { problems.append("\(name): alte Datei ließ sich nicht in den Papierkorb legen"); return false }
            }
        }
        if safetyStop { return false }
        let size = Safety.itemSize(src)
        let n = j.plan("verschieben", src, dst, size: size)
        do { try fm.moveItem(at: src, to: dst) }
        catch {
            j.fail(n, error.localizedDescription)
            problems.append("\(name): konnte nicht verschoben werden (\(error.localizedDescription))")
            return false
        }
        guard fm.fileExists(atPath: dst.path) && !fm.fileExists(atPath: src.path) && Safety.itemSize(dst) == size else {
            j.fail(n, "Prüfung nach dem Verschieben fehlgeschlagen")
            stopForSafety("\(name): Nach dem Verschieben stimmt etwas nicht (Ziel fehlt, Größe anders oder Quelle noch da) – Lauf sofort gestoppt. Nichts wurde gelöscht; „Rückgängig machen“ ist verfügbar.")
            return false
        }
        j.done(n)
        return true
    }

    /// Fehlende Ordner einzeln anlegen und protokollieren (Rückgängig entfernt sie wieder, wenn sie leer sind)
    private func ensureDir(_ dir: URL) -> Bool {
        var missing: [URL] = []
        var cur = dir.standardizedFileURL
        var isDir: ObjCBool = false
        while !fm.fileExists(atPath: cur.path, isDirectory: &isDir) {
            missing.insert(cur, at: 0)
            let p = cur.deletingLastPathComponent()
            if p.path == cur.path { return false }
            cur = p
        }
        guard isDir.boolValue else { return false }
        for d in missing {
            let n = j.plan("ordner-anlegen", nil, d)
            do { try fm.createDirectory(at: d, withIntermediateDirectories: false); j.done(n) }
            catch { j.fail(n, error.localizedDescription); return false }
        }
        return true
    }

    /// „Ersetzen“ bei Duplikat: alte Datei nur in den Papierkorb, Ablageort im Protokoll
    private func trashLogged(_ u: URL) -> Bool {
        let n = j.plan("papierkorb", u, nil, size: Safety.itemSize(u))
        var res: NSURL?
        do {
            try fm.trashItem(at: u, resultingItemURL: &res)
            j.done(n, dst: res.map { $0 as URL })
            return true
        } catch { j.fail(n, error.localizedDescription); return false }
    }

    /// Entfernt NUR leere Ordner (höchstens .DS_Store) – nie eine Datei. Mit Protokoll.
    @discardableResult
    private func removeEmptyDir(_ u: URL) -> Bool {
        guard Safety.isEmptyDir(u) else { return false }
        let n = j.plan("ordner-loeschen", u, nil)
        do { try fm.removeItem(at: u); j.done(n); return true }
        catch { j.fail(n, error.localizedDescription); return false }
    }

    private func askDuplicate(name: String, folder: String) async -> DupChoice {
        if let all = dupForAll { return all }
        let (choice, forAll): (DupChoice, Bool) = await withCheckedContinuation { c in
            pendingDuplicate = DuplicateRequest(name: name, folder: folder, continuation: c)
        }
        if forAll { dupForAll = choice }
        return choice
    }

    private func freeURL(in dir: URL, for name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let u = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }

    // MARK: Ausrichtung

    private func orientation(of asset: AVURLAsset) async -> String? { await videoProps(of: asset).orient }

    /// Ausrichtung und nominale Framerate in EINEM Ladevorgang der Videospur (keine doppelte Analyse pro Datei)
    private func videoProps(of asset: AVURLAsset) async -> (orient: String?, nominalFps: Double) {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let props = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) else { return (nil, 0) }
        let r = props.0.applying(props.1)
        return (FolderNames.orientation(width: Double(abs(r.width)), height: Double(abs(r.height))), Double(props.2))
    }

    // MARK: Framerate

    /// Sony-Zeitlupe (S&Q): nominal z. B. 25p, aufgenommen mit 100p. Steht im NRT-XML als
    /// <VideoFrame … captureFps="100p" formatFps="25p">. Liefert die Aufnahme-Framerate oder nil.
    nonisolated static func captureFps(fromXML s: String) -> Double? {
        guard let tagR = s.range(of: #"<VideoFrame[^>]*>"#, options: .regularExpression) else { return nil }
        let tag = String(s[tagR])
        guard let r = tag.range(of: #"captureFps="[0-9.]+"#, options: .regularExpression) else { return nil }
        let v = Double(tag[r].dropFirst("captureFps=\"".count))
        return v.flatMap { $0 > 0 ? $0 : nil }
    }

    /// FPS-Ordnername für einen Clip: Sony-Aufnahme-FPS (captureFps), sonst nominale Framerate der Videospur.
    private func fpsFolder(for url: URL, nominal: Double, bytes: Data? = nil) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        var fps = nominal
        if let xu = sidecar(stem, exts: ["M01.XML", "M01.xml"], near: url.deletingLastPathComponent()),
           let x = try? String(contentsOf: xu, encoding: .utf8), let c = Self.captureFps(fromXML: x) { fps = c }
        else if let s = String(data: bytes ?? headTail(url), encoding: .isoLatin1), let c = Self.captureFps(fromXML: s) { fps = c }
        return FolderNames.fpsName(FolderNames.fpsClass(fps))
    }

    /// Frage „Auch nach Framerate sortieren?“ – nur bei mindestens zwei verschiedenen Frameraten. nil = nicht fragen (Antwort „no“).
    func fpsQuestion(_ names: [String], example pos: String, sample: String? = nil) -> PreRunQuestion? {
        guard store.fpsMode != "off" else { return nil }
        var count: [String: Int] = [:]
        for n in names { count[n, default: 0] += 1 }
        guard count.count > 1 else { return nil }
        func num(_ k: String) -> Int { Int(k.prefix { $0.isNumber }) ?? Int.max }
        let list = count.keys.sorted { (num($0), $0) < (num($1), $1) }.map { "\($0): \(count[$0]!)" }.joined(separator: ", ")
        return PreRunQuestion(
            key: "fps", title: "Auch nach Framerate sortieren?",
            message: "Die Clips haben unterschiedliche Frameraten (\(list)).",
            icon: "speedometer",
            options: [QuestionOption(id: "yes", label: "Ja, unter der Kamera", detail: pos),
                      QuestionOption(id: "no", label: "Nein", detail: "Alle Frameraten zusammen")],
            preset: nil,
            remember: { [weak self] a in
                guard let self else { return }
                if a == "yes" { self.store.levels = LearnedStore.insertingFps(into: self.store.levels) } else { self.store.fpsMode = "off" }
            },
            example: sample, recommended: "yes",
            reason: "\(count.count) Frameraten kommen vor – Zeitlupen-Clips liegen dann getrennt und sind im Schnitt sofort zu finden.")
    }

    /// Gibt es unter `root` (bis 4 Ebenen tief) schon FPS-Ordner? Dann Struktur ohne Frage weiterführen.
    func hasFpsFolders(_ root: URL, depth: Int = 4) -> Bool {
        guard depth > 0, let kids = try? fm.contentsOfDirectory(atPath: root.path) else { return false }
        for k in kids where !k.hasPrefix(".") {
            var isDir: ObjCBool = false
            let u = root.appendingPathComponent(k)
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if FolderNames.hasFpsPart(k) { return true }
            if FolderNames.isOrientation(k) || ["Stabilisiert", "Original", "Gyroflow-Projekte"].contains(k) { continue }
            if hasFpsFolders(u, depth: depth - 1) { return true }
        }
        return false
    }

    // MARK: Kamera

    /// nil = Nutzer hat abgebrochen
    private func camera(for url: URL, asset: AVURLAsset, siblings: Set<String>) async -> String? {
        let det = await detect(url: url, asset: asset, siblings: siblings)

        // 1) Gelernte Zuordnung
        if let learned = store.camera(for: det.signature) { return learned }
        // 2) Sicher erkannt und keine Bestätigung gewünscht
        if let n = det.name, !store.confirmCameras { return n }
        // 3) Lernen übersprungen → bestes Wissen
        if skipAsking { return det.name ?? "Unbekannt" }
        // 3b) In diesem Durchlauf schon beantwortet
        if let a = askedCameras[det.signature] { return a }
        // 4) Nachfragen
        let answer: String? = await withCheckedContinuation { c in
            pendingCamera = CameraRequest(fileName: url.lastPathComponent, hint: det.hint, suggestion: det.name ?? "",
                                          signature: det.signature, signatureLabel: det.label, continuation: c)
        }
        if Task.isCancelled { return nil }
        let result = answer ?? det.name ?? "Unbekannt"
        askedCameras[det.signature] = result
        return result
    }

    private func detect(url: URL, asset: AVURLAsset, siblings: Set<String>) async -> Detection {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        func known(_ n: String, _ how: String) -> Detection {
            Detection(name: n, signature: "auto:" + n, label: how, hint: "Erkannt als „\(n)“ (\(how)). Unter welchem Namen soll diese Kamera einsortiert werden?")
        }

        let bytes = headTail(url)

        // Sony: Modell aus Begleit-XML oder aus dem in der MP4 eingebetteten XML
        if let xu = sidecar(stem, exts: ["M01.XML", "M01.xml"], near: url.deletingLastPathComponent()),
           let s = try? String(contentsOf: xu, encoding: .utf8),
           let n = Self.sonyName(fromXML: s) { return known(n, "Sony-XML") }
        if let s = String(data: bytes, encoding: .isoLatin1), let n = Self.sonyName(fromXML: s) {
            return known(n, "Sony-Metadaten in der Datei")
        }

        // Metadaten im Video (iPhone, Android/Samsung, viele Kameras)
        var make = "", model = ""
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let key = (item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "").lowercased()
                guard let val = try? await item.load(.stringValue), !val.isEmpty else { continue }
                if key.contains("model"), model.isEmpty { model = val }
                else if (key.contains("make") || key.contains("manufacturer")), make.isEmpty { make = val }
            }
        }
        if let n = nameFrom(make: make, model: model), !n.lowercased().hasPrefix("dji") || n.count > 4 {
            return known(n, "Video-Metadaten")
        }

        // DJI: stabile Signatur – Kürzel am Dateinamen-Ende (z. B. _M3P), sonst Kamera-Code FCxxxx
        let hasSRT = siblings.contains(stem + ".SRT") || siblings.contains(stem + ".srt")
        let srtNote = hasSRT ? " Daneben liegt eine SRT-Datei – vermutlich eine Drohne." : ""
        let upName = name.uppercased()
        let isDJI = upName.hasPrefix("DJI_") || Self.djiCode(bytes) != nil
        if isDJI {
            if let code = Self.djiSuffix(upName) {
                return Detection(name: nil, signature: "dji-suffix:" + code, label: "DJI-Dateikürzel „\(code)“",
                                 hint: "DJI-Datei mit Kürzel „\(code)“ am Namensende.\(srtNote) Welches Modell ist das?")
            }
            if let code = Self.djiCode(bytes) {
                return Detection(name: nil, signature: "dji-code:" + code, label: "DJI-Kamera-Code „\(code)“",
                                 hint: "DJI-Kamera mit Code „\(code)“.\(srtNote) Welches Modell ist das?")
            }
            return Detection(name: nil, signature: "dji:unbekannt", label: "DJI ohne Modellkennung",
                             hint: "DJI-Datei ohne Modellkennung.\(srtNote) Welches Modell ist das?")
        }

        // Markenkennung in der Datei
        if let b = Self.scanBrand(bytes) { return known(b, "Herstellerkennung in der Datei") }

        // Dateiname
        let up = name.uppercased()
        func starts(_ re: String) -> Bool { up.range(of: re, options: .regularExpression) != nil }
        if starts(#"^C\d{4}"#) { return known("Sony", "Dateiname") }
        if starts(#"^IMG_.*\.MOV$"#) { return known("iPhone", "Dateiname") }
        if starts(#"^G[HXSL]\d+"#) || starts(#"^GOPR\d+"#) { return known("GoPro", "Dateiname") }
        if starts(#"^MVI_\d+"#) { return known("Canon", "Dateiname") }
        if starts(#"^PXL_\d+"#) { return known("Google Pixel", "Dateiname") }
        if starts(#"\.INSV$"#) || starts(#"^VID_\d{8}_\d{6}_\d{2}_\d+"#) { return known("Insta360", "Dateiname") }

        let p = LearnedStore.prefix(of: name)
        let low = name.lowercased()
        let screen = ["bildschirmaufnahme", "aufzeichnung", "screen recording", "screenrecording", "bildschirmfoto"].contains { low.hasPrefix($0) }
        let hint = screen ? "Sieht nach einer Bildschirmaufnahme aus – nicht von einer Kamera."
                 : starts(#"^\d{8}_\d{6}"#) ? "Vermutlich ein Android-Handy (z. B. Samsung)."
                 : "Kamera nicht erkannt – oder ist es ein Export bzw. kein Kamera-Clip? Dann unten einen Ordner wählen."
        return Detection(name: nil, signature: "name:\(p)|\(ext)",
                         label: "Dateiname \(LearnedStore.prefixLabel(p)), Endung .\(ext)", hint: hint)
    }

    private func nameFrom(make: String, model: String) -> String? {
        let mk = make.trimmingCharacters(in: .whitespaces), md = model.trimmingCharacters(in: .whitespaces)
        let all = "\(mk) \(md)".lowercased()
        guard !mk.isEmpty || !md.isEmpty else { return nil }
        if all.contains("iphone") { return "iPhone" }
        if all.contains("ipad") { return "iPad" }
        if all.contains("sony") { return md.isEmpty ? "Sony" : Self.sonyPretty(md) }
        if all.contains("dji") {
            var m = md.isEmpty ? mk : md
            if !m.lowercased().contains("dji") { m = "DJI " + m }
            return Self.clean(m)
        }
        if mk.lowercased() == "samsung" { return Self.clean("Samsung " + Self.samsungName(md)) }
        if !md.isEmpty, md.lowercased().hasPrefix(mk.lowercased()) { return Self.clean(md) }
        let brand = mk.prefix(1).uppercased() + mk.dropFirst()
        return Self.clean("\(brand) \(md)")
    }

    // MARK: Objektiv

    private func lensName(for url: URL, asset: AVURLAsset, siblings: Set<String>) async -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        // Sony: <Lens modelName="…"> in Begleit-XML oder eingebettet
        if let xu = sidecar(stem, exts: ["M01.XML", "M01.xml"], near: url.deletingLastPathComponent()),
           let s = try? String(contentsOf: xu, encoding: .utf8),
           let l = Self.lens(fromXML: s) { return l }
        if let s = String(data: headTail(url), encoding: .isoLatin1), let l = Self.lens(fromXML: s) { return l }
        // Andere Kameras/Handys: Objektiv-Angabe in den Metadaten, falls vorhanden
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let key = (item.identifier?.rawValue ?? "").lowercased()
                guard key.contains("lens"), let v = try? await item.load(.stringValue), !v.isEmpty else { continue }
                return Self.clean(v)
            }
        }
        return nil
    }

    static func lens(fromXML s: String) -> String? {
        guard let tagR = s.range(of: #"<Lens[^>]*>"#, options: .regularExpression) else { return nil }
        let tag = String(s[tagR])
        guard let r = tag.range(of: #"modelName="[^"]+""#, options: .regularExpression) else { return nil }
        let raw = String(tag[r].dropFirst("modelName=\"".count).dropLast()).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : clean(raw)
    }

    // MARK: Hilfen

    private func headTail(_ url: URL) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        let chunk = 1024 * 1024
        var data = (try? h.read(upToCount: chunk)) ?? Data()
        if let size = try? h.seekToEnd(), size > UInt64(chunk) {
            try? h.seek(toOffset: size - UInt64(chunk))
            data.append((try? h.read(upToCount: chunk)) ?? Data())
        }
        return data
    }

    /// Liest modelName="…" aus Sony-XML (auch eingebettet in der MP4).
    static func sonyName(fromXML s: String) -> String? {
        // Nur das <Device …>-Tag – <Lens modelName=…> ist das Objektiv!
        guard let tagR = s.range(of: #"<Device[^>]*>"#, options: .regularExpression) else { return nil }
        let tag = String(s[tagR])
        guard tag.range(of: "manufacturer=\"Sony\"", options: .caseInsensitive) != nil else { return nil }
        if let r = tag.range(of: #"modelName="[^"]+""#, options: .regularExpression) {
            let raw = tag[r].dropFirst("modelName=\"".count).dropLast()
            return sonyPretty(String(raw))
        }
        return "Sony"
    }

    static func sonyPretty(_ model: String) -> String {
        let m = model.uppercased().trimmingCharacters(in: .whitespaces)
        let table: [String: String] = [
            "ILCE-1": "Sony Alpha 1", "ILCE-1M2": "Sony Alpha 1 II", "ZV-E1": "Sony ZV-E1",
            "ILCE-7M3": "Sony Alpha 7 III", "ILCE-7M4": "Sony Alpha 7 IV", "ILCE-7M5": "Sony Alpha 7 V",
            "ILCE-7SM3": "Sony Alpha 7S III", "ILCE-7RM5": "Sony Alpha 7R V", "ILCE-7CM2": "Sony Alpha 7C II",
            "ILCE-7CR": "Sony Alpha 7CR", "ILCE-9M3": "Sony Alpha 9 III", "ILCE-6700": "Sony Alpha 6700",
            "ZV-E10": "Sony ZV-E10", "ZV-E10M2": "Sony ZV-E10 II", "ILME-FX3": "Sony FX3", "ILME-FX30": "Sony FX30",
            "ILME-FX6": "Sony FX6", "ILME-FX2": "Sony FX2",
        ]
        if let t = table[m] { return t }
        if m.hasPrefix("ILCE-") { return "Sony Alpha " + m.dropFirst(5) }
        if m.hasPrefix("ILME-") { return "Sony " + m.dropFirst(5) }
        return clean("Sony " + model)
    }

    /// Neues DJI-Namensschema: DJI_20250426155228_0038_D_M3P.MP4 → "M3P"
    static func djiSuffix(_ upName: String) -> String? {
        guard let r = upName.range(of: #"^DJI_\d{14}_\d{4}_[A-Z]_([A-Z0-9]{2,8})\."#, options: .regularExpression) else { return nil }
        let part = upName[r].dropLast()            // ohne Punkt
        guard let last = part.split(separator: "_").last else { return nil }
        return String(last)
    }

    /// Kamera-Code wie "FC4370" aus den Dateibytes (stabil, ohne wechselnde Anhängsel).
    static func djiCode(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .isoLatin1),
              let r = s.range(of: #"DJI[ _-]?FC\d{3,5}"#, options: .regularExpression),
              let c = s[r].range(of: #"FC\d{3,5}"#, options: .regularExpression) else { return nil }
        return String(s[r][c])
    }

    static func scanBrand(_ data: Data) -> String? {
        let brands: [(String, String)] = [
            ("Insta360", "Insta360"), ("Canon", "Canon"), ("GoPro", "GoPro"), ("SAMSUNG", "Samsung"),
            ("samsung", "Samsung"), ("Panasonic", "Panasonic"), ("FUJIFILM", "Fujifilm"), ("NIKON", "Nikon"),
            ("Nikon", "Nikon"), ("OLYMPUS", "Olympus"), ("OM Digital", "OM System"), ("Blackmagic", "Blackmagic"),
            ("Xiaomi", "Xiaomi"), ("HUAWEI", "Huawei"), ("OnePlus", "OnePlus"),
        ]
        for (needle, brand) in brands where data.range(of: Data(needle.utf8)) != nil { return brand }
        return nil
    }

    private static func samsungName(_ model: String) -> String {
        let m = model.uppercased()
        let map: [(String, String)] = [("SM-S9", "Galaxy S"), ("SM-A", "Galaxy A"), ("SM-F", "Galaxy Z"), ("SM-M", "Galaxy M"), ("SM-G", "Galaxy")]
        for (p, n) in map where m.hasPrefix(p) { return "\(n) (\(model))" }
        return model
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
         .replacingOccurrences(of: ":", with: "-")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Modus „Meine Kameraordner“

/// Ergebnis je Kameraordner (Fertig-Bildschirm)
struct CamFolderStat: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    var hochkant = 0
    var quer = 0
    var quadrat = 0
    var other = 0          // Fotos, Begleitdateien, Extras
    var moved: Int { hochkant + quer + quadrat + other }
}

extension Sorter {
    /// Kartenordner, die zu einer Kamera gehören (nie selbst eine Kamera)
    static let cardish: Set<String> = cardMarkers.union(["MISC", "AVF_INFO", "THMBNL", "SUB", "GENERAL", "DJI_001", "XDROOT", "MP_ROOT", "AVCHD", "DCIM"])
    /// Namen, die eher nicht nach einer Kamera klingen → Hinweis an Tim
    static let notCameraLike: Set<String> = ["export", "exporte", "exports", "audio", "sound", "sounds", "projekt", "projekte",
                                              "schnitt", "grafik", "grafiken", "logos", "final", "finale videos", "render", "renders", "proxy", "proxies"]

    /// Ordner, die in diesem Modus nie Kamera sind und nicht durchsucht werden
    private func ownSkipNames() -> Set<String> {
        var s = Set(outputNames.map(FolderNames.fold))
        for f in store.specialFolders { s.insert(FolderNames.fold(f)) }
        for f in ["Stabilisiert", "Original", "Gyroflow-Projekte", "Videos", FolderNames.videos, "Musik", "ZIP", "FCP", "Sonstiges"] { s.insert(FolderNames.fold(f)) }
        return s
    }

    private struct Entry { let url: URL; let isDir: Bool; let isLink: Bool; let isPackage: Bool }

    private func entries(_ dir: URL) -> [Entry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Entry(url: u, isDir: v?.isDirectory == true, isLink: v?.isSymbolicLink == true, isPackage: v?.isPackage == true)
        }
    }

    /// Ein Kameraordner. group = Elternordner (für „Tagesordner oben“), nil wenn der gewählte Ordner selbst die Kamera ist.
    struct OwnCam { let url: URL; let group: URL?; var name: String { url.lastPathComponent }; let inDayFolder: Bool }

    /// Welche Kameraordner stecken im gewählten Ordner? (selbst Kamera oder Elternordner) + lose Dateien
    private func cameraFolders(in base: URL, skip: Set<String>) -> (cams: [OwnCam], loose: Int)? {
        guard let items = entries(base) else { return nil }
        let isCard: (Entry) -> Bool = { $0.isDir && Self.cardish.contains($0.url.lastPathComponent.uppercased()) }
        let hasCard = items.contains(where: isCard)
        let looseFiles = items.filter { e in
            !e.isDir && !e.isLink && !(category(for: e.url.pathExtension.lowercased()) == .ignore)
        }
        let candidates = items.filter { e in
            e.isDir && !e.isLink && !e.isPackage && !isCard(e)
                && !FolderNames.isOrientation(e.url.lastPathComponent) && !FolderNames.hasFpsPart(e.url.lastPathComponent)
                && !skip.contains(FolderNames.fold(e.url.lastPathComponent))
        }
        // Unterordner, die nur Kartenkopien DIESER Kamera sind (z. B. „A1/A1 Karte 2/PRIVATE“, „A1/Karte 1/DCIM“)
        let baseName = FolderNames.fold(base.lastPathComponent)
        func isCardCopy(_ c: Entry) -> Bool {
            let n = FolderNames.fold(c.url.lastPathComponent)
            let named = n.hasPrefix(baseName) || ["karte", "card", "sd", "kopie", "backup", "copy"].contains { n.contains($0) }
            return named && (entries(c.url) ?? []).contains(where: isCard)
        }
        let onlyCardCopies = !candidates.isEmpty && candidates.allSatisfy(isCardCopy)
        // Gemischt (lose Dateien UND Kameraordner) → Elternordner; lose Dateien bleiben liegen
        if hasCard || candidates.isEmpty || onlyCardCopies { return ([OwnCam(url: base, group: nil, inDayFolder: false)], 0) }
        var cams: [OwnCam] = []
        for c in candidates {
            if store.isDayFolder(c.url.lastPathComponent) {
                // schon „Tagesordner oben“: <Eltern>/<Tag>/<Kamera>
                for k in entries(c.url) ?? [] where k.isDir && !k.isLink && !k.isPackage
                    && !FolderNames.isOrientation(k.url.lastPathComponent) && !FolderNames.hasFpsPart(k.url.lastPathComponent)
                    && !skip.contains(FolderNames.fold(k.url.lastPathComponent))
                    && !Self.cardish.contains(k.url.lastPathComponent.uppercased()) {
                    cams.append(OwnCam(url: k.url, group: base, inDayFolder: true))
                }
            } else {
                cams.append(OwnCam(url: c.url, group: base, inDayFolder: false))
            }
        }
        return (cams, looseFiles.count)
    }

    /// Einen Ordnernamen unter `parent` wiederverwenden, auch wenn er anders geschrieben ist („hochkant“).
    private func childDir(_ parent: URL, _ name: String) -> URL {
        let clean = Self.clean(name)
        if let items = try? fm.contentsOfDirectory(atPath: parent.path),
           let hit = items.first(where: { FolderNames.fold($0) == FolderNames.fold(clean) }) {
            var isDir: ObjCBool = false
            let u = parent.appendingPathComponent(hit)
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
        }
        return parent.appendingPathComponent(clean)
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        FolderNames.fold(a.standardizedFileURL.resolvingSymlinksInPath().path) == FolderNames.fold(b.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func runOwnCameraFolders() async {
        let skip = ownSkipNames()
        var ownCams: [OwnCam] = []
        var seen = Set<String>()
        for base in folders {
            guard let r = cameraFolders(in: base, skip: skip) else {
                problems.append("\(base.lastPathComponent): kein Zugriff auf den Ordner – bitte unter Systemeinstellungen › Datenschutz & Sicherheit erlauben")
                continue
            }
            if r.loose > 0 {
                hints.append("\(base.lastPathComponent): \(plural(r.loose, "Datei lag", "Dateien lagen")) außerhalb eines Kameraordners und \(r.loose == 1 ? "wurde" : "wurden") nicht verschoben")
            }
            for c in r.cams {
                let key = FolderNames.fold(c.url.standardizedFileURL.path)
                if seen.insert(key).inserted { ownCams.append(c) }
            }
        }
        let cams = ownCams.map(\.url)
        let camInfo = Dictionary(ownCams.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let odd = cams.map(\.lastPathComponent).filter { Self.notCameraLike.contains(FolderNames.fold($0)) }
        if !odd.isEmpty {
            hints.append("Als Kameraordner behandelt: \(odd.joined(separator: ", ")). Falls das keine Kamera ist: unter Einstellungen › Eigene Ordner eintragen, dann bleibt der Ordner unberührt.")
        }

        // 1) Dateien je Kameraordner einsammeln (Hochkant/Quer & Ausgabeordner werden nicht betreten → idempotent)
        struct Item { let cam: URL; let url: URL; let ext: String }
        var found: [Item] = []
        var symlinks = 0, proxyDirs = 0
        for cam in cams {
            if Task.isCancelled { phase = .cancelled; return }
            var stack: [URL] = [cam]
            var cardSkipped = false
            while let dir = stack.popLast() {
                guard let items = entries(dir) else { problems.append("\(dir.lastPathComponent): Ordner nicht lesbar"); continue }
                for e in items {
                    let name = e.url.lastPathComponent
                    let ext = e.url.pathExtension.lowercased()
                    if e.isLink { symlinks += 1; continue }
                    if e.isDir {
                        if Self.projectExt.contains(ext) { if !FCPLibraryBuilder.isOwnOutput(e.url) { found.append(Item(cam: cam, url: e.url, ext: ext)) }; continue }
                        if e.isPackage { continue }
                        if FolderNames.isOrientation(name) || skip.contains(FolderNames.fold(name)) { continue }
                        // Sony-Proxys (M4ROOT/SUB) und Vorschaubilder nicht als Clips einsortieren
                        let up = name.uppercased()
                        if (up == "SUB" || up == "THMBNL") && dir.lastPathComponent.uppercased() == "M4ROOT" { proxyDirs += 1; continue }
                        if cfg.includeSubfolders { stack.append(e.url) } else { cardSkipped = true }
                        continue
                    }
                    found.append(Item(cam: cam, url: e.url, ext: ext))
                }
            }
            if cardSkipped { hints.append("\(cam.lastPathComponent): „Unterordner durchsuchen“ ist aus – Unterordner (z. B. Kartenstruktur) wurden nicht durchsucht") }
        }
        if symlinks > 0 { hints.append("\(plural(symlinks, "Verknüpfung (Alias/Symlink)", "Verknüpfungen (Alias/Symlink)")) übersprungen") }
        if proxyDirs > 0 { hints.append("Sony-Proxy-/Vorschau-Ordner (SUB, THMBNL) unverändert gelassen") }
        fcpLibraries = found.filter { $0.ext == "fcpbundle" }.map(\.url) + FCPLibraryBuilder.ownLibraries(in: folders)   // eigene Mediathek (CamSort) mit Neu-Verknüpfen-Hinweis

        // 2) Unbekannte Dateitypen erfragen (wie sonst auch)
        var unknown: [String: (example: String, count: Int)] = [:]
        for f in found where category(for: f.ext) == nil {
            let cur = unknown[f.ext]
            unknown[f.ext] = (cur?.example ?? f.url.lastPathComponent, (cur?.count ?? 0) + 1)
        }
        guard let sessionExt = await askUnknown(unknown) else { phase = .cancelled; return }

        var stats: [String: CamFolderStat] = [:]
        for c in cams { stats[c.path] = CamFolderStat(path: c.path, name: c.lastPathComponent) }
        var vids: [Item] = [], others: [(Item, FileCategory)] = []
        for f in found {
            let cat = category(for: f.ext) ?? sessionExt[f.ext] ?? .ignore
            switch cat {
            case .video: vids.append(f)
            case .ignore: if !Self.alwaysIgnore.contains(f.ext) { ignored += 1 }
            default: others.append((f, cat))
            }
        }
        total = vids.count + others.count
        processed = 0
        phase = .sorting
        var extras = cfg.levels.filter { ["lens", "length", "speed", "fps"].contains($0) }
        var emptied = Set<URL>()   // Ordner, aus denen etwas verschoben wurde → danach aufräumen, wenn leer

        // 3a) Videos analysieren (Ausrichtung, Zusatzebenen, Aufnahmezeit) – noch nichts verschieben
        struct VInfo { let v: Item; let o: String; var parts: [String]; let fps: String; let start: Date }
        var infos: [VInfo] = []
        for v in vids {
            if Task.isCancelled { phase = .cancelled; return }
            currentFile = v.url.lastPathComponent
            guard fm.fileExists(atPath: v.url.path) else { processed += 1; continue }
            let size = (try? v.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 { problems.append("\(v.url.lastPathComponent): leere Datei (0 Byte) – nicht verschoben"); processed += 1; continue }
            let asset = AVURLAsset(url: v.url)
            let props = await videoProps(of: asset)
            guard let o = props.orient else {
                problems.append("\(v.url.lastPathComponent): Bildgröße nicht lesbar (beschädigt?) – nicht verschoben"); processed += 1; continue
            }
            let stem = v.url.deletingPathExtension().lastPathComponent
            let dir = v.url.deletingLastPathComponent()
            let (st, en) = await recordingTime(asset, url: v.url)
            let fps = fpsFolder(for: v.url, nominal: props.nominalFps)
            var parts: [String] = []
            for l in extras {
                switch l {
                case "lens":
                    let sib = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    parts.append(await lensName(for: v.url, asset: asset, siblings: sib) ?? "Objektiv unbekannt")
                case "length":
                    parts.append(en.timeIntervalSince(st) < cfg.lengthThreshold ? cfg.lengthShort : cfg.lengthLong)
                case "speed":
                    let srt = [dir, v.cam.appendingPathComponent(FolderNames.side), v.cam.appendingPathComponent("Begleitdateien")]
                        .flatMap { d in [stem + ".SRT", stem + ".srt"].map { d.appendingPathComponent($0) } }
                        .first { fm.fileExists(atPath: $0.path) }
                    if let srt {
                        switch SRTSpeed.analyze(srt) {
                        case .speed(let kmh):
                            parts.append(kmh >= cfg.standMin && kmh <= cfg.standMax ? "Stand"
                                       : kmh >= cfg.moveMin && kmh <= cfg.moveMax ? "Fahrt" : "Dazwischen")
                        case .noGPS: parts.append("Ohne GPS")
                        case .unreadable: break
                        }
                    }
                case "fps": parts.append(fps)
                default: break
                }
            }
            infos.append(VInfo(v: v, o: o, parts: parts, fps: fps, start: st))
            noteStart(st, for: v.url)
        }

        // 3b) Rückfragen vor dem Verschieben (nur wenn relevant). Vorhandene Tagesordner → Struktur weiterführen.
        var existing: String? = nil
        if ownCams.contains(where: \.inDayFolder) { existing = "top" }
        else if ownCams.contains(where: { existingDateLayout($0.url) == "top" }) { existing = "under" }
        var dateChoice = "off"
        if cfg.levels.contains("date") { dateChoice = existing ?? "under" }
        else if !projectsNeedDate(infos.map { ($0.v.url, $0.start) }) { dateChoice = "off" }
        else if let q = dateQuestion(starts: infos.map(\.start), existing: existing,
                                     example: ("Dreh/\(store.dayString(Date()))/A1/Hochkant", "Dreh/A1/\(store.dayString(Date()))/Hochkant"),
                                     sample: infos.first.map { "\($0.v.url.lastPathComponent) (\(store.dayString($0.start))) → \(relPath($0.v.cam))/\(store.dayString($0.start))/\($0.o)" }) {
            guard let a = await resolve([q]) else { phase = .cancelled; return }
            dateChoice = a["date"] ?? "off"
        }
        // Framerate: vorhandene FPS-Ordner weiterführen, sonst nur bei mehreren Frameraten fragen. Position: als letzte Zusatzebene, direkt über Hochkant/Quer.
        if !extras.contains("fps") && !infos.isEmpty {
            var on = ownCams.contains { hasFpsFolders($0.url) }
            let fs = infos.first { $0.fps != infos[0].fps } ?? infos[0]
            if !on, let q = fpsQuestion(infos.map(\.fps), example: "A1/" + (extras.isEmpty ? "" : "…/") + "\(infos[0].fps)/Hochkant",
                                        sample: "\(fs.v.url.lastPathComponent) → \(relPath(fs.v.cam))/\(fs.fps)/\(fs.o)") {
                guard let a = await resolve([q]) else { phase = .cancelled; return }
                on = a["fps"] == "yes"
            }
            if on {
                extras.append("fps")
                for k in infos.indices { infos[k].parts.append(infos[k].fps) }
            }
        }
        if dateChoice == "top" && ownCams.contains(where: { $0.group == nil }) {
            hints.append("Tagesordner oben geht nur, wenn der Dreh-Ordner (mit den Kameraordnern) gewählt ist – für direkt gewählte Kameraordner liegen die Tage unter der Kamera.")
        }
        /// Wurzel für einen Clip/eine Datei: Kameraordner bzw. <Eltern>/<Tag>/<Kamera>
        func root(for cam: URL, day: String?) -> URL {
            guard let day, dateChoice != "off" else { return cam }
            let info = camInfo[cam.path]
            if dateChoice == "top", let g = info?.group { return childDir(childDir(g, day), cam.lastPathComponent) }
            return childDir(cam, day)
        }
        var rootOfStem: [String: [(stem: String, root: URL)]] = [:]   // Begleitdateien folgen ihrem Clip

        // 3c) Ziele berechnen (noch nichts verschieben): <Wurzel>/[Zusatzebenen]/Hochkant|Quer
        struct VStep { let i: VInfo; let dir: URL; let target: URL }
        var vPlan: [VStep] = []
        for i in infos {
            let v = i.v
            guard fm.fileExists(atPath: v.url.path) else { processed += 1; continue }
            let dir = v.url.deletingLastPathComponent()
            let base = root(for: v.cam, day: store.dayString(i.start))
            rootOfStem[v.cam.path, default: []].append((stem: v.url.deletingPathExtension().lastPathComponent, root: base))
            var target = base
            if cfg.nestLevels { for p in i.parts { target = childDir(target, p) } }
            else if !i.parts.isEmpty { target = childDir(target, i.parts.joined(separator: FolderNames.separator)) }
            target = childDir(target, i.o)
            if samePath(dir, target) { processed += 1; continue }
            vPlan.append(VStep(i: i, dir: dir, target: target))
        }
        // 4) Alles andere bleibt im Kameraordner: Begleitdateien, Fotos, Extras/<Musik|ZIP|FCP>
        struct OStep { let f: Item; let cat: FileCategory; let dir: URL; let target: URL; let key: String }
        var oPlan: [OStep] = []
        for (f, cat) in others {
            guard fm.fileExists(atPath: f.url.path) else { processed += 1; continue }
            let dir = f.url.deletingLastPathComponent()
            let target: URL
            let key: String
            let fstem = f.url.deletingPathExtension().lastPathComponent
            let owner = (rootOfStem[f.cam.path] ?? []).filter { fstem.hasPrefix($0.stem) }.max { $0.stem.count < $1.stem.count }
            switch cat {
            case .side:
                // bei Tagesordnern oben neben den Clip-Tag, sonst Kameraordner (Gyroflow findet die XML beim Hochsteigen)
                let r = dateChoice == "top" ? (owner?.root ?? f.cam) : f.cam
                target = childDir(r, FolderNames.side); key = f.ext.uppercased()
            case .photo:
                let fd: Date? = (try? f.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let r = dateChoice == "top" ? root(for: f.cam, day: fd.map { store.dayString($0) }) : f.cam
                target = childDir(r, FolderNames.photos); key = "Fotos"
            case .music, .archive, .project:
                let folder = cat.folder ?? "Sonstiges"
                target = childDir(childDir(f.cam, FolderNames.extras), folder); key = folder
            default: processed += 1; continue
            }
            if samePath(dir, target) { processed += 1; continue }
            oPlan.append(OStep(f: f, cat: cat, dir: dir, target: target, key: key))
        }
        var overviewMoves: [(URL, URL)] = vPlan.map { ($0.i.v.url, $0.target) }
        overviewMoves += oPlan.map { ($0.f.url, $0.target) }
        guard await confirmOverview(overviewMoves) else { phase = .cancelled; return }

        // 4b) Verschieben
        for st in vPlan {
            if Task.isCancelled || safetyStop { phase = .cancelled; return }
            let i = st.i, v = i.v, target = st.target
            currentFile = v.url.lastPathComponent
            defer { processed += 1 }
            guard fm.fileExists(atPath: v.url.path) else { continue }
            if await move(v.url, to: target) {
                movedVideos += 1
                counts[i.o, default: 0] += 1
                cameras[v.cam.lastPathComponent, default: 0] += 1
                for p in i.parts where ["Stand", "Fahrt", "Dazwischen", "Ohne GPS"].contains(p) { speeds[p, default: 0] += 1 }
                if extras.contains("lens"), let li = extras.firstIndex(of: "lens"), li < i.parts.count { lenses[i.parts[li], default: 0] += 1 }
                if i.o == FolderNames.portrait { stats[v.cam.path]?.hochkant += 1 }
                else if i.o == FolderNames.landscape { stats[v.cam.path]?.quer += 1 } else { stats[v.cam.path]?.quadrat += 1 }
                _ = TagRunner.addFinderTags([v.cam.lastPathComponent, i.o], to: target.appendingPathComponent(v.url.lastPathComponent))
                emptied.insert(st.dir)
            }
        }
        for st in oPlan {
            if Task.isCancelled || safetyStop { phase = .cancelled; return }
            currentFile = st.f.url.lastPathComponent
            defer { processed += 1 }
            guard fm.fileExists(atPath: st.f.url.path) else { continue }
            if await move(st.f.url, to: st.target) {
                if st.cat == .photo { counts["Fotos", default: 0] += 1 } else { sideCounts[st.key, default: 0] += 1 }
                stats[st.f.cam.path]?.other += 1
                emptied.insert(st.dir)
            }
        }
        currentFile = ""

        // 5) Nur wirklich leer gewordene Kartenordner entfernen (bis hoch zum Kameraordner)
        for d in emptied.sorted(by: { $0.path.count > $1.path.count }) {
            guard let cam = cams.first(where: { d.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { continue }
            var cur = d
            while cur.standardizedFileURL.path.count > cam.standardizedFileURL.path.count {
                guard removeEmptyDir(cur) else { break }
                cur = cur.deletingLastPathComponent()
            }
        }

        if dateChoice == "top" {
            for c in ownCams where c.group != nil && !c.inDayFolder {
                removeEmptyDir(c.url)   // nur wenn wirklich leer
            }
        }

        // Ein direkt gewählter Kameraordner wird nie umbenannt (sein Name ist die Kamera)
        for c in ownCams where c.group == nil { drehStarts[c.url.standardizedFileURL.path] = nil }

        folderStats = cams.compactMap { stats[$0.path] }
        let fresh = folderStats.filter { $0.moved > 0 }, same = folderStats.filter { $0.moved == 0 }
        if !fresh.isEmpty || !same.isEmpty {
            var line = ""
            if !fresh.isEmpty { line = "Neu sortiert: " + fresh.map { "\($0.name) (\(plural($0.hochkant + $0.quer + $0.quadrat, "Clip", "Clips")))" }.joined(separator: ", ") }
            if !same.isEmpty { line += (line.isEmpty ? "" : " – ") + "unverändert: " + same.map(\.name).joined(separator: ", ") }
            hints.insert(line, at: 0)
        }

        // 6) Gyrodaten erkennen (im Hintergrund, kein Main-Thread-Stau)
        stepLabel = "Gyrodaten prüfen …"
        let suffixes = cfg.gyroSuffixList
        let bases = folders
        let offer: [URL] = await Task.detached(priority: .userInitiated) {
            let r = await GyroRunner.collectGyroClips(in: bases, suffixes: suffixes)
            return r.hochkant + r.quer
        }.value
        stepLabel = ""
        let camNames = Set(cams.map(\.lastPathComponent))
        gyroOffer = offer
        var by: [String: Int] = [:]
        for u in offer {
            let name = u.pathComponents.dropLast().last(where: { camNames.contains($0) }) ?? "Andere"
            by[name, default: 0] += 1
        }
        gyroOfferByCamera = by
    }
}

// MARK: - Projekte trennen (lange Drehpause)

/// Ein Projekt im Fertig-Bildschirm
struct ProjectSummary: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let range: String
    let cams: String
    let isNew: Bool
}

/// Inhalt der unsichtbaren Markierungsdatei `.camsort-projekt` im Projektordner
struct ProjectMarker: Codable {
    var name: String
    var start: Date
    var end: Date
}

extension Sorter {
    nonisolated static let projectMarker = ".camsort-projekt"

    fileprivate struct PClip { let url: URL; let start: Date; let end: Date; let cam: String }
    /// Geplante Projekt-Trennung eines eingeworfenen Ordners (ausgeführt erst nach allen Fragen)
    fileprivate struct SplitPlan {
        let base: URL
        let projects: [PProject]
        let moves: [(src: URL, dir: URL)]
        let summaries: [ProjectSummary]
    }
    fileprivate struct PFile { let url: URL; let date: Date? }
    fileprivate final class PProject {
        let url: URL
        var name: String
        var start: Date
        var end: Date
        let existing: Bool
        var clips: [PClip] = []
        var files: [URL] = []
        init(url: URL, name: String, start: Date, end: Date, existing: Bool) {
            self.url = url; self.name = name; self.start = start; self.end = end; self.existing = existing
        }
        func distance(to d: Date) -> TimeInterval {
            if d < start { return start.timeIntervalSince(d) }
            if d > end { return d.timeIntervalSince(end) }
            return 0
        }
    }

    /// Datumsfrage nur, wenn innerhalb EINES Projekts (bzw. gewählten Ordners) mehrere Tage vorkommen.
    func projectsNeedDate(_ items: [(URL, Date)]) -> Bool {
        guard !projectRoots.isEmpty else { return true }
        var days: [String: Set<String>] = [:]
        for (u, d) in items {
            let p = u.standardizedFileURL.path
            let root = projectRoots.map { $0.standardizedFileURL.path }.filter { p.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? ""
            days[root, default: []].insert(store.dayString(d))
        }
        return days.values.contains { $0.count > 1 }
    }

    static func readMarker(_ dir: URL) -> ProjectMarker? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(projectMarker)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ProjectMarker.self, from: data)
    }

    private func writeMarker(_ m: ProjectMarker, in dir: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(m) else { return }
        if !writeLogged(data, to: dir.appendingPathComponent(Self.projectMarker)) {
            hints.append("\(dir.lastPathComponent): Projekt-Markierung konnte nicht gespeichert werden – beim nächsten Einlesen wird evtl. erneut gefragt")
        }
    }

    /// Aufnahmezeit inkl. Ende (Start + Dauer)
    private func clipTime(_ url: URL) async -> (start: Date, end: Date) {
        let r = await recordingTime(AVURLAsset(url: url), url: url)
        return (start: r.0, end: r.1)
    }

    /// Aufnahmedatum eines Fotos: EXIF DateTimeOriginal (Ortszeit der Kamera), sonst Dateidatum
    private func photoDate(_ url: URL) -> Date? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return rv?.contentModificationDate ?? rv?.creationDate
    }

    /// Kamera-Name nur für die Übersicht (ohne Rückfrage)
    private func quickCamera(_ url: URL, base: URL, selfCam: Bool) async -> String {
        if cfg.ownCameraFolders {
            if selfCam { return base.lastPathComponent }
            let rel = url.standardizedFileURL.pathComponents.dropFirst(base.standardizedFileURL.pathComponents.count)
            return rel.count > 1 ? rel.first! : "lose Dateien"
        }
        let sib = Set((try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
        let det = await detect(url: url, asset: AVURLAsset(url: url), siblings: sib)
        if let l = store.camera(for: det.signature) { return l.hasPrefix(LearnedStore.folderPrefix) ? String(l.dropFirst(LearnedStore.folderPrefix.count)) : l }
        return det.name ?? "Kamera „\(LearnedStore.prefix(of: url.lastPathComponent))“"
    }

    static func durationText(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) Min." }
        let h = m / 60, r = m % 60
        if h >= 48 { return "\(h / 24) Tagen" }
        return r == 0 ? "\(h) Std." : "\(h) Std. \(r) Min."
    }

    /// Clips chronologisch zu Zeitblöcken zusammenführen (parallele Kameras überlappen) und Projektgrenzen bestimmen:
    /// Lücke ≥ Mindestpause UND (bei mind. 4 Lücken) ≥ 4 × Median der Lücken dieses Drehs.
    private func groupByPause(_ clips: [PClip]) -> [[PClip]] {
        let sorted = clips.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        var blocks: [[PClip]] = [[sorted[0]]]
        var blockEnd = sorted[0].end
        var gaps: [TimeInterval] = []
        for c in sorted.dropFirst() {
            if c.start <= blockEnd { blocks[blocks.count - 1].append(c) }
            else { gaps.append(c.start.timeIntervalSince(blockEnd)); blocks.append([c]) }
            blockEnd = max(blockEnd, c.end)
        }
        let minGap = min(720, max(30, store.projectGapMinutes)) * 60
        var limit = minGap
        if gaps.count >= 4 {
            let g = gaps.sorted()
            let median = g.count % 2 == 1 ? g[g.count / 2] : (g[g.count / 2 - 1] + g[g.count / 2]) / 2
            limit = max(minGap, 4 * median)
        }
        var out: [[PClip]] = [blocks[0]]
        for (i, b) in blocks.enumerated().dropFirst() {
            if gaps[i - 1] >= limit { out.append(b) } else { out[out.count - 1] += b }
        }
        return out
    }

    /// Vor dem Sortieren: je gewähltem Ordner prüfen, ob die Clips aus mehreren Projekten stammen. false = abgebrochen.
    /// Bei Trennung werden `folders` durch die Projektordner ersetzt – der normale Ablauf sortiert dann jedes Projekt für sich.
    /// Nur planen und fragen – verschoben wird erst in executeSplits(), nachdem alle Fragen beantwortet sind.
    func splitProjects() async -> Bool {
        var out: [URL] = []
        for base in folders {
            if Task.isCancelled { return false }
            guard let r = await planProjects(base) else { return false }
            for u in r where !out.contains(where: { $0.standardizedFileURL.path == u.standardizedFileURL.path }) { out.append(u) }
        }
        plannedFolders = (out != folders && !out.isEmpty) ? out : []
        return true
    }

    /// Geplante Projekt-Trennung ausführen (nach Übersicht). false = abgebrochen.
    func executeSplits() async -> Bool {
        let all: [(URL, URL)] = splitPlans.flatMap { $0.moves.map { ($0.src, $0.dir) } }
        let newProjects = splitPlans.flatMap(\.projects).filter { !$0.existing }.count
        guard await confirmOverview(all, note: newProjects > 0 ? "\n\nZuerst werden \(plural(newProjects, "Projektordner", "Projektordner")) angelegt, danach wird darin sortiert." : "") else { return false }
        stepLabel = "Projekte anlegen …"
        for plan in splitPlans {
            let basePath = plan.base.standardizedFileURL.path
            var touched = Set<URL>()
            for p in plan.projects where !p.clips.isEmpty || !p.files.isEmpty || !p.existing {
                guard ensureDir(p.url) else { problems.append("\(p.url.lastPathComponent): Projektordner konnte nicht angelegt werden"); return false }
            }
            for m in plan.moves {
                if Task.isCancelled || safetyStop { return false }
                currentFile = m.src.lastPathComponent
                if await move(m.src, to: m.dir) { touched.insert(m.src.deletingLastPathComponent()) }
            }
            for p in plan.projects where fm.fileExists(atPath: p.url.path) { writeMarker(ProjectMarker(name: p.name, start: p.start, end: p.end), in: p.url) }
            currentFile = ""
            // leer gewordene Ordner (Kartenstruktur, Kameraordner) entfernen – nur wenn wirklich leer
            for d in touched.sorted(by: { $0.path.count > $1.path.count }) {
                var cur = d
                while cur.standardizedFileURL.path.count > basePath.count && cur.standardizedFileURL.path.hasPrefix(basePath + "/") {
                    guard removeEmptyDir(cur) else { break }
                    cur = cur.deletingLastPathComponent()
                }
            }
            projectSummaries += plan.summaries
        }
        if !plannedFolders.isEmpty { folders = plannedFolders }
        splitPlans = []
        return !safetyStop
    }

    private func planProjects(_ base: URL) async -> [URL]? {
        if fm.fileExists(atPath: base.appendingPathComponent(Self.projectMarker).path) { projectRoots.append(base); return [base] }
        // vorhandene Projektordner
        let kids = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var projects: [PProject] = []
        for k in kids where fm.fileExists(atPath: k.appendingPathComponent(Self.projectMarker).path) {
            let m = Self.readMarker(k)
            projects.append(PProject(url: k, name: m?.name ?? k.lastPathComponent, start: m?.start ?? .distantPast, end: m?.end ?? .distantPast, existing: true))
        }
        if store.projectMode == "never" && projects.isEmpty { return [base] }

        // Unsortierte Dateien einsammeln (CamSort-Ausgabeordner und Projektordner nicht betreten)
        var skip = Set(outputNames.map(FolderNames.fold))
        for f in ["Stabilisiert", "Original", "Gyroflow-Projekte", "Musik", "ZIP", "FCP", "Sonstiges"] { skip.insert(FolderNames.fold(f)) }
        if cfg.ownCameraFolders { for f in store.specialFolders { skip.insert(FolderNames.fold(f)) } }
        let projectPaths = Set(projects.map { $0.url.standardizedFileURL.path })
        var files: [URL] = []
        var sortedPresent = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey]
        var stack: [URL] = [base]
        while let dir = stack.popLast() {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                if dir == base { return [base] }   // kein Zugriff → normaler Ablauf meldet das
                continue
            }
            for u in items where !u.lastPathComponent.hasPrefix(".") {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isSymbolicLink == true { continue }
                let name = u.lastPathComponent
                if v?.isDirectory == true {
                    if Self.projectExt.contains(u.pathExtension.lowercased()) { files.append(u); continue }
                    if v?.isPackage == true { continue }
                    if projectPaths.contains(u.standardizedFileURL.path) { continue }
                    if FolderNames.isVideos(name) || FolderNames.hasOrientationPart(name) || FolderNames.hasFpsPart(name) || FolderNames.isSceneFolder(name) { sortedPresent = true; continue }
                    if skip.contains(FolderNames.fold(name)) { continue }
                    if cfg.includeSubfolders || cfg.ownCameraFolders { stack.append(u) }
                    continue
                }
                if v?.isRegularFile == true { files.append(u) }
            }
        }
        // Bereits sortierter Dreh ohne Projektordner → nicht umbauen
        if sortedPresent && projects.isEmpty { return [base] }

        // Modus „Meine Kameraordner“ mit direkt gewähltem Kameraordner: Projekt/<Kamera>/…
        var selfCam = false
        if cfg.ownCameraFolders {
            if let p = projects.first { selfCam = fm.fileExists(atPath: p.url.appendingPathComponent(base.lastPathComponent).path) }
            else if let r = cameraFolders(in: base, skip: ownSkipNames()), r.cams.count == 1, r.cams[0].group == nil { selfCam = true }
        }

        // Clips (Videos außer Sony-Proxys/Vorschau) mit Aufnahmezeit
        var clips: [PClip] = []
        var others: [URL] = []
        for u in files {
            if Task.isCancelled { return nil }
            let ext = u.pathExtension.lowercased()
            let parent = u.deletingLastPathComponent()
            let proxy = ["SUB", "THMBNL"].contains(parent.lastPathComponent.uppercased())
                && parent.deletingLastPathComponent().lastPathComponent.uppercased() == "M4ROOT"
            if category(for: ext) == .video && !proxy {
                currentFile = u.lastPathComponent
                let t = await clipTime(u)
                let cam = await quickCamera(u, base: base, selfCam: selfCam)
                clips.append(PClip(url: u, start: t.start, end: t.end, cam: cam))
            } else if ext != "savedsearch" { others.append(u) }
        }
        currentFile = ""
        if clips.isEmpty && projects.isEmpty { return [base] }
        let minGap = min(720, max(30, store.projectGapMinutes)) * 60

        // 1) Clips, die zeitlich zu einem vorhandenen Projekt passen, dorthin – ohne Frage
        var rest: [PClip] = []
        for c in clips {
            if let p = projects.filter({ $0.distance(to: c.start) < minGap || $0.distance(to: c.end) < minGap })
                .min(by: { $0.distance(to: c.start) < $1.distance(to: c.start) }) { p.clips.append(c) }
            else { rest.append(c) }
        }
        var groups = groupByPause(rest)
        if projects.isEmpty && groups.count <= 1 { return [base] }

        let tf = DateFormatter(); tf.dateFormat = "HH:mm"; tf.timeZone = .current
        let df = DateFormatter(); df.dateFormat = "dd.MM. HH:mm"; df.timeZone = .current
        func range(_ a: Date, _ b: Date) -> String {
            Calendar.current.isDate(a, inSameDayAs: b) ? "\(df.string(from: a))–\(tf.string(from: b))" : "\(df.string(from: a)) – \(df.string(from: b))"
        }
        func camList(_ cs: [PClip]) -> String {
            var n: [String: Int] = [:]
            for c in cs { n[c.cam, default: 0] += 1 }
            return n.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }

        // 2) Kamera mit falsch gestellter Uhr? Eine Kamera bildet allein einen Block, kommt sonst nirgends vor.
        var suspect: (group: Int, cam: String, target: Int)? = nil
        if groups.count + projects.count > 1 {
            for (i, g) in groups.enumerated() {
                let cams = Set(g.map(\.cam))
                guard cams.count == 1, let cam = cams.first else { continue }
                let elsewhere = groups.enumerated().contains { $0.offset != i && $0.element.contains { $0.cam == cam } }
                    || projects.contains { p in p.clips.contains { $0.cam == cam } }
                let othersHaveCams = groups.enumerated().contains { $0.offset != i && !$0.element.isEmpty } || !projects.isEmpty
                guard !elsewhere && othersHaveCams, groups.count > 1 else { continue }
                // Ziel: Block mit den meisten anderen Clips
                let t = groups.indices.filter { $0 != i }.max { groups[$0].count < groups[$1].count }
                if let t { suspect = (i, cam, t); break }
            }
        }

        // 3) Rückfrage
        var lines: [String] = []
        for p in projects { lines.append("Vorhanden: \(p.name) (\(p.start == .distantPast ? "ohne Zeit" : range(p.start, p.end)))") }
        var dflt: [String] = []
        let partF = DateFormatter(); partF.dateFormat = "HH.mm"; partF.timeZone = .current
        for g in groups {
            let a = g.map(\.start).min()!, b = g.map(\.end).max()!
            let h = Calendar.current.component(.hour, from: a)
            dflt.append(Self.clean("\(store.dayString(a)) " + (h < 12 ? "Vormittag" : h < 17 ? "Nachmittag" : "Abend")))
            lines.append("Projekt \(projects.count + dflt.count): \(range(a, b)) · \(camList(g))")
        }
        // gleiche Vorschläge unterscheidbar machen (Uhrzeit anhängen)
        let orig = dflt
        for i in dflt.indices where orig.filter({ $0 == orig[i] }).count > 1 || projects.contains(where: { $0.name == orig[i] }) {
            dflt[i] += " " + partF.string(from: groups[i].map(\.start).min()!)
        }
        var pauses: [String] = []
        var allBlocks: [(Date, Date)] = projects.filter { $0.start != .distantPast }.map { ($0.start, $0.end) }
        for g in groups { allBlocks.append((g.map(\.start).min()!, g.map(\.end).max()!)) }
        allBlocks.sort { $0.0 < $1.0 }
        for i in allBlocks.indices.dropFirst() where allBlocks[i].0 > allBlocks[i - 1].1 {
            let gap = allBlocks[i].0.timeIntervalSince(allBlocks[i - 1].1)
            let sameDay = Calendar.current.isDate(allBlocks[i - 1].1, inSameDayAs: allBlocks[i].0)
            let fa = sameDay ? tf.string(from: allBlocks[i - 1].1) : df.string(from: allBlocks[i - 1].1)
            let fb = sameDay ? tf.string(from: allBlocks[i].0) : df.string(from: allBlocks[i].0)
            if gap >= minGap { pauses.append("Zwischen \(fa) und \(fb) liegt eine Pause von \(Self.durationText(gap)).") }
        }
        var msg = (pauses.isEmpty ? "Neue Clips passen zeitlich zu keinem vorhandenen Projekt." : pauses.joined(separator: " "))
        msg += "\n\n" + lines.joined(separator: "\n")
        var opts = [QuestionOption(id: "split", label: "Ja, getrennt ablegen",
                                   detail: "\(base.lastPathComponent)/<Projektname>/…")]
        if let s = suspect {
            let ga = groups[s.group].map(\.start).min()!, gt = groups[s.target].map(\.start).min()!
            let far = abs(ga.timeIntervalSince(gt)) > 30 * 86400
            msg += "\n\nAchtung: Kamera \(s.cam) liegt komplett separat\(far ? " (Aufnahmedatum \(store.dayString(ga)))" : "") – evtl. falsche Uhrzeit an der Kamera?"
            opts.append(QuestionOption(id: "split-fix", label: "Ja, aber \(s.cam) zu Projekt \(projects.count + s.target + 1)",
                                       detail: "\(s.cam) dem Projekt mit den meisten anderen Clips zuordnen"))
        }
        opts.append(QuestionOption(id: "one", label: projects.isEmpty ? "Nein, ein Projekt" : "Nein, zum nächstliegenden Projekt",
                                   detail: projects.isEmpty ? "Alles bleibt zusammen in „\(base.lastPathComponent)“" : "Kein neuer Projektordner"))
        let fields = dflt.enumerated().map { QuestionField(id: "name\($0.offset)", label: "Name Projekt \(projects.count + $0.offset + 1)", value: $0.element, showFor: "split") }
        // „Immer trennen“ gemerkt: nur fragen, wenn eine Kamera verdächtig isoliert liegt
        let preset: String? = store.projectMode == "always" && suspect == nil ? "split"
                            : store.projectMode == "never" ? "one" : nil
        let exGroup = groups.count > 1 ? 1 : 0
        let exClip = groups.indices.contains(exGroup) ? groups[exGroup].sorted { $0.start < $1.start }.first : nil
        let q = PreRunQuestion(key: "project", title: pauses.isEmpty ? "Neues Projekt?" : "Sind das \(groups.count + projects.count) Projekte?",
                               message: msg, icon: "rectangle.split.3x1", options: opts, preset: preset,
                               remember: { [weak self] a in self?.store.projectMode = a == "one" ? "never" : "always" },
                               fields: fields,
                               example: exClip.map { "\($0.url.lastPathComponent) (\(tf.string(from: $0.start))) → \(base.lastPathComponent)/\(dflt[exGroup])/…" },
                               recommended: suspect != nil ? "split-fix" : "split",
                               reason: suspect.map { "Kamera \($0.cam) liegt zeitlich allein – vermutlich falsche Kamerauhr." }
                                   ?? (pauses.first ?? "Die neuen Clips passen zeitlich zu keinem vorhandenen Projekt."))
        var ans: [String: String] = ["project": "split"]
        if !groups.isEmpty {
            guard let a = await resolve([q]) else { return nil }
            ans = a
        }
        var choice = ans["project"] ?? "one"
        if choice == "split-fix", let s = suspect {
            groups[s.target] += groups[s.group]
            groups[s.group] = []
            hints.append("Kamera \(s.cam) liegt zeitlich separat (Kamerauhr prüfen) – dem Projekt mit den meisten Clips zugeordnet")
            choice = "split"
        }
        if choice != "split" {
            if projects.isEmpty { return [base] }
            for c in rest { projects.min { $0.distance(to: c.start) < $1.distance(to: c.start) }?.clips.append(c) }
        } else {
            var usedNames = Set<String>()
            for (i, g) in groups.enumerated() where !g.isEmpty {
                var name = Self.clean(ans["project.name\(i)"] ?? dflt[i])
                if name.isEmpty || name.hasPrefix(".") { name = dflt[i] }
                // Dublette innerhalb dieser Frage → Zähler anhängen
                var n = 2
                let stem = name
                while usedNames.contains(FolderNames.fold(name)) { name = "\(stem) (\(n))"; n += 1 }
                usedNames.insert(FolderNames.fold(name))
                // Gibt es den Projektordner schon → als bestehendes Projekt weiterverwenden
                if let old = projects.first(where: { FolderNames.fold($0.url.lastPathComponent) == FolderNames.fold(name) }) {
                    old.clips += g; continue
                }
                var dir = base.appendingPathComponent(name)
                var isDir: ObjCBool = false
                while fm.fileExists(atPath: dir.path, isDirectory: &isDir) && !isDir.boolValue {   // gleichnamige Datei
                    dir = base.appendingPathComponent("\(stem) (\(n))"); n += 1
                }
                let p = PProject(url: dir, name: dir.lastPathComponent, start: g.map(\.start).min()!, end: g.map(\.end).max()!, existing: false)
                p.clips = g
                projects.append(p)
            }
        }
        // Zeiträume aktualisieren
        for p in projects where !p.clips.isEmpty {
            let a = p.clips.map(\.start).min()!, b = p.clips.map(\.end).max()!
            p.start = p.start == .distantPast ? a : min(p.start, a); p.end = p.end == .distantPast ? b : max(p.end, b)
        }
        guard !projects.isEmpty else { return [base] }

        // 4) Andere Dateien: Begleitdatei folgt ihrem Clip (Dateiname beginnt mit dem Clipnamen), sonst nach Datum, sonst erstes Projekt
        var byStem: [(stem: String, dir: String, p: PProject)] = []
        for p in projects { for c in p.clips { byStem.append((c.url.deletingPathExtension().lastPathComponent, c.url.deletingLastPathComponent().path, p)) } }
        var undated = 0
        for f in others {
            let stem = f.deletingPathExtension().lastPathComponent
            let cands = byStem.filter { !$0.stem.isEmpty && stem.hasPrefix($0.stem) }
            if let hit = cands.max(by: { ($0.dir == f.deletingLastPathComponent().path ? 1 : 0, $0.stem.count) < ($1.dir == f.deletingLastPathComponent().path ? 1 : 0, $1.stem.count) }) {
                hit.p.files.append(f); continue
            }
            let isPhoto = category(for: f.pathExtension.lowercased()) == .photo
            let d: Date? = isPhoto ? photoDate(f) : (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let d, let p = projects.min(by: { $0.distance(to: d) < $1.distance(to: d) }) { p.files.append(f) }
            else { projects[0].files.append(f); undated += 1 }
        }
        if undated > 0 { hints.append("\(plural(undated, "Datei", "Dateien")) ohne Datum → \(projects[0].name)") }

        // 5) Ziele planen: relative Lage bleibt erhalten (<Eingeworfen>/<Projekt>/[Kamera]/…). Verschoben wird erst nach allen Fragen.
        let basePath = base.standardizedFileURL.path
        var moves: [(src: URL, dir: URL)] = []
        for p in projects {
            for u in p.clips.map(\.url) + p.files {
                let parent = u.deletingLastPathComponent().standardizedFileURL.path
                guard parent == basePath || parent.hasPrefix(basePath + "/") else { continue }
                var target = p.url
                if selfCam { target = target.appendingPathComponent(base.lastPathComponent) }
                let rel = String(parent.dropFirst(basePath.count)).split(separator: "/").map(String.init)
                for r in rel { target = target.appendingPathComponent(r) }
                moves.append((u, target))
            }
        }
        var sums: [ProjectSummary] = []
        for p in projects {
            let cams = camList(p.clips)
            sums.append(ProjectSummary(path: p.url.path, name: p.url.lastPathComponent,
                                       range: p.start == .distantPast ? "" : range(p.start, p.end),
                                       cams: cams.isEmpty ? "keine neuen Clips" : cams, isNew: !p.existing))
        }
        splitPlans.append(SplitPlan(base: base, projects: projects, moves: moves, summaries: sums))
        let urls = projects.map(\.url)
        projectRoots += urls
        return urls
    }
}
