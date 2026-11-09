import Foundation
import AVFoundation
import ImageIO
import SwiftUI
import AppKit

/// Final-Cut-Mediathek aus dem sortierten Ordner: CamSort schreibt pro Dreh/Projekt eine FCPXML-Datei
/// „<Ordner>.fcpxml“, die Final Cut beim Öffnen als neue Mediathek „<Ordner>.fcpbundle“ im selben Ordner anlegt
/// (Importoption „library location“). Medien werden nur verknüpft („copy assets“ = 0) – nie kopiert oder verändert.
/// Schlagwörter kommen aus der Ordnerstruktur (Kamera, Objektiv, Ausrichtung, fps, Länge, Szene, eigene Ordner) und den Finder-Tags.
@MainActor
final class FCPLibraryBuilder: ObservableObject {
    static let shared = FCPLibraryBuilder()

    enum State: Equatable { case idle, scanning, ready, writing, finished, failed(String) }
    enum Kind: String, Codable { case video, photo, audio }

    struct Item: Hashable {
        let url: URL
        let rel: String          // Pfad relativ zum Dreh (für das Gedächtnis)
        let kind: Kind
        var keywords: [String]
        let role: String?        // Audio-Rolle (music / effects)
    }

    struct Plan: Identifiable {
        var id: String { dreh.path }
        let dreh: URL
        let name: String
        let library: URL
        let items: [Item]        // nur noch nicht importierte
        let total: Int           // alle gefundenen Medien
        let libraryExists: Bool
        let foreign: Bool        // Mediathek existiert, aber nicht von CamSort angelegt
        var isAddition: Bool { libraryExists }
        var upToDate: Bool { items.isEmpty }
    }

    /// Unsichtbares Gedächtnis im Dreh-Ordner: welche Dateien schon in der Mediathek sind
    struct Memo: Codable {
        var library: String
        var imported: [String]
        var events: [String]
    }
    nonisolated static let memoName = ".camsort-fcp.json"

    @Published var state: State = .idle
    @Published var plans: [Plan] = []
    @Published var outputs: [URL] = []
    @Published var messages: [String] = []
    @Published var errors: [String] = []
    /// Rückfrage für diesen Lauf beantwortet / Anlegen wartet auf Gyroflow
    @Published var answered = false
    @Published var waitingForGyro = false
    private(set) var lastFolders: [URL] = []
    /// Warum es keine Pläne gibt (für die Karte)
    @Published var emptyReason: String = ""

    // Einstellungen
    private static let d = UserDefaults.standard
    /// "ask" | "always" | "never"
    @Published var mode: String = d.string(forKey: "fcpLibMode") ?? "ask" { didSet { Self.d.set(mode, forKey: "fcpLibMode") } }
    @Published var includePhotos: Bool = d.object(forKey: "fcpLibPhotos") as? Bool ?? true { didSet { Self.d.set(includePhotos, forKey: "fcpLibPhotos") } }
    @Published var includeOriginals: Bool = d.object(forKey: "fcpLibOriginals") as? Bool ?? true { didSet { Self.d.set(includeOriginals, forKey: "fcpLibOriginals") } }

    var totalNew: Int { plans.reduce(0) { $0 + $1.items.count } }
    var busy: Bool { state == .scanning || state == .writing }

    /// Neuer Lauf (DoneView erscheint): Rückfrage wieder zulassen
    func resetForRun(_ folders: [URL], force: Bool = false) {
        let norm = folders.map { $0.standardizedFileURL }
        guard force || norm != lastFolders || state == .idle else { return }
        guard !busy else { return }
        lastFolders = norm
        emptyReason = ""
        answered = false; waitingForGyro = false
        outputs = []; messages = []; errors = []; plans = []; state = .idle
    }

    // MARK: Planen

    func prepare(folders: [URL], suffixes: [String]) {
        state = .scanning
        let ph = includePhotos, orig = includeOriginals
        let drehs = Self.drehs(for: folders)
        var out: [Plan] = []
        for dr in drehs {
            let others = drehs.filter { $0 != dr }
            if let p = Self.plan(dreh: dr, excluding: others, suffixes: suffixes, photos: ph, originals: orig) { out.append(p) }
        }
        plans = out
        if folders.isEmpty { emptyReason = "Kein Ordner gewählt." }
        else if drehs.isEmpty { emptyReason = "In \(folders.map(\.lastPathComponent).joined(separator: ", ")) liegen keine sortierten Clips (erwartet: „Videos/…“ oder Kameraordner mit Hochkant/Quer)." }
        else if out.isEmpty { emptyReason = "Die Dreh-Ordner \(drehs.map(\.lastPathComponent).joined(separator: ", ")) enthalten keine passenden Medien." }
        else { emptyReason = "" }
        state = .ready
    }

    /// Dreh-/Projektordner wie bei „Beste Momente“: Ordner über „Videos“, Projektordner, sonst der gewählte Ordner
    static func drehs(for folders: [URL]) -> [URL] {
        var set: [URL] = []
        for f in folders {
            guard let en = FileManager.default.enumerator(at: f, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                guard Sorter.videoExt.contains(u.pathExtension.lowercased()), FolderNames.isSortedVideoPath(u.pathComponents) else { continue }
                let d: URL
                if let p = projectFolder(of: u, below: f) {
                    d = p   // Projekt-Trennung: eine Mediathek je Projektordner (.camsort-projekt)
                } else {
                    let own = !u.pathComponents.contains(where: FolderNames.isVideos)
                    d = (own ? f : Sorter.drehRoot(u.deletingLastPathComponent())).standardizedFileURL
                }
                if !set.contains(d) { set.append(d) }
            }
        }
        return set.sorted { $0.path < $1.path }
    }

    /// Nächster Ordner mit `.camsort-projekt` zwischen dem gewählten Ordner `base` (einschließlich) und dem Clip
    nonisolated static func projectFolder(of clip: URL, below base: URL) -> URL? {
        let fm = FileManager.default
        let b = base.standardizedFileURL.pathComponents
        var dir = clip.deletingLastPathComponent().standardizedFileURL
        while dir.pathComponents.count >= b.count {
            if fm.fileExists(atPath: dir.appendingPathComponent(Sorter.projectMarker).path) { return dir }
            if dir.pathComponents.count == b.count { break }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    /// Enthält der Ordner (oder er selbst) Projektordner von CamSort?
    nonisolated static func hasProjectFolders(_ base: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: base.appendingPathComponent(Sorter.projectMarker).path) { return true }
        let kids = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
        return kids.contains { !$0.hasPrefix(".") && fm.fileExists(atPath: base.appendingPathComponent($0).appendingPathComponent(Sorter.projectMarker).path) }
    }

    nonisolated static func libraryURL(_ dreh: URL) -> URL {
        dreh.appendingPathComponent(dreh.lastPathComponent + ".fcpbundle", isDirectory: false)
    }

    nonisolated static func readMemo(_ dreh: URL) -> Memo? {
        guard let data = try? Data(contentsOf: dreh.appendingPathComponent(memoName)) else { return nil }
        return try? JSONDecoder().decode(Memo.self, from: data)
    }

    nonisolated static func plan(dreh: URL, excluding others: [URL], suffixes: [String], photos: Bool, originals: Bool) -> Plan? {
        let all = collect(dreh: dreh, excluding: others, suffixes: suffixes, photos: photos, originals: originals)
        guard !all.isEmpty else { return nil }
        let lib = libraryURL(dreh)
        let exists = FileManager.default.fileExists(atPath: lib.path)
        let memo = readMemo(dreh)
        var items = all
        if exists, let m = memo {
            let done = Set(m.imported)
            items = all.filter { !done.contains($0.rel) }
        }
        return Plan(dreh: dreh, name: dreh.lastPathComponent, library: lib, items: items, total: all.count,
                    libraryExists: exists, foreign: exists && memo == nil)
    }

    /// Alle Medien eines Drehs mit Schlagwörtern aus der Ordnerstruktur
    nonisolated static func collect(dreh: URL, excluding others: [URL], suffixes: [String], photos: Bool, originals: Bool) -> [Item] {
        let fm = FileManager.default
        let skipDirs: Set<String> = Set([FolderNames.side, "Begleitdateien", FolderNames.gyroProjects, FolderNames.checkFolder, "ZIP", "FCP", "Sonstiges"].map(FolderNames.fold))
        let otherPaths = Set(others.map { $0.standardizedFileURL.path })
        let base = dreh.standardizedFileURL.pathComponents
        var raw: [(url: URL, kind: Kind, dirs: [String])] = []
        guard let en = fm.enumerator(at: dreh, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        while let u = en.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true {
                if v?.isPackage == true || skipDirs.contains(FolderNames.fold(u.lastPathComponent)) || otherPaths.contains(u.standardizedFileURL.path) { en.skipDescendants() }
                continue
            }
            let ext = u.pathExtension.lowercased()
            let kind: Kind
            if Sorter.videoExt.contains(ext) { kind = .video }
            else if Sorter.photoExt.contains(ext) { guard photos else { continue }; kind = .photo }
            else if Sorter.musicExt.contains(ext) { kind = .audio }
            else { continue }
            let comps = u.standardizedFileURL.pathComponents
            let dirs = comps.count > base.count + 1 ? Array(comps[base.count..<(comps.count - 1)]) : []
            raw.append((u, kind, dirs))
        }
        func stem(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent.lowercased() }
        func isStab(_ u: URL) -> Bool { let s = stem(u); return suffixes.contains { s.contains($0) } }
        let stabStems = raw.filter { $0.kind == .video && isStab($0.url) }.map { stem($0.url) }

        var out: [Item] = []
        for r in raw {
            var kw = keywords(fromDirs: r.dirs)
            if r.kind == .video {
                if isStab(r.url) { kw.append(FolderNames.stabilized) }
                else if stabStems.contains(where: { $0.hasPrefix(stem(r.url)) }) {
                    guard originals else { continue }
                    kw.append(FolderNames.legacyOriginal)
                }
            }
            if let tags = (try? r.url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames { kw += tags }
            var role: String? = nil
            if r.kind == .audio {
                let fx = r.dirs.contains { FolderNames.fold($0).contains("effekt") || FolderNames.fold($0).contains("sfx") || FolderNames.fold($0).contains("sound") }
                role = fx ? "effects" : "music"
                if !kw.contains(where: { FolderNames.fold($0) == "musik" }) && !fx { kw.append("Musik") }
            }
            let rel = r.url.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
            out.append(Item(url: r.url, rel: rel, kind: r.kind, keywords: dedupe(kw), role: role))
        }
        return out.sorted { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
    }

    /// Ordnernamen → Schlagwörter. Sammelordner (Videos, Fotos, Extras) und Stabilisiert/Original fallen weg,
    /// zusammengesetzte Namen („Sony A1 · Quer“) werden geteilt, Szenen-Ordner nur mit „Szene 03“.
    nonisolated static func keywords(fromDirs dirs: [String]) -> [String] {
        let drop = Set(["Videos", FolderNames.videos, FolderNames.photos, "Fotos", FolderNames.extras, "Extras", "Stabilisiert", FolderNames.stabilized, FolderNames.legacyOriginal].map(FolderNames.fold))
        var kw: [String] = []
        for d in dirs {
            if drop.contains(FolderNames.fold(d)) { continue }
            if FolderNames.isSceneFolder(d) { kw.append(d.components(separatedBy: FolderNames.separator).first ?? d); continue }
            let parts = FolderNames.separator.isEmpty ? [d] : d.components(separatedBy: FolderNames.separator)
            for p in parts {
                let t = p.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !drop.contains(FolderNames.fold(t)) { kw.append(t) }
            }
        }
        return kw
    }

    nonisolated static func dedupe(_ kw: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for k in kw {
            // Komma trennt in FCPXML mehrere Schlagwörter – im Namen ersetzen
            let c = k.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces)
            if c.isEmpty { continue }
            if seen.insert(FolderNames.fold(c)).inserted { out.append(c) }
        }
        return out
    }

    // MARK: Anlegen

    /// Schreibt die FCPXML-Dateien (neu bzw. Nachtrag) und öffnet sie in Final Cut (außer `open` = false).
    func build(folders: [URL], suffixes: [String], open: Bool = true) async {
        answered = true; waitingForGyro = false
        prepare(folders: folders, suffixes: suffixes)   // neu einlesen – z. B. nach Gyroflow
        state = .writing
        outputs = []; messages = []; errors = []
        for p in plans {
            if p.upToDate { messages.append("\(p.name): Mediathek ist aktuell – keine neuen Clips."); continue }
            do {
                let res = try await Self.write(plan: p)
                outputs.append(res.xml)
                messages.append(p.isAddition
                    ? "\(p.name): \(p.items.count) neue Medien als Ereignis „\(res.event)“ für \(p.library.lastPathComponent)"
                    : "\(p.name): \(p.items.count) Medien → \(p.library.lastPathComponent)")
                if res.skipped > 0 { errors.append("\(p.name): \(res.skipped) Datei(en) nicht lesbar – ausgelassen") }
            } catch { errors.append("\(p.name): \(error.localizedDescription)") }
        }
        if open && !outputs.isEmpty && ProcessInfo.processInfo.environment["CAMSORT_NO_FCP_OPEN"] == nil {
            if let app = Self.finalCutApp() {
                for o in outputs {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    do { _ = try await NSWorkspace.shared.open([o], withApplicationAt: app, configuration: cfg) }
                    catch { errors.append("Final Cut ließ sich nicht öffnen: \(error.localizedDescription) – FCPXML liegt bereit: \(o.lastPathComponent)") }
                }
            } else {
                messages.append("Final Cut Pro nicht gefunden. Die FCPXML liegt bereit – in Final Cut über Ablage › Importieren › XML … öffnen.")
            }
        }
        state = errors.isEmpty || !outputs.isEmpty ? .finished : .failed(errors.first ?? "Fehler")
    }

    static func finalCutApp() -> URL? {
        for id in ["com.apple.FinalCut", "com.apple.FinalCutTrial"] {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        return nil
    }

    struct WriteResult { let xml: URL; let event: String; let skipped: Int }

    nonisolated static func eventName(for p: Plan, date: Date = Date()) -> String {
        guard p.isAddition else { return p.name }
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "dd.MM.yyyy HH.mm"
        return "\(p.name) – Nachtrag \(f.string(from: date))"
    }

    /// FCPXML schreiben + Gedächtnis aktualisieren. Medien werden nur gelesen.
    nonisolated static func write(plan p: Plan, date: Date = Date()) async throws -> WriteResult {
        let event = eventName(for: p, date: date)
        let xmlURL: URL
        if p.isAddition {
            let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "yyyy-MM-dd HH.mm"
            xmlURL = p.dreh.appendingPathComponent("\(p.name) – Nachtrag \(f.string(from: date)).fcpxml")
        } else {
            xmlURL = p.dreh.appendingPathComponent("\(p.name).fcpxml")
        }
        let body = await document(items: p.items, library: p.library, event: event)
        guard body.clips > 0 else {
            throw NSError(domain: "CamSort", code: 2, userInfo: [NSLocalizedDescriptionKey: "Keine lesbaren Medien"])
        }
        try body.xml.write(to: xmlURL, atomically: true, encoding: .utf8)
        // Gedächtnis
        var memo = (p.libraryExists ? readMemo(p.dreh) : nil) ?? Memo(library: p.library.lastPathComponent, imported: [], events: [])
        memo.library = p.library.lastPathComponent
        memo.imported = Array(Set(memo.imported).union(body.importedRels)).sorted()
        memo.events.append(event)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(memo).write(to: p.dreh.appendingPathComponent(memoName), options: .atomic)
        return WriteResult(xml: xmlURL, event: event, skipped: body.skipped)
    }

    struct Document { let xml: String; let clips: Int; let skipped: Int; let importedRels: [String] }

    /// Das eigentliche FCPXML (Version 1.10): import-options → resources → library/event mit asset-clips + Schlagwörtern
    nonisolated static func document(items: [Item], library: URL, event: String) async -> Document {
        typealias R = FCPXML.Rate
        var formats: [String: String] = [:]     // Schlüssel → id
        var res = "", clips = ""
        var n = 1, ok = 0, skipped = 0
        var rels: [String] = []
        func newID() -> String { defer { n += 1 }; return "r\(n)" }
        func fmtID(_ key: String, _ line: (String) -> String) -> String {
            if let id = formats[key] { return id }
            let id = newID(); formats[key] = id; res += line(id); return id
        }
        func kwLines(_ kw: [String], start: String, dur: String) -> String {
            kw.map { "        <keyword start=\"\(start)\" duration=\"\(dur)\" value=\"\(FCPXML.esc($0))\"/>\n" }.joined()
        }
        let ord = FCPXML.esc

        for it in items {
            let name = ord(it.url.deletingPathExtension().lastPathComponent)
            let src = ord(it.url.absoluteString)
            switch it.kind {
            case .video:
                let a = AVURLAsset(url: it.url)
                guard let vts = try? await a.loadTracks(withMediaType: .video), let vt = vts.first,
                      let props = try? await vt.load(.nominalFrameRate, .naturalSize, .preferredTransform) else { skipped += 1; continue }
                let r: R = FCPXML.rate(props.0)
                let sz = props.1.applying(props.2)
                let w = Int(abs(sz.width).rounded()), h = Int(abs(sz.height).rounded())
                let fid = fmtID("v\(r.num)/\(r.den)-\(w)x\(h)") { id in
                    "    <format id=\"\(id)\" frameDuration=\"\(r.num)/\(r.den)s\" width=\"\(w)\" height=\"\(h)\"/>\n"
                }
                let start = await FCPXML.timecodeStart(a, rate: r)
                let dur = max(1, FCPXML.frames((try? await a.load(.duration))?.seconds ?? 0, r))
                var audioAttr = ""
                if let ats = try? await a.loadTracks(withMediaType: .audio), let at = ats.first {
                    let asbd = await audioInfo(at)
                    audioAttr = " audioSources=\"\(ats.count)\" audioChannels=\"\(asbd.channels)\" audioRate=\"\(asbd.rate)\""
                }
                let id = newID()
                res += "    <asset id=\"\(id)\" name=\"\(name)\" start=\"\(FCPXML.t(start, r))\" duration=\"\(FCPXML.t(dur, r))\" hasVideo=\"1\" format=\"\(fid)\" hasAudio=\"\(audioAttr.isEmpty ? 0 : 1)\"\(audioAttr)>\n"
                res += "      <media-rep kind=\"original-media\" src=\"\(src)\"/>\n    </asset>\n"
                // Ausrichtung + Framerate auch aus der Datei (falls nicht nach ihnen sortiert)
                var kw = it.keywords
                if let o = FolderNames.orientation(width: Double(w), height: Double(h)) { kw.append(o) }
                kw.append(FolderNames.fpsName(FolderNames.fpsClass(Double(props.0))))
                kw = dedupe(kw)
                let st = FCPXML.t(start, r), du = FCPXML.t(dur, r)
                clips += "      <asset-clip ref=\"\(id)\" name=\"\(name)\" start=\"\(st)\" duration=\"\(du)\" format=\"\(fid)\" tcFormat=\"NDF\">\n"
                clips += kwLines(kw, start: st, dur: du)
                clips += "      </asset-clip>\n"
            case .photo:
                guard let size = imageSize(it.url) else { skipped += 1; continue }
                let fid = fmtID("p\(size.w)x\(size.h)") { id in
                    "    <format id=\"\(id)\" name=\"FFVideoFormatRateUndefined\" width=\"\(size.w)\" height=\"\(size.h)\"/>\n"
                }
                let id = newID()
                res += "    <asset id=\"\(id)\" name=\"\(name)\" start=\"0s\" duration=\"0s\" hasVideo=\"1\" format=\"\(fid)\">\n"
                res += "      <media-rep kind=\"original-media\" src=\"\(src)\"/>\n    </asset>\n"
                var kw = it.keywords
                kw.append("Foto")
                if let o = FolderNames.orientation(width: Double(size.w), height: Double(size.h)) { kw.append(o) }
                kw = dedupe(kw)
                clips += "      <asset-clip ref=\"\(id)\" name=\"\(name)\" duration=\"5s\" format=\"\(fid)\">\n"
                clips += kwLines(kw, start: "0s", dur: "5s")
                clips += "      </asset-clip>\n"
            case .audio:
                let a = AVURLAsset(url: it.url)
                guard let ats = try? await a.loadTracks(withMediaType: .audio), let at = ats.first else { skipped += 1; continue }
                let info = await audioInfo(at)
                let secs = (try? await a.load(.duration))?.seconds ?? 0
                guard secs > 0 else { skipped += 1; continue }
                let samples = Int((secs * Double(info.rate)).rounded())
                let du = "\(samples)/\(info.rate)s"
                let id = newID()
                res += "    <asset id=\"\(id)\" name=\"\(name)\" start=\"0s\" duration=\"\(du)\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(info.channels)\" audioRate=\"\(info.rate)\">\n"
                res += "      <media-rep kind=\"original-media\" src=\"\(src)\"/>\n    </asset>\n"
                clips += "      <asset-clip ref=\"\(id)\" name=\"\(name)\" duration=\"\(du)\"\(it.role.map { " audioRole=\"\($0)\"" } ?? "")>\n"
                clips += kwLines(it.keywords, start: "0s", dur: du)
                clips += "      </asset-clip>\n"
            }
            ok += 1
            rels.append(it.rel)
        }
        // Ohne Schrägstrich am Ende: ein Ordner-URL hieße „Standardname in diesem Ordner“ (Apple: import-options)
        let loc = ord(URL(fileURLWithPath: library.path, isDirectory: false).absoluteString)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <import-options>
            <option key="library location" value="\(loc)"/>
            <option key="copy assets" value="0"/>
          </import-options>
          <resources>
        \(res)  </resources>
          <library location="\(loc)">
            <event name="\(ord(event))">
        \(clips)    </event>
          </library>
        </fcpxml>

        """
        return Document(xml: xml, clips: ok, skipped: skipped, importedRels: rels)
    }

    nonisolated static func audioInfo(_ t: AVAssetTrack) async -> (channels: Int, rate: Int) {
        var ch = 2, rate = 48000
        if let fds = try? await t.load(.formatDescriptions), let fd = fds.first,
           let p = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            let asbd = p.pointee
            if asbd.mChannelsPerFrame > 0 { ch = Int(asbd.mChannelsPerFrame) }
            if asbd.mSampleRate > 0 { rate = Int(asbd.mSampleRate.rounded()) }
        }
        return (ch, rate)
    }

    nonisolated static func imageSize(_ u: URL) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 && o <= 8 ? (h, w) : (w, h)   // EXIF 5–8 = um 90° gedreht
    }

    // MARK: Für Sorter / Neu-Verknüpfen

    /// Von CamSort hier angelegte Mediathek/FCPXML? (wird beim erneuten Sortieren nicht nach Extras/FCP verschoben)
    nonisolated static func isOwnOutput(_ u: URL) -> Bool {
        let ext = u.pathExtension.lowercased()
        guard ext == "fcpbundle" || ext == "fcpxml" else { return false }
        let dir = u.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(memoName).path) else { return false }
        return u.deletingPathExtension().lastPathComponent.hasPrefix(dir.lastPathComponent)
    }

    /// Von CamSort angelegte Mediatheken unter den Ordnern (für den Neu-Verknüpfen-Hinweis)
    nonisolated static func ownLibraries(in folders: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        func check(_ d: URL) {
            let lib = libraryURL(d)
            if fm.fileExists(atPath: d.appendingPathComponent(memoName).path), fm.fileExists(atPath: lib.path), !out.contains(lib) { out.append(lib) }
        }
        for f in folders {
            check(f)
            guard let en = fm.enumerator(at: f, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                if en.level > 3 { en.skipDescendants(); continue }
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { check(u) }
            }
        }
        return out
    }
}

// MARK: - Ansicht im Fertig-Bildschirm

struct FCPLibraryCard: View {
    let folders: [URL]
    let suffixes: [String]
    let gyroBusy: Bool
    @ObservedObject var lib = FCPLibraryBuilder.shared

    private var title: String {
        if lib.plans.count == 1, let p = lib.plans.first { return p.library.lastPathComponent }
        return "\(lib.plans.count) Mediatheken"
    }
    private var anyAddition: Bool { lib.plans.contains { $0.isAddition && !$0.upToDate } }
    private var allUpToDate: Bool { !lib.plans.isEmpty && lib.plans.allSatisfy { $0.upToDate } }
    private var question: String {
        let name = lib.plans.count == 1 ? "„\(lib.plans[0].name)“" : "für \(lib.plans.count) Drehs"
        if anyAddition {
            let foreign = lib.plans.contains { $0.foreign } ? " (Mediathek nicht von CamSort – evtl. sind Clips schon drin)" : ""
            return "Mediathek \(name) existiert – \(lib.totalNew) neue Medien als weiteres Ereignis hinzufügen?\(foreign)"
        }
        return "Final-Cut-Mediathek \(name) anlegen? Empfohlen – \(lib.totalNew) Medien, Schlagwörter nach Kamera/Ausrichtung/fps"
    }

    var body: some View {
        // Wichtig: immer eine echte View rendern – an einer leeren Group feuert .onAppear nicht,
        // dann lief prepare() nie und die Karte blieb für immer unsichtbar.
        VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "film.stack")
                        Text("Final-Cut-Mediathek").font(.system(size: 13, weight: .bold))
                        Spacer()
                        HelpButton(title: "Final-Cut-Mediathek anlegen", text: "CamSort schreibt eine Final-Cut-Datei (FCPXML) in den Dreh-Ordner und öffnet sie in Final Cut. Final Cut legt daraus eine gleichnamige Mediathek im selben Ordner an – mit einem Ereignis und allen Clips, Fotos und Musik. Die Medien bleiben, wo sie sind: nichts wird kopiert oder verändert.\n\nJeder Clip bekommt Schlagwörter aus der Ordnerstruktur (Kamera, Objektiv, Hochkant/Quer, „50 fps“, Länge, Szene, eigene Ordner) und deine Finder-Tags. Links in der Seitenleiste erscheinen sie als Schlagwortsammlungen – ein Klick filtert.\n\nGibt es die Mediathek schon, fügt CamSort nur neue Clips als weiteres Ereignis „Nachtrag“ hinzu. Welche Dateien schon drin sind, merkt sich die unsichtbare Datei .camsort-fcp.json im Ordner.")
                    }
                    switch lib.state {
                    case .scanning, .writing:
                        HStack { ProgressView().controlSize(.small); Text(lib.state == .scanning ? "Lese Medien …" : "Schreibe Final-Cut-Datei …").font(.system(size: 12)) }
                    case .finished, .failed:
                        ForEach(lib.messages, id: \.self) { Text("• " + $0).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                        ForEach(lib.errors, id: \.self) { Text("• " + $0).font(.system(size: 11)).foregroundStyle(Theme.orange).fixedSize(horizontal: false, vertical: true) }
                        if !lib.outputs.isEmpty {
                            Text(FCPLibraryBuilder.finalCutApp() == nil
                                 ? "Final Cut nicht gefunden – die FCPXML liegt im Dreh-Ordner. In Final Cut: Ablage › Importieren › XML …"
                                 : "Final Cut legt die Mediathek jetzt an. Die Clips bleiben am Ort.")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                ForEach(lib.outputs.prefix(3), id: \.self) { o in
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([o]) } label: {
                                        Label(o.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                                    }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    default:
                        if lib.plans.isEmpty && lib.state == .ready {
                            Text("Keine Clips für eine Mediathek gefunden").font(.system(size: 12, weight: .semibold))
                            if !lib.emptyReason.isEmpty {
                                Text(lib.emptyReason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                            }
                        } else if lib.waitingForGyro {
                            HStack { ProgressView().controlSize(.small); Text("Wird angelegt, sobald Gyroflow fertig ist – dann mit den stabilisierten Clips.").font(.system(size: 12)) }
                        } else if allUpToDate {
                            Text("Mediathek ist aktuell – alle Medien sind schon drin.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        } else if lib.mode == "ask" && !lib.answered {
                            Text(question).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Button("Anlegen") { start() }.buttonStyle(.borderedProminent).tint(Theme.mint)
                                Button("Nicht jetzt") { lib.answered = true }.buttonStyle(.bordered)
                                Button("Immer") { lib.mode = "always"; start() }.buttonStyle(.bordered)
                                Button("Nie") { lib.mode = "never"; lib.answered = true }.buttonStyle(.bordered)
                            }.controlSize(.small)
                        }
                    }
                    if !lib.busy && !lib.waitingForGyro && !(lib.mode == "ask" && !lib.answered && lib.state == .ready && !lib.plans.isEmpty) && !allUpToDate {
                        Button { start() } label: {
                            Label(lib.plans.isEmpty ? "Final-Cut-Mediathek anlegen"
                                  : anyAddition ? "Neue Clips zur Mediathek hinzufügen (\(lib.totalNew))" : "Final-Cut-Mediathek anlegen: \(title)", systemImage: "film.stack")
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.orange.opacity(0.35)))
                        }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.orange.opacity(0.12)))
        .onAppear { refresh() }
        .onChange(of: folders) { _, _ in refresh() }
        .onChange(of: gyroBusy) { _, busy in
            if !busy && lib.waitingForGyro { Task { await lib.build(folders: folders, suffixes: suffixes) } }
            else if !busy && lib.state == .ready { lib.prepare(folders: folders, suffixes: suffixes) }   // stabilisierte Clips sind neu
        }
    }

    /// Neue Ordnerliste → Singleton-Zustand zurücksetzen und neu planen
    private func refresh() {
        lib.resetForRun(folders)
        if lib.state == .idle { lib.prepare(folders: folders, suffixes: suffixes) }
        if lib.mode == "always" && !lib.answered && lib.totalNew > 0 { start() }
    }

    private func start() {
        lib.answered = true
        if gyroBusy { lib.waitingForGyro = true; return }
        Task { await lib.build(folders: folders, suffixes: suffixes) }
    }
}

// MARK: - Einstellungen

struct FCPLibrarySettings: View {
    @ObservedObject var lib = FCPLibraryBuilder.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WithHelp(title: "Final-Cut-Mediathek", text: "Nach dem Sortieren kann CamSort aus dem Dreh-Ordner direkt eine gleichnamige Final-Cut-Mediathek anlegen (z. B. „Pitbike.fcpbundle“ im Ordner „Pitbike“) – mit einem Ereignis, allen Clips und Schlagwörtern aus der Ordnerstruktur: Kamera, Objektiv, Hochkant/Quer, Framerate, Länge, Szene, eigene Ordner und deine Finder-Tags.\n\nFragen: Nach dem Sortieren erscheint eine kurze Rückfrage.\nImmer: wird ohne Rückfrage angelegt (läuft Gyroflow noch, danach).\nNie: keine Rückfrage; der Knopf im Fertig-Bildschirm bleibt.\n\nDie Medien bleiben am Ort, nichts wird kopiert oder verändert.") {
                Picker("Nach dem Sortieren Mediathek anlegen", selection: $lib.mode) {
                    Text("Fragen").tag("ask"); Text("Immer").tag("always"); Text("Nie").tag("never")
                }.pickerStyle(.segmented)
            }
            WithHelp(title: "Fotos aufnehmen", text: "An: Fotos aus dem Ordner „\(FolderNames.photos)“ kommen als Standbilder mit in die Mediathek (Schlagwort „Foto“).") {
                Toggle("Fotos aufnehmen", isOn: $lib.includePhotos)
            }
            WithHelp(title: "Originale neben stabilisierten", text: "An: Gibt es zu einem Clip eine stabilisierte Gyroflow-Fassung, kommen beide in die Mediathek – das Original mit dem Schlagwort „Original“, die stabilisierte mit „Stabilisiert“. So filterst du in Final Cut mit einem Klick.\n\nAus: Nur die stabilisierte Fassung.") {
                Toggle("Originale neben stabilisierten aufnehmen", isOn: $lib.includeOriginals)
            }
        }
        .toggleStyle(.switch).font(.system(size: 12)).controlSize(.small)
    }
}


// MARK: - Startbildschirm: Mediathek für einen schon sortierten Ordner

struct FCPLibraryQuickRow: View {
    let folder: URL
    let suffixes: [String]
    @ObservedObject var lib = FCPLibraryBuilder.shared

    private var mine: Bool { lib.lastFolders == [folder.standardizedFileURL] }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "film.stack").foregroundStyle(.white.opacity(0.6))
            if mine && lib.busy {
                ProgressView().controlSize(.small)
                Text(lib.state == .scanning ? "Lese Medien …" : "Schreibe Final-Cut-Datei …")
            } else if mine, lib.state == .finished || lib.state == .ready, let line = (lib.errors + lib.messages).first ?? (lib.plans.isEmpty && !lib.emptyReason.isEmpty ? lib.emptyReason : nil) {
                Text(line).lineLimit(2).foregroundStyle(lib.errors.isEmpty ? Color.white.opacity(0.7) : Theme.orange)
            }
            Spacer()
            Button("Final-Cut-Mediathek anlegen") {
                lib.resetForRun([folder], force: true)
                Task { await lib.build(folders: [folder], suffixes: suffixes) }
            }
            .buttonStyle(.link)
            .disabled(lib.busy)
        }
        .font(.system(size: 11))
    }
}
