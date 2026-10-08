import Foundation
import AVFoundation
import AppKit

// MARK: - Modelle

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

enum Phase { case idle, scanning, sorting, done, cancelled }

private enum Kind { case video, photo, side(String) }

private struct Job {
    let base: URL
    let url: URL
    let kind: Kind
}

// MARK: - Sortierer

@MainActor
final class Sorter: ObservableObject {
    @Published var folders: [URL] = []
    @Published var phase: Phase = .idle
    @Published var total = 0
    @Published var processed = 0
    @Published var currentFile = ""
    @Published var counts: [String: Int] = [:]          // Hochkant, Quer, Fotos, XML, LRF, SRT
    @Published var cameras: [String: Int] = [:]
    @Published var skipped = 0
    @Published var problems: [String] = []
    @Published var pendingDuplicate: DuplicateRequest?

    static let videoExt: Set<String> = ["mp4", "mov", "m4v"]
    static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "hif", "tif", "tiff", "raw"]
    static let sideExt: Set<String> = ["xml", "lrf", "srt"]

    private var dupForAll: DupChoice?
    private var task: Task<Void, Never>?
    private let fm = FileManager.default

    var progress: Double { total == 0 ? 0 : Double(processed) / Double(total) }
    var movedTotal: Int { counts.values.reduce(0, +) }

    func addFolders(_ urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, !folders.contains(u) {
                folders.append(u)
            }
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
        counts = [:]; cameras = [:]; skipped = 0; problems = []; dupForAll = nil
    }

    func start() {
        guard !folders.isEmpty else { return }
        counts = [:]; cameras = [:]; skipped = 0; problems = []; dupForAll = nil
        processed = 0
        phase = .scanning
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        if let p = pendingDuplicate { pendingDuplicate = nil; p.continuation.resume(returning: (.skip, false)) }
    }

    func answerDuplicate(_ choice: DupChoice, forAll: Bool) {
        guard let p = pendingDuplicate else { return }
        pendingDuplicate = nil
        p.continuation.resume(returning: (choice, forAll))
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(folders)
    }

    // MARK: Ablauf

    private func run() async {
        var videos: [Job] = []
        var others: [Job] = []
        var siblingNames: [URL: Set<String>] = [:]

        for base in folders {
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else {
                problems.append("\(base.lastPathComponent): kein Zugriff auf den Ordner")
                continue
            }
            siblingNames[base] = Set(items.map { $0.lastPathComponent })
            for u in items {
                let isFile = (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }
                let ext = u.pathExtension.lowercased()
                if Self.videoExt.contains(ext) { videos.append(Job(base: base, url: u, kind: .video)) }
                else if Self.photoExt.contains(ext) { others.append(Job(base: base, url: u, kind: .photo)) }
                else if Self.sideExt.contains(ext) { others.append(Job(base: base, url: u, kind: .side(ext.uppercased()))) }
            }
        }

        let jobs = videos + others
        total = jobs.count
        phase = .sorting

        for job in jobs {
            if Task.isCancelled { phase = .cancelled; return }
            currentFile = job.url.lastPathComponent
            guard fm.fileExists(atPath: job.url.path) else { processed += 1; continue }

            switch job.kind {
            case .video:
                let asset = AVURLAsset(url: job.url)
                guard let o = await orientation(of: asset) else {
                    problems.append("\(job.url.lastPathComponent): Video konnte nicht gelesen werden")
                    break
                }
                let cam = await camera(for: job.url, asset: asset, siblings: siblingNames[job.base] ?? [])
                let target = job.base.appendingPathComponent("Videos").appendingPathComponent(cam).appendingPathComponent(o)
                if await move(job.url, to: target) {
                    counts[o, default: 0] += 1
                    cameras[cam, default: 0] += 1
                }
            case .photo:
                if await move(job.url, to: job.base.appendingPathComponent("Fotos")) { counts["Fotos", default: 0] += 1 }
            case .side(let key):
                if await move(job.url, to: job.base.appendingPathComponent(key)) { counts[key, default: 0] += 1 }
            }
            withAnimationSafe { processed += 1 }
        }
        currentFile = ""
        phase = Task.isCancelled ? .cancelled : .done
    }

    private func withAnimationSafe(_ body: () -> Void) { body() }

    // MARK: Verschieben

    private func move(_ src: URL, to dir: URL) async -> Bool {
        let name = src.lastPathComponent
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { problems.append("\(name): Zielordner konnte nicht angelegt werden"); return false }

        var dst = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) {
            let choice = await askDuplicate(name: name, folder: dir.path)
            switch choice {
            case .skip:
                skipped += 1
                return false
            case .keepBoth:
                dst = freeURL(in: dir, for: name)
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
        let (choice, forAll): (DupChoice, Bool) = await withCheckedContinuation { (c: CheckedContinuation<(DupChoice, Bool), Never>) in
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
            let n = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let u = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }

    // MARK: Erkennung

    private func orientation(of asset: AVURLAsset) async -> String? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = size.applying(transform)
        let w = abs(r.width), h = abs(r.height)
        guard w > 0, h > 0 else { return nil }
        return h > w ? "Hochkant" : "Quer"
    }

    private func camera(for url: URL, asset: AVURLAsset, siblings: Set<String>) async -> String {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent

        // Sony: Begleit-XML
        for x in [stem + "M01.XML", stem + "M01.xml"] where siblings.contains(x) {
            let xmlURL = url.deletingLastPathComponent().appendingPathComponent(x)
            if let s = try? String(contentsOf: xmlURL, encoding: .utf8),
               s.range(of: "manufacturer=\"Sony\"", options: .caseInsensitive) != nil {
                return "Sony"
            }
        }

        // Metadaten im Video
        var make = "", model = ""
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let key = (item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "").lowercased()
                guard let val = try? await item.load(.stringValue), !val.isEmpty else { continue }
                if key.contains("model"), model.isEmpty { model = val }
                else if (key.contains("make") || key.contains("manufacturer")), make.isEmpty { make = val }
            }
        }
        let all = "\(make) \(model)".trimmingCharacters(in: .whitespaces)
        let low = all.lowercased()
        if low.contains("iphone") { return "iPhone" }
        if low.contains("sony") { return "Sony" }
        if low.contains("dji") {
            var m = model.isEmpty ? make : model
            if !m.lowercased().contains("dji") { m = "DJI " + m }
            return clean(m)
        }
        if !all.isEmpty {
            if !model.isEmpty, model.lowercased().hasPrefix(make.lowercased()) { return clean(model) }
            return clean(all)
        }

        // Dateiname als Notlösung
        let up = name.uppercased()
        if up.hasPrefix("DJI_") { return "DJI" }
        if up.range(of: #"^C\d{4}"#, options: .regularExpression) != nil { return "Sony" }
        if up.hasPrefix("IMG_") && up.hasSuffix(".MOV") { return "iPhone" }
        if up.range(of: #"^G[HXSL]\d+"#, options: .regularExpression) != nil { return "GoPro" }
        return "Unbekannt"
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
         .replacingOccurrences(of: ":", with: "-")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
