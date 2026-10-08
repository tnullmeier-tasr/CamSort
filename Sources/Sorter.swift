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
    let hint: String          // was die App selbst gefunden hat (z. B. Marke)
    let continuation: CheckedContinuation<String?, Never>
    init(fileName: String, hint: String, continuation: CheckedContinuation<String?, Never>) {
        self.fileName = fileName; self.hint = hint; self.continuation = continuation
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
    let base: URL
    let url: URL
    let cat: FileCategory
    let sideKey: String
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
    @Published var skipped = 0
    @Published var ignored = 0
    @Published var problems: [String] = []
    @Published var hints: [String] = []
    @Published var pendingDuplicate: DuplicateRequest?
    @Published var pendingCamera: CameraRequest?
    @Published var pendingExtensions: ExtensionRequest?

    let store: LearnedStore

    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "insv", "mts", "m2ts", "avi", "mkv", "3gp", "lrv"]
    static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "hif", "tif", "tiff", "raw",
                                        "cr2", "cr3", "nef", "raf", "orf", "rw2", "insp", "webp", "gif", "srw", "pef"]
    static let sideExt: Set<String> = ["xml", "lrf", "srt", "thm", "aae", "xmp", "bim", "dat"]
    static let alwaysIgnore: Set<String> = ["ds_store", "db", "ini"]

    private var dupForAll: DupChoice?
    private var askedCameras: [String: String] = [:]   // Regel-Schlüssel -> Antwort in diesem Durchlauf
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
        counts = [:]; sideCounts = [:]; cameras = [:]; skipped = 0; ignored = 0
        problems = []; hints = []; dupForAll = nil; askedCameras = [:]
    }

    func start() {
        guard !folders.isEmpty else { return }
        clearResults(); processed = 0
        phase = .scanning
        task = Task { await run() }
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
        if let c = clean, remember { store.learnCamera(fileName: p.fileName, camera: c) }
        p.continuation.resume(returning: clean)
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
        if Self.sideExt.contains(ext) { return .side }
        if Self.alwaysIgnore.contains(ext) || ext.isEmpty { return .ignore }
        return nil
    }

    // MARK: Ablauf

    private func run() async {
        var found: [(base: URL, url: URL, ext: String)] = []
        var siblings: [URL: Set<String>] = [:]

        for base in folders {
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else {
                problems.append("\(base.lastPathComponent): kein Zugriff auf den Ordner – bitte in den Systemeinstellungen unter Datenschutz & Sicherheit erlauben")
                continue
            }
            siblings[base] = Set(items.map { $0.lastPathComponent })
            for u in items where ((try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) {
                found.append((base, u, u.pathExtension.lowercased()))
            }
        }

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
            let job = Job(base: f.base, url: f.url, cat: cat, sideKey: f.ext.uppercased())
            switch cat {
            case .video: videos.append(job)
            case .photo, .side: others.append(job)
            case .ignore: if !Self.alwaysIgnore.contains(f.ext) { ignored += 1 }
            }
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
                guard let cam = await camera(for: job.url, asset: asset, siblings: siblings[job.base] ?? []) else {
                    phase = .cancelled; return
                }
                var target = job.base.appendingPathComponent("Videos").appendingPathComponent(cam)
                if let o { target = target.appendingPathComponent(o) }
                else { hints.append("\(job.url.lastPathComponent): Ausrichtung nicht lesbar – liegt direkt in Videos/\(cam)") }
                if await move(job.url, to: target) {
                    counts[o ?? "Video", default: 0] += 1
                    cameras[cam, default: 0] += 1
                }
            case .photo:
                if await move(job.url, to: job.base.appendingPathComponent("Fotos")) { counts["Fotos", default: 0] += 1 }
            case .side:
                if await move(job.url, to: job.base.appendingPathComponent(job.sideKey)) { sideCounts[job.sideKey, default: 0] += 1 }
            case .ignore: break
            }
            processed += 1
        }
        currentFile = ""
        phase = Task.isCancelled ? .cancelled : .done
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
        let name = url.lastPathComponent

        // 1) Gelernt
        if let learned = store.camera(for: name) { return learned }

        // 2) Erkannt
        let detected = await detectCamera(url: url, asset: asset, siblings: siblings)
        if let d = detected.name { return d }

        // 3) Nachfragen (einmal pro Dateimuster und Durchlauf)
        let key = LearnedStore.prefix(of: name) + "|" + url.pathExtension.lowercased()
        if let a = askedCameras[key] { return a }
        let answer: String? = await withCheckedContinuation { c in
            pendingCamera = CameraRequest(fileName: name, hint: detected.hint, continuation: c)
        }
        if Task.isCancelled { return nil }
        let result = answer ?? "Unbekannt"
        askedCameras[key] = result
        return result
    }

    private func detectCamera(url: URL, asset: AVURLAsset, siblings: Set<String>) async -> (name: String?, hint: String) {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent

        // Sony: Begleit-XML (enthält auch das Modell)
        for x in [stem + "M01.XML", stem + "M01.xml"] where siblings.contains(x) {
            if let s = try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(x), encoding: .utf8),
               s.range(of: "manufacturer=\"Sony\"", options: .caseInsensitive) != nil { return ("Sony", "") }
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
        if let n = nameFrom(make: make, model: model) { return (n, "") }

        // Markenkennung in der Datei selbst (Canon, Insta360, GoPro, DJI, Samsung …)
        let brand = scanBrand(url)
        if let b = brand, b != "DJI" { return (b, "") }

        // Dateiname
        let up = name.uppercased()
        func starts(_ re: String) -> Bool { up.range(of: re, options: .regularExpression) != nil }
        if starts(#"^C\d{4}"#) { return ("Sony", "") }
        if starts(#"^IMG_.*\.MOV$"#) { return ("iPhone", "") }
        if starts(#"^G[HXSL]\d+"#) || starts(#"^GOPR\d+"#) { return ("GoPro", "") }
        if starts(#"^MVI_\d+"#) { return ("Canon", "") }
        if starts(#"^PXL_\d+"#) { return ("Google Pixel", "") }
        if starts(#"\.INSV$"#) || starts(#"^VID_\d{8}_\d{6}_\d{2}_\d+"#) { return ("Insta360", "") }

        // DJI: Marke klar, Modell unklar → nachfragen, damit Action/Mini getrennt werden können
        if brand == "DJI" || up.hasPrefix("DJI_") { return (nil, "Vermutlich DJI – welches Modell?") }
        if starts(#"^\d{8}_\d{6}"#) { return (nil, "Vermutlich ein Android-Handy (z. B. Samsung)") }
        return (nil, "")
    }

    private func nameFrom(make: String, model: String) -> String? {
        let mk = make.trimmingCharacters(in: .whitespaces), md = model.trimmingCharacters(in: .whitespaces)
        let all = "\(mk) \(md)".lowercased()
        guard !mk.isEmpty || !md.isEmpty else { return nil }
        if all.contains("iphone") { return "iPhone" }
        if all.contains("ipad") { return "iPad" }
        if all.contains("sony") { return "Sony" }
        if all.contains("dji") {
            var m = md.isEmpty ? mk : md
            if !m.lowercased().contains("dji") { m = "DJI " + m }
            return Self.clean(m)
        }
        if mk.lowercased() == "samsung" {
            return Self.clean("Samsung " + Self.samsungName(md))
        }
        if !md.isEmpty, md.lowercased().hasPrefix(mk.lowercased()) { return Self.clean(md) }
        let brand = mk.prefix(1).uppercased() + mk.dropFirst()
        return Self.clean("\(brand) \(md)")
    }

    private static func samsungName(_ model: String) -> String {
        // SM-S9xx → Galaxy S, SM-A → Galaxy A usw. – sonst Modellnummer
        let m = model.uppercased()
        let map: [(String, String)] = [("SM-S9", "Galaxy S"), ("SM-A", "Galaxy A"), ("SM-F", "Galaxy Z"), ("SM-M", "Galaxy M"), ("SM-G", "Galaxy")]
        for (p, n) in map where m.hasPrefix(p) { return "\(n) (\(model))" }
        return model
    }

    /// Sucht Herstellerkennungen in Anfang und Ende der Datei (nur lesen).
    private func scanBrand(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 512 * 1024
        var data = (try? h.read(upToCount: chunk)) ?? Data()
        if let size = try? h.seekToEnd(), size > UInt64(chunk) {
            try? h.seek(toOffset: size - UInt64(chunk))
            data.append((try? h.read(upToCount: chunk)) ?? Data())
        }
        let brands: [(String, String)] = [
            ("Insta360", "Insta360"), ("Canon", "Canon"), ("GoPro", "GoPro"), ("SAMSUNG", "Samsung"),
            ("samsung", "Samsung"), ("Panasonic", "Panasonic"), ("FUJIFILM", "Fujifilm"), ("NIKON", "Nikon"),
            ("Nikon", "Nikon"), ("OLYMPUS", "Olympus"), ("OM Digital", "OM System"), ("Blackmagic", "Blackmagic"),
            ("Xiaomi", "Xiaomi"), ("HUAWEI", "Huawei"), ("OnePlus", "OnePlus"), ("DJI", "DJI"),
        ]
        for (needle, brand) in brands where data.range(of: Data(needle.utf8)) != nil { return brand }
        return nil
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
         .replacingOccurrences(of: ":", with: "-")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
