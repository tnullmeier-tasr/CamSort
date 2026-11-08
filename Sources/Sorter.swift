import Foundation
import AVFoundation
import AppKit

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

final class QuestionRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let icon: String
    let options: [QuestionOption]
    let continuation: CheckedContinuation<(String, Bool)?, Never>
    init(title: String, message: String, icon: String, options: [QuestionOption], continuation: CheckedContinuation<(String, Bool)?, Never>) {
        self.title = title; self.message = message; self.icon = icon; self.options = options; self.continuation = continuation
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
}

enum Phase { case idle, scanning, sorting, done, cancelled }

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
    /// Aufnahmezeiten je gewähltem Ordner (für „Datum in den Ordnernamen“)
    private var drehStarts: [String: [Date]] = [:]
    /// Modus „Meine Kameraordner“: Ergebnis je Kameraordner
    @Published var folderStats: [CamFolderStat] = []
    /// Clips mit Gyrodaten nach dem Sortieren (Angebot im Fertig-Bildschirm)
    @Published var gyroOffer: [URL] = []
    @Published var gyroOfferByCamera: [String: Int] = [:]

    let store: LearnedStore

    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "insv", "mts", "m2ts", "avi", "mkv", "3gp", "mxf"]
    static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "hif", "tif", "tiff", "raw",
                                        "cr2", "cr3", "nef", "raf", "orf", "rw2", "insp", "webp", "gif", "srw", "pef"]
    static let musicExt: Set<String> = ["mp3", "wav", "aac", "m4a", "aif", "aiff", "flac", "ogg", "opus", "wma", "caf"]
    static let archiveExt: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz"]
    static let projectExt: Set<String> = ["fcpbundle", "fcpxml", "fcpxmld", "fcpxd"]
    static let sideExt: Set<String> = ["gyroflow", "xml", "lrf", "srt", "thm", "aae", "xmp", "bim", "lrv"]
    static let alwaysIgnore: Set<String> = ["ds_store", "db", "ini", "localized"]
    static var fixedOutput: Set<String> { FolderNames.outputNames.union(["Musik", "ZIP", "FCP", "Hochkant", "Quer", "Quadratisch", FolderNames.square, "Stabilisiert", "Original", "Gyroflow-Projekte"]) }

    private var dupForAll: DupChoice?
    @Published var skipAsking = false   // „Lernen überspringen“ für diesen Durchlauf
    private var askedCameras: [String: String] = [:]
    private var task: Task<Void, Never>?
    private let fm = FileManager.default

    init(store: LearnedStore) { self.store = store }

    var progress: Double { total == 0 ? 0 : Double(processed) / Double(total) }
    var movedTotal: Int { counts.values.reduce(0, +) + sideCounts.values.reduce(0, +) }

    func addFolders(_ urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, !folders.contains(u) { folders.append(u) }
        }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Auswählen"
        panel.message = "Welche Ordner sollen sortiert werden?"
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }

    func reset() {
        folders = []; phase = .idle; total = 0; processed = 0; currentFile = ""
        clearResults()
    }

    private func clearResults() {
        counts = [:]; sideCounts = [:]; cameras = [:]; lenses = [:]; speeds = [:]; skipped = 0; ignored = 0
        problems = []; hints = []; movedVideos = 0; folderStats = []; gyroOffer = []; gyroOfferByCamera = [:]; drehStarts = [:]; dupForAll = nil; skipAsking = false; askedCameras = [:]; gyroMoved = 0
    }

    func start() {
        FolderNames.load()
        guard !folders.isEmpty else { return }
        clearResults(); processed = 0
        phase = .scanning
        task = Task {
            stepLabel = store.ownCameraFolders ? "Meine Kameraordner: Hochkant / Quer"
                      : alreadySorted ? "Ordner schon sortiert – suche neue Dateien" : "Schritt 1: Sortieren"
            if store.ownCameraFolders { await runOwnCameraFolders() } else { await run() }
            guard phase != .cancelled, !Task.isCancelled else { return }
            await renameDrehFolders()
            guard phase != .cancelled, !Task.isCancelled else { return }
            if store.autoGyro { await runGyro(auto: true) }
            stepLabel = ""
            phase = Task.isCancelled ? .cancelled : .done
        }
    }

    /// Schritt 2: nach Gyroflow stabilisierte und unstabilisierte Clips trennen.
    @Published var stepLabel = ""
    @Published var gyroMoved = 0
    private var alreadySorted: Bool {
        folders.contains { fm.fileExists(atPath: $0.appendingPathComponent(FolderNames.videos).path) }
    }

    func startGyro() {
        guard !folders.isEmpty else { return }
        clearResults(); processed = 0
        phase = .scanning
        task = Task { stepLabel = "Gyroflow-Dateien trennen"; await runGyro(auto: false); stepLabel = ""; phase = Task.isCancelled ? .cancelled : .done }
    }

    private func runGyro(auto: Bool) async {
        let suffixes = store.gyroSuffixList
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
        for (dir, files) in byDir {
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
        stepLabel = "Schritt 2: Gyroflow-Dateien trennen"
        total = jobs.count; processed = 0
        phase = .sorting
        for (f, target) in jobs.sorted(by: { $0.0.path < $1.0.path }) {
            if Task.isCancelled { phase = .cancelled; return }
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
        task?.cancel()
        if let p = pendingDuplicate { pendingDuplicate = nil; p.continuation.resume(returning: (.skip, false)) }
        if let p = pendingCamera { pendingCamera = nil; p.continuation.resume(returning: nil) }
        if let p = pendingExtensions { pendingExtensions = nil; p.continuation.resume(returning: nil) }
        if let p = pendingQuestion { pendingQuestion = nil; p.continuation.resume(returning: nil) }
    }

    func answerQuestion(_ option: String?, remember: Bool) {
        guard let p = pendingQuestion else { return }
        pendingQuestion = nil
        p.continuation.resume(returning: option.map { ($0, remember) })
    }

    /// Fragen nacheinander klären. Ergebnis: key → Antwort; nil = abgebrochen.
    func resolve(_ questions: [PreRunQuestion]) async -> [String: String]? {
        var out: [String: String] = [:]
        for q in questions {
            if let p = q.preset { out[q.key] = p; continue }
            let a: (String, Bool)? = await withCheckedContinuation { c in
                pendingQuestion = QuestionRequest(title: q.title, message: q.message, icon: q.icon, options: q.options, continuation: c)
            }
            guard let a, !Task.isCancelled else { return nil }
            let (opt, rem) = a
            if rem { q.remember(opt) }
            out[q.key] = opt
        }
        return out
    }

    /// Frage „Auch nach Datum sortieren?“ – nur relevant, wenn die Clips von mehreren Tagen stammen.
    /// existing: vorhandene Tagesordner-Struktur ("top"/"under") → gleiche Struktur weiterführen, nicht fragen.
    func dateQuestion(starts: [Date], existing: String?, example: (top: String, under: String)) -> PreRunQuestion? {
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
            preset: preset, remember: { [weak self] a in self?.store.dateMode = a })
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
        if let c = clean, remember { store.learn(signature: p.signature, label: p.signatureLabel, camera: c) }
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
        if let m = map, remember { for (e, c) in m { store.learnExtension(e, as: c) } }
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
                    if Self.projectExt.contains(ext) { out.append((u.deletingLastPathComponent(), u, ext)) }
                    return false
                }
                if store.compactLayout && FolderNames.isVideos(u.lastPathComponent) { return true }
                if store.compactLayout && u.pathComponents.contains(where: FolderNames.isVideos) {
                    return !["Stabilisiert", "Original", "Gyroflow-Projekte"].contains(u.lastPathComponent)
                }
                return !outNames.contains(u.lastPathComponent)
            }
            if v?.isRegularFile == true { out.append((u.deletingLastPathComponent(), u, ext)) }
            return false
        }

        if store.includeSubfolders {
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
        fcpLibraries = found.filter { $0.ext == "fcpbundle" }.map(\.url)

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

        if store.compactLayout {
            total = videos.count + others.count
            phase = .sorting
            guard await layoutCompact(videos, siblings: siblings) else { phase = .cancelled; return }
            for job in others {
                if Task.isCancelled { phase = .cancelled; return }
                currentFile = job.url.lastPathComponent
                guard fm.fileExists(atPath: job.url.path) else { processed += 1; continue }
                let dreh = Self.drehRoot(job.dir)
                switch job.cat {
                case .side:
                    if await move(job.url, to: dreh.appendingPathComponent(FolderNames.side)) { sideCounts[job.ext.uppercased(), default: 0] += 1 }
                case .photo:
                    if await move(job.url, to: dreh.appendingPathComponent(FolderNames.photos)) { counts["Fotos", default: 0] += 1 }
                case .music, .archive, .project:
                    let folder = job.cat.folder ?? "Sonstiges"
                    if await move(job.url, to: dreh.appendingPathComponent(FolderNames.extras).appendingPathComponent(folder)) { sideCounts[folder, default: 0] += 1 }
                default: break
                }
                processed += 1
            }
            currentFile = ""
            return
        }

        let jobs = videos + others
        total = jobs.count
        phase = .sorting

        for job in jobs {
            if Task.isCancelled { phase = .cancelled; return }
            currentFile = job.url.lastPathComponent
            guard fm.fileExists(atPath: job.url.path) else { processed += 1; continue }

            switch job.cat {
            case .video:
                let asset = AVURLAsset(url: job.url)
                let o = await orientation(of: asset)
                guard let cam = await camera(for: job.url, asset: asset, siblings: siblings[job.dir] ?? []) else {
                    phase = .cancelled; return
                }
                if cam.hasPrefix(LearnedStore.folderPrefix) {
                    let f = String(cam.dropFirst(LearnedStore.folderPrefix.count))
                    if await move(job.url, to: job.dir.appendingPathComponent(f)) { sideCounts[f, default: 0] += 1 }
                    processed += 1; continue
                }
                var target = job.dir.appendingPathComponent("Videos").appendingPathComponent(cam)
                if store.sortByLens {
                    if let lens = await lensName(for: job.url, asset: asset, siblings: siblings[job.dir] ?? []) {
                        target = target.appendingPathComponent(lens)
                        lenses[lens, default: 0] += 1
                    } else {
                        target = target.appendingPathComponent("Objektiv unbekannt")
                        lenses["Objektiv unbekannt", default: 0] += 1
                    }
                }
                if store.droneBySpeed {
                    let stem = job.url.deletingPathExtension().lastPathComponent
                    let srt = [stem + ".SRT", stem + ".srt"].first { (siblings[job.dir] ?? []).contains($0) }
                    if let srt {
                        switch SRTSpeed.analyze(job.dir.appendingPathComponent(srt)) {
                        case .speed(let kmh):
                            let folder: String
                            if kmh >= store.standMin && kmh <= store.standMax { folder = "Stand" }
                            else if kmh >= store.moveMin && kmh <= store.moveMax { folder = "Fahrt" }
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
                if await move(job.url, to: target) {
                    movedVideos += 1
                    counts[o ?? "Video", default: 0] += 1
                    cameras[cam, default: 0] += 1
                }
            case .side:
                let key = job.ext.uppercased()
                if await move(job.url, to: job.dir.appendingPathComponent(key)) { sideCounts[key, default: 0] += 1 }
            case .photo:
                if await move(job.url, to: job.dir.appendingPathComponent("Fotos")) { counts["Fotos", default: 0] += 1 }
            case .music, .archive, .project:
                let folder = job.cat.folder ?? "Sonstiges"
                if await move(job.url, to: job.dir.appendingPathComponent(folder)) { sideCounts[folder, default: 0] += 1 }
            case .ignore: break
            }
            processed += 1
        }
        currentFile = ""
    }

    /// Unbekannte Dateitypen einmal abfragen. nil = abgebrochen.
    private func askUnknown(_ unknown: [String: (example: String, count: Int)]) async -> [String: FileCategory]? {
        guard !unknown.isEmpty else { return [:] }
        let list = unknown.map { (ext: $0.key, example: $0.value.example, count: $0.value.count) }.sorted { $0.ext < $1.ext }
        let answer: [String: FileCategory]? = await withCheckedContinuation { c in
            pendingExtensions = ExtensionRequest(extensions: list, continuation: c)
        }
        if Task.isCancelled { return nil }
        return answer ?? [:]
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
        } else { return dir }
        // Ordner, der nur eine Kartenkopie enthält (z. B. „Karte A/PRIVATE“) → der Dreh ist eine Ebene höher
        let inside = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
        let cardish = cardMarkers.union(["MISC", "AVF_INFO", "THMBNL", "SUB", "GENERAL"])
        let hasCard = inside.contains { cardish.contains($0.uppercased()) }
        let onlyCardOrOutput = inside.allSatisfy { cardish.contains($0.uppercased()) || fixedOutput.contains($0) }
        if hasCard && onlyCardOrOutput { root = root.deletingLastPathComponent() }
        return root
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

    /// Analysiert alle Videos je Dreh und legt nur die Ordner an, die sich dort unterscheiden.
    private func layoutCompact(_ videos: [Job], siblings: [URL: Set<String>]) async -> Bool {
        struct Info { let job: Job; let cam: String; let lens: String?; let speed: String?; let orient: String?; let start: Date; let end: Date }
        var lv = store.levels
        var infos: [Info] = []
        for job in videos {
            if Task.isCancelled { return false }
            currentFile = job.url.lastPathComponent
            let asset = AVURLAsset(url: job.url)
            let o = await orientation(of: asset)
            var sib = siblings[job.dir] ?? []
            let stem = job.url.deletingPathExtension().lastPathComponent
            if let x = sidecar(stem, exts: ["M01.XML", "M01.xml"], near: job.dir) { sib.insert(x.lastPathComponent) }
            guard let cam = await camera(for: job.url, asset: asset, siblings: sib) else { return false }
            var lens: String? = nil
            if lv.contains("lens") { lens = await lensName(for: job.url, asset: asset, siblings: sib) ?? "Objektiv unbekannt" }
            var speed: String? = nil
            if lv.contains("speed"), let srt = sidecar(stem, exts: [".SRT", ".srt"], near: job.dir) {
                switch SRTSpeed.analyze(srt) {
                case .speed(let kmh):
                    speed = kmh >= store.standMin && kmh <= store.standMax ? "Stand"
                          : kmh >= store.moveMin && kmh <= store.moveMax ? "Fahrt" : "Dazwischen"
                    hints.append(String(format: "%@: Ø %.1f km/h → %@", job.url.lastPathComponent, kmh, speed!))
                case .noGPS: speed = "Ohne GPS"
                case .unreadable: break
                }
            }
            let (st, en) = await recordingTime(asset, url: job.url)
            infos.append(Info(job: job, cam: cam, lens: lens, speed: speed, orient: o, start: st, end: en))
            noteStart(st, for: job.url)
        }
        // Rückfrage: mehrere Aufnahmetage → auch nach Datum sortieren?
        // Tagesordner: vorhandene Struktur weiterführen; sonst nur fragen, wenn neue Clips von mehreren Tagen dabei sind
        if !lv.contains("date") && !infos.isEmpty {
            var existing: String? = nil
            for d in Set(infos.map { Self.drehRoot($0.job.dir) }) {
                if let e = existingDateLayout(d.appendingPathComponent(FolderNames.videos)) { existing = e; break }
            }
            let hasNew = infos.contains { !$0.job.dir.pathComponents.contains(where: FolderNames.isVideos) }
            let day = store.dayString(Date())
            var choice: String? = existing
            if existing == nil && hasNew,
               let q = dateQuestion(starts: infos.map(\.start), existing: nil,
                                    example: ("\(FolderNames.videos)/\(day)/Kamera/…", "\(FolderNames.videos)/Kamera/\(day)/…")) {
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
        // je Dreh: welche Merkmale unterscheiden sich?
        var byDreh: [URL: [Info]] = [:]
        for i in infos { byDreh[Self.drehRoot(i.job.dir), default: []].append(i) }
        let tf = DateFormatter(); tf.dateFormat = "HH.mm"
        for (dreh, list) in byDreh {
            // Szenen: chronologisch, neue Szene nach einer Pause > Schwelle (über alle Kameras hinweg)
            var sceneOf: [URL: String] = [:]
            if lv.contains("scene") {
                let cams = list.filter { !$0.cam.hasPrefix(LearnedStore.folderPrefix) }.sorted { $0.start < $1.start }
                var scenes: [[Info]] = []
                var lastEnd = Date.distantPast
                for c in cams {
                    if scenes.isEmpty || c.start.timeIntervalSince(lastEnd) > store.sceneGapMinutes * 60 { scenes.append([c]) }
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
            for i in list {
                if Task.isCancelled { return false }
                currentFile = i.job.url.lastPathComponent
                // Immer eine Ebene, Name enthält alle Merkmale – so erkennt man den Ordner sofort.
                var tags: [String] = [i.cam]
                if let l = i.lens { tags.append(l) }
                if let s = i.speed { tags.append(s) }
                if let o = i.orient { tags.append(o) }
                // Ordner-Baukasten: Werte der aktiven Kriterien in der gewählten Reihenfolge
                let dur = i.end.timeIntervalSince(i.start)
                var parts: [String] = []
                for l in lv {
                    switch l {
                    case "scene": if let s = sceneOf[i.job.url] { parts.append(s) }
                    case "camera": parts.append(i.cam)
                    case "lens": if let x = i.lens { parts.append(x) }
                    case "length": parts.append(dur < store.lengthThreshold ? store.lengthShort : store.lengthLong)
                    case "orientation": if let o = i.orient { parts.append(o) }
                    case "speed": if let s = i.speed { parts.append(s) }
                    case "date": parts.append(store.dayString(i.start))
                    default: break
                    }
                }
                var target = dreh.appendingPathComponent(FolderNames.videos)
                if store.nestLevels {
                    for p in parts { target = target.appendingPathComponent(Self.clean(p)) }
                } else if !parts.isEmpty {
                    target = target.appendingPathComponent(Self.clean(parts.joined(separator: FolderNames.separator)))
                }
                // Was nicht im Ordnernamen steht, als Finder-Tag – Datei bleibt unverändert
                _ = TagRunner.addFinderTags(tags, to: i.job.url)
                if i.cam.hasPrefix(LearnedStore.folderPrefix) {   // eigener Ordner (Exporte, Bildschirmaufnahmen …)
                    target = dreh.appendingPathComponent(FolderNames.extras).appendingPathComponent(String(i.cam.dropFirst(LearnedStore.folderPrefix.count)))
                }
                let here = i.job.url.deletingLastPathComponent().standardizedFileURL.path
                var ok = here == target.standardizedFileURL.path
                if !ok { ok = await move(i.job.url, to: target); if ok { movedVideos += 1 } }
                if ok {
                    counts[i.orient ?? "Video", default: 0] += 1
                    cameras[i.cam, default: 0] += 1
                    if let l = i.lens { lenses[l, default: 0] += 1 }
                    if let s = i.speed { speeds[s, default: 0] += 1 }
                }
                processed += 1
            }
        }
        // leer gewordene alte Unterordner unter „Videos“ aufräumen
        for dreh in byDreh.keys { removeEmptyDirs(dreh.appendingPathComponent(FolderNames.videos)) }
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
                                   message: "„\(name)“ hat noch kein Datum im Namen. Frühestes Aufnahmedatum der Clips: \(startL)." + (multi ? " Aufnahmen bis \(store.dayString(b))." : ""),
                                   icon: "calendar.badge.plus", options: opts, preset: preset,
                                   remember: { [weak self] v in self?.store.renameMode = v })
            guard let ans = await resolve([q]) else { phase = .cancelled; return }
            let choice = ans["rename"] ?? "off"
            guard choice != "off" else { continue }
            let label = choice.hasSuffix("range") ? rangeL : startL
            let newName = Self.clean(choice.hasPrefix("front") ? "\(label) \(name)" : "\(name) \(label)")
            let dst = cur.deletingLastPathComponent().appendingPathComponent(newName)
            if fm.fileExists(atPath: dst.path) {
                hints.append("„\(name)“ nicht umbenannt: „\(newName)“ gibt es dort schon"); continue
            }
            do { try fm.moveItem(at: cur, to: dst) }
            catch {
                problems.append("„\(name)“ konnte nicht in „\(newName)“ umbenannt werden (geöffnet, gesperrt oder schreibgeschützt?): \(error.localizedDescription)")
                continue
            }
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
    func existingDateLayout(_ root: URL) -> String? {
        let kids = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
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
            let items = (try? fm.contentsOfDirectory(atPath: d.path))?.filter { $0 != ".DS_Store" } ?? ["x"]
            if items.isEmpty { try? fm.removeItem(at: d) }   // nur wirklich leere Ordner
        }
    }

    // MARK: Verschieben

    private func move(_ src: URL, to dir: URL) async -> Bool {
        let name = src.lastPathComponent
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { problems.append("\(name): Zielordner konnte nicht angelegt werden (\(error.localizedDescription))"); return false }

        var dst = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) {
            switch await askDuplicate(name: name, folder: dir.path) {
            case .skip: skipped += 1; return false
            case .keepBoth: dst = freeURL(in: dir, for: name)
            case .replace:
                do { try fm.trashItem(at: dst, resultingItemURL: nil) }
                catch { problems.append("\(name): alte Datei ließ sich nicht in den Papierkorb legen"); return false }
            }
        }
        do { try fm.moveItem(at: src, to: dst); return true }
        catch { problems.append("\(name): konnte nicht verschoben werden (\(error.localizedDescription))"); return false }
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

    private func orientation(of asset: AVURLAsset) async -> String? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = size.applying(transform)
        return FolderNames.orientation(width: Double(abs(r.width)), height: Double(abs(r.height)))
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
                && !FolderNames.isOrientation(e.url.lastPathComponent) && !skip.contains(FolderNames.fold(e.url.lastPathComponent))
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
                    && !FolderNames.isOrientation(k.url.lastPathComponent) && !skip.contains(FolderNames.fold(k.url.lastPathComponent))
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
                        if Self.projectExt.contains(ext) { found.append(Item(cam: cam, url: e.url, ext: ext)); continue }
                        if e.isPackage { continue }
                        if FolderNames.isOrientation(name) || skip.contains(FolderNames.fold(name)) { continue }
                        // Sony-Proxys (M4ROOT/SUB) und Vorschaubilder nicht als Clips einsortieren
                        let up = name.uppercased()
                        if (up == "SUB" || up == "THMBNL") && dir.lastPathComponent.uppercased() == "M4ROOT" { proxyDirs += 1; continue }
                        if store.includeSubfolders { stack.append(e.url) } else { cardSkipped = true }
                        continue
                    }
                    found.append(Item(cam: cam, url: e.url, ext: ext))
                }
            }
            if cardSkipped { hints.append("\(cam.lastPathComponent): „Unterordner durchsuchen“ ist aus – Unterordner (z. B. Kartenstruktur) wurden nicht durchsucht") }
        }
        if symlinks > 0 { hints.append("\(plural(symlinks, "Verknüpfung (Alias/Symlink)", "Verknüpfungen (Alias/Symlink)")) übersprungen") }
        if proxyDirs > 0 { hints.append("Sony-Proxy-/Vorschau-Ordner (SUB, THMBNL) unverändert gelassen") }
        fcpLibraries = found.filter { $0.ext == "fcpbundle" }.map(\.url)

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
        let extras = store.levels.filter { ["lens", "length", "speed"].contains($0) }
        var emptied = Set<URL>()   // Ordner, aus denen etwas verschoben wurde → danach aufräumen, wenn leer

        // 3a) Videos analysieren (Ausrichtung, Zusatzebenen, Aufnahmezeit) – noch nichts verschieben
        struct VInfo { let v: Item; let o: String; let parts: [String]; let start: Date }
        var infos: [VInfo] = []
        for v in vids {
            if Task.isCancelled { phase = .cancelled; return }
            currentFile = v.url.lastPathComponent
            guard fm.fileExists(atPath: v.url.path) else { processed += 1; continue }
            let size = (try? v.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 { problems.append("\(v.url.lastPathComponent): leere Datei (0 Byte) – nicht verschoben"); processed += 1; continue }
            let asset = AVURLAsset(url: v.url)
            guard let o = await orientation(of: asset) else {
                problems.append("\(v.url.lastPathComponent): Bildgröße nicht lesbar (beschädigt?) – nicht verschoben"); processed += 1; continue
            }
            let stem = v.url.deletingPathExtension().lastPathComponent
            let dir = v.url.deletingLastPathComponent()
            let (st, en) = await recordingTime(asset, url: v.url)
            var parts: [String] = []
            for l in extras {
                switch l {
                case "lens":
                    let sib = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    parts.append(await lensName(for: v.url, asset: asset, siblings: sib) ?? "Objektiv unbekannt")
                case "length":
                    parts.append(en.timeIntervalSince(st) < store.lengthThreshold ? store.lengthShort : store.lengthLong)
                case "speed":
                    let srt = [dir, v.cam.appendingPathComponent(FolderNames.side), v.cam.appendingPathComponent("Begleitdateien")]
                        .flatMap { d in [stem + ".SRT", stem + ".srt"].map { d.appendingPathComponent($0) } }
                        .first { fm.fileExists(atPath: $0.path) }
                    if let srt {
                        switch SRTSpeed.analyze(srt) {
                        case .speed(let kmh):
                            parts.append(kmh >= store.standMin && kmh <= store.standMax ? "Stand"
                                       : kmh >= store.moveMin && kmh <= store.moveMax ? "Fahrt" : "Dazwischen")
                        case .noGPS: parts.append("Ohne GPS")
                        case .unreadable: break
                        }
                    }
                default: break
                }
            }
            infos.append(VInfo(v: v, o: o, parts: parts, start: st))
            noteStart(st, for: v.url)
        }

        // 3b) Rückfragen vor dem Verschieben (nur wenn relevant). Vorhandene Tagesordner → Struktur weiterführen.
        var existing: String? = nil
        if ownCams.contains(where: \.inDayFolder) { existing = "top" }
        else if ownCams.contains(where: { existingDateLayout($0.url) == "top" }) { existing = "under" }
        var dateChoice = "off"
        if store.levels.contains("date") { dateChoice = existing ?? "under" }
        else if let q = dateQuestion(starts: infos.map(\.start), existing: existing,
                                     example: ("Dreh/\(store.dayString(Date()))/A1/Hochkant", "Dreh/A1/\(store.dayString(Date()))/Hochkant")) {
            guard let a = await resolve([q]) else { phase = .cancelled; return }
            dateChoice = a["date"] ?? "off"
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

        // 3c) Videos verschieben: <Wurzel>/[Zusatzebenen]/Hochkant|Quer
        for i in infos {
            if Task.isCancelled { phase = .cancelled; return }
            let v = i.v
            currentFile = v.url.lastPathComponent
            defer { processed += 1 }
            guard fm.fileExists(atPath: v.url.path) else { continue }
            let dir = v.url.deletingLastPathComponent()
            let base = root(for: v.cam, day: store.dayString(i.start))
            rootOfStem[v.cam.path, default: []].append((stem: v.url.deletingPathExtension().lastPathComponent, root: base))
            var target = base
            if store.nestLevels { for p in i.parts { target = childDir(target, p) } }
            else if !i.parts.isEmpty { target = childDir(target, i.parts.joined(separator: FolderNames.separator)) }
            target = childDir(target, i.o)
            if samePath(dir, target) { continue }
            if await move(v.url, to: target) {
                movedVideos += 1
                counts[i.o, default: 0] += 1
                cameras[v.cam.lastPathComponent, default: 0] += 1
                for p in i.parts where ["Stand", "Fahrt", "Dazwischen", "Ohne GPS"].contains(p) { speeds[p, default: 0] += 1 }
                if extras.contains("lens"), let li = extras.firstIndex(of: "lens"), li < i.parts.count { lenses[i.parts[li], default: 0] += 1 }
                if i.o == FolderNames.portrait { stats[v.cam.path]?.hochkant += 1 }
                else if i.o == FolderNames.landscape { stats[v.cam.path]?.quer += 1 } else { stats[v.cam.path]?.quadrat += 1 }
                _ = TagRunner.addFinderTags([v.cam.lastPathComponent, i.o], to: target.appendingPathComponent(v.url.lastPathComponent))
                emptied.insert(dir)
            }
        }

        // 4) Alles andere bleibt im Kameraordner: Begleitdateien, Fotos, Extras/<Musik|ZIP|FCP>
        for (f, cat) in others {
            if Task.isCancelled { phase = .cancelled; return }
            currentFile = f.url.lastPathComponent
            defer { processed += 1 }
            guard fm.fileExists(atPath: f.url.path) else { continue }
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
            default: continue
            }
            if samePath(dir, target) { continue }
            if await move(f.url, to: target) {
                if cat == .photo { counts["Fotos", default: 0] += 1 } else { sideCounts[key, default: 0] += 1 }
                stats[f.cam.path]?.other += 1
                emptied.insert(dir)
            }
        }
        currentFile = ""

        // 5) Nur wirklich leer gewordene Kartenordner entfernen (bis hoch zum Kameraordner)
        for d in emptied.sorted(by: { $0.path.count > $1.path.count }) {
            guard let cam = cams.first(where: { d.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { continue }
            var cur = d
            while cur.standardizedFileURL.path.count > cam.standardizedFileURL.path.count {
                let items = ((try? fm.contentsOfDirectory(atPath: cur.path)) ?? ["x"]).filter { $0 != ".DS_Store" }
                guard items.isEmpty else { break }
                try? fm.removeItem(at: cur)
                cur = cur.deletingLastPathComponent()
            }
        }

        if dateChoice == "top" {
            for c in ownCams where c.group != nil && !c.inDayFolder {
                let items = ((try? fm.contentsOfDirectory(atPath: c.url.path)) ?? ["x"]).filter { $0 != ".DS_Store" }
                if items.isEmpty { try? fm.removeItem(at: c.url) }   // nur wenn wirklich leer
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
        let suffixes = store.gyroSuffixList
        let bases = folders
        let offer: [URL] = await Task.detached(priority: .userInitiated) {
            let r = GyroRunner.collectGyroClips(in: bases, suffixes: suffixes)
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
