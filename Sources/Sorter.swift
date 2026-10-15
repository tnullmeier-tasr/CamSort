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
    @Published var pendingCamera: CameraRequest?
    @Published var pendingExtensions: ExtensionRequest?

    let store: LearnedStore

    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "insv", "mts", "m2ts", "avi", "mkv", "3gp", "mxf"]
    static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "hif", "tif", "tiff", "raw",
                                        "cr2", "cr3", "nef", "raf", "orf", "rw2", "insp", "webp", "gif", "srw", "pef"]
    static let musicExt: Set<String> = ["mp3", "wav", "aac", "m4a", "aif", "aiff", "flac", "ogg", "opus", "wma", "caf"]
    static let archiveExt: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz"]
    static let projectExt: Set<String> = ["fcpbundle", "fcpxml", "fcpxmld", "fcpxd"]
    static let sideExt: Set<String> = ["gyroflow", "xml", "lrf", "srt", "thm", "aae", "xmp", "bim", "lrv"]
    static let alwaysIgnore: Set<String> = ["ds_store", "db", "ini", "localized"]
    static let fixedOutput: Set<String> = ["Videos", "Fotos", "Musik", "ZIP", "FCP", "Hochkant", "Quer", "Stabilisiert", "Original", "Gyroflow-Projekte"]

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
        problems = []; hints = []; dupForAll = nil; skipAsking = false; askedCameras = [:]; gyroMoved = 0
    }

    func start() {
        guard !folders.isEmpty else { return }
        clearResults(); processed = 0
        phase = .scanning
        task = Task {
            stepLabel = alreadySorted ? "Ordner schon sortiert – suche neue Dateien" : "Schritt 1: Sortieren"
            await run()
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
        folders.contains { fm.fileExists(atPath: $0.appendingPathComponent("Videos").path) }
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
                if store.compactLayout && u.lastPathComponent == "Videos" { return true }
                if store.compactLayout && u.pathComponents.contains("Videos") {
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

        // Unbekannte Dateitypen erfragen
        var unknown: [String: (example: String, count: Int)] = [:]
        for f in found where category(for: f.ext) == nil {
            let cur = unknown[f.ext]
            unknown[f.ext] = (cur?.example ?? f.url.lastPathComponent, (cur?.count ?? 0) + 1)
        }
        var sessionExt: [String: FileCategory] = [:]
        if !unknown.isEmpty {
            let list = unknown.map { (ext: $0.key, example: $0.value.example, count: $0.value.count) }.sorted { $0.ext < $1.ext }
            let answer: [String: FileCategory]? = await withCheckedContinuation { c in
                pendingExtensions = ExtensionRequest(extensions: list, continuation: c)
            }
            if Task.isCancelled { phase = .cancelled; return }
            sessionExt = answer ?? [:]
        }

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
                    if await move(job.url, to: dreh.appendingPathComponent("Begleitdateien")) { sideCounts[job.ext.uppercased(), default: 0] += 1 }
                case .photo:
                    if await move(job.url, to: dreh.appendingPathComponent("Fotos")) { counts["Fotos", default: 0] += 1 }
                case .music, .archive, .project:
                    let folder = job.cat.folder ?? "Sonstiges"
                    if await move(job.url, to: dreh.appendingPathComponent(folder)) { sideCounts[folder, default: 0] += 1 }
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

    // MARK: Kompakte Struktur

    static let cardMarkers: Set<String> = ["DCIM", "PRIVATE", "M4ROOT", "CLIP", "AVCHD", "MP_ROOT", "100MEDIA", "101MEDIA"]

    /// Dreh-Ordner: über „Videos“ bzw. über Kartenordnern (DCIM, PRIVATE …), sonst der Ordner selbst.
    static func drehRoot(_ dir: URL) -> URL {
        let c = dir.pathComponents
        if let i = c.firstIndex(of: "Videos") { return URL(fileURLWithPath: NSString.path(withComponents: Array(c[..<i]))) }
        if let i = c.firstIndex(where: { cardMarkers.contains($0.uppercased()) }) {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(c[..<i])))
        }
        return dir
    }

    private func sidecar(_ stem: String, exts: [String], near dir: URL) -> URL? {
        let dreh = Self.drehRoot(dir)
        let dirs = [dir, dreh.appendingPathComponent("Begleitdateien"), dreh.appendingPathComponent("SRT")]
        for d in dirs { for e in exts {
            let u = d.appendingPathComponent(stem + e)
            if fm.fileExists(atPath: u.path) { return u }
        } }
        return nil
    }

    /// Analysiert alle Videos je Dreh und legt nur die Ordner an, die sich dort unterscheiden.
    private func layoutCompact(_ videos: [Job], siblings: [URL: Set<String>]) async -> Bool {
        struct Info { let job: Job; let cam: String; let lens: String?; let speed: String?; let orient: String? }
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
            if store.sortByLens { lens = await lensName(for: job.url, asset: asset, siblings: sib) ?? "Objektiv unbekannt" }
            var speed: String? = nil
            if store.droneBySpeed, let srt = sidecar(stem, exts: [".SRT", ".srt"], near: job.dir) {
                switch SRTSpeed.analyze(srt) {
                case .speed(let kmh):
                    speed = kmh >= store.standMin && kmh <= store.standMax ? "Stand"
                          : kmh >= store.moveMin && kmh <= store.moveMax ? "Fahrt" : "Dazwischen"
                    hints.append(String(format: "%@: Ø %.1f km/h → %@", job.url.lastPathComponent, kmh, speed!))
                case .noGPS: speed = "Ohne GPS"
                case .unreadable: break
                }
            }
            infos.append(Info(job: job, cam: cam, lens: lens, speed: speed, orient: o))
        }
        // je Dreh: welche Merkmale unterscheiden sich?
        var byDreh: [URL: [Info]] = [:]
        for i in infos { byDreh[Self.drehRoot(i.job.dir), default: []].append(i) }
        for (dreh, list) in byDreh {
            for i in list {
                if Task.isCancelled { return false }
                currentFile = i.job.url.lastPathComponent
                // Immer eine Ebene, Name enthält alle Merkmale – so erkennt man den Ordner sofort.
                var parts: [String] = [i.cam]
                if let l = i.lens { parts.append(l) }
                if let s = i.speed { parts.append(s) }
                if let o = i.orient { parts.append(o) }
                var target = dreh.appendingPathComponent("Videos")
                if !parts.isEmpty { target = target.appendingPathComponent(Self.clean(parts.joined(separator: " · "))) }
                let here = i.job.url.deletingLastPathComponent().standardizedFileURL.path
                var ok = here == target.standardizedFileURL.path
                if !ok { ok = await move(i.job.url, to: target) }
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
        for dreh in byDreh.keys { removeEmptyDirs(dreh.appendingPathComponent("Videos")) }
        return true
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
        let w = abs(r.width), h = abs(r.height)
        guard w > 0, h > 0 else { return nil }
        return h > w ? "Hochkant" : "Quer"
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
        for x in [stem + "M01.XML", stem + "M01.xml"] where siblings.contains(x) {
            if let s = try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(x), encoding: .utf8),
               let n = Self.sonyName(fromXML: s) { return known(n, "Sony-XML") }
        }
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
        let hint = starts(#"^\d{8}_\d{6}"#) ? "Vermutlich ein Android-Handy (z. B. Samsung)." : "Kamera nicht erkannt."
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
        for x in [stem + "M01.XML", stem + "M01.xml"] where siblings.contains(x) {
            if let s = try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(x), encoding: .utf8),
               let l = Self.lens(fromXML: s) { return l }
        }
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
