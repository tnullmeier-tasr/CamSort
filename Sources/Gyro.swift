import Foundation
import AVFoundation
import SwiftUI
import AppKit

/// Schickt Sony-Clips nacheinander über die Gyroflow-Kommandozeile zum Rendern.
@MainActor
final class GyroRunner: ObservableObject {
    enum State: Equatable { case idle, running, paused, finished, failed(String) }

    @Published var state: State = .idle
    @Published var queue: [URL] = []
    @Published var index = 0
    @Published var currentFile = ""
    @Published var currentGroup = ""      // Hochkant / Quer
    @Published var filePercent: Double = 0
    @Published var done: [String] = []
    @Published var errors: [String] = []
    /// Je fertigem Clip: „C0001.MP4 → A1/Stabilisiert/Hochkant“
    @Published var placed: [String] = []
    /// Stabilisiert-Ordner, in die dieser Lauf abgelegt hat (Knopf „Im Finder zeigen“)
    @Published var stabilizedDirs: [URL] = []
    /// Übersprungen, weil die stabilisierte Fassung schon existiert (nie überschreiben)
    @Published var skippedExisting = 0

    var active: Bool { state != .idle }
    var eta = ETA()
    var remainingText: String { ETA.text(eta.remaining(done: Double(index) + filePercent, total: Double(queue.count))) }
    var overall: Double {
        queue.isEmpty ? 0 : (Double(index) + filePercent) / Double(queue.count)
    }

    private let store: LearnedStore
    private weak var sorter: Sorter?
    private var process: Process?
    private var cancelled = false
    private var pauseRequested = false
    private var lastOutput = ""
    /// Komplette Ausgabe des aktuellen Clips (für die Log-Datei)
    private var fullOutput = ""
    /// Log-Datei des zuletzt gescheiterten Clips (Knopf „Log zeigen“)
    @Published var lastLogURL: URL?
    /// Preset-Variante: reduziert (+ -p) oder – nach einem Fallback – komplett mit Ausgabegröße
    /// .plain = komplettes Original-Preset ohne Größenvorgabe (nach einer falsch ausgerichteten Ausgabe für Hochkant-Clips)
    enum PresetVariant { case reduced, full, plain }

    init(store: LearnedStore, sorter: Sorter) { self.store = store; self.sorter = sorter }

    // MARK: Gyroflow finden

    static let defaultAppPaths = ["/Applications/Gyroflow.app", NSHomeDirectory() + "/Applications/Gyroflow.app"]

    var appURL: URL? {
        let custom = store.gyroAppPath
        for p in ([custom] + Self.defaultAppPaths) where !p.isEmpty && FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// Ausführbare Datei im App-Paket (Contents/MacOS/…)
    func executable(in app: URL) -> URL? {
        if let b = Bundle(url: app), let e = b.executableURL { return e }
        let dir = app.appendingPathComponent("Contents/MacOS")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.lastPathComponent.lowercased().hasPrefix("gyroflow") } ?? items.first
    }

    // MARK: Sony-Clips sammeln

    /// Unstabilisierte Clips mit Gyrodaten (Sony, DJI, GoPro, Insta360) in Hochkant/Quer-Ordnern – erst alle Hochkant, dann alle Quer.
    func collectSonyClips(in folders: [URL]) async -> (hochkant: [URL], quer: [URL]) {
        await Self.collectGyroClips(in: folders, suffixes: store.gyroSuffixList)
    }

    nonisolated static func collectGyroClips(in folders: [URL], suffixes: [String]) async -> (hochkant: [URL], quer: [URL]) {
        let fm = FileManager.default
        var h: [URL] = [], q: [URL] = []
        for base in folders {
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                let name = u.lastPathComponent
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if FolderNames.isGyroFolder(name) { en.skipDescendants() }
                    continue
                }
                guard Sorter.videoExt.contains(u.pathExtension.lowercased()) else { continue }
                if let g = await classify(u, suffixes: suffixes) {
                    if g == FolderNames.portrait { h.append(u) } else { q.append(u) }
                }
            }
        }
        return (h.sorted { $0.path < $1.path }, q.sorted { $0.path < $1.path })
    }

    /// Ausrichtung des Clips, wenn er sortiert, unstabilisiert und Gyroflow-tauglich ist – sonst nil.
    nonisolated static func classify(_ u: URL, suffixes: [String]) async -> String? {
        let stem = u.deletingPathExtension().lastPathComponent.lowercased()
        if suffixes.contains(where: { stem.contains($0) }) { return nil }       // schon stabilisiert
        let comps = u.pathComponents
        guard FolderNames.isSortedVideoPath(comps) else { return nil }
        let dirs = comps.dropLast()
        let group: String
        if dirs.contains(where: { FolderNames.fold($0) == FolderNames.fold(FolderNames.portrait) }) || dirs.last(where: { $0.contains("Hochkant") }) != nil {
            group = FolderNames.portrait
        } else if dirs.contains(where: { FolderNames.fold($0) == FolderNames.fold(FolderNames.landscape) }) || dirs.last(where: { $0.contains("Quer") }) != nil {
            group = FolderNames.landscape
        } else {
            group = await videoOrientation(u)
        }
        guard !hasStabilizedSibling(u, suffixes: suffixes) else { return nil }
        guard gyroSource(u) != nil else { return nil }
        return group
    }

    /// Hochkant/Quer direkt aus dem Video (wenn der Ordnername es nicht verrät)
    nonisolated static func videoOrientation(_ u: URL) async -> String {
        let a = AVURLAsset(url: u)
        guard let found = try? await a.loadTracks(withMediaType: .video), let t = found.first,
              let props = try? await t.load(.naturalSize, .preferredTransform) else { return "Quer" }
        let r = props.0.applying(props.1)
        return FolderNames.orientation(width: Double(abs(r.width)), height: Double(abs(r.height))) ?? "Quer"
    }

    nonisolated static func hasStabilizedSibling(_ u: URL, suffixes: [String]) -> Bool {
        let dir = u.deletingLastPathComponent()
        let stem = u.deletingPathExtension().lastPathComponent.lowercased()
        func hasStab(in d: URL) -> Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            return names.contains(where: { n in
                let s = (n as NSString).deletingPathExtension.lowercased()
                return s != stem && s.hasPrefix(stem) && suffixes.contains { s.contains($0) }
            })
        }
        // a) selbst in Gyroflow gerendert: liegt (noch) neben dem Original
        if hasStab(in: dir) { return true }
        // b) neues Schema: <Eltern>/Stabilisiert/<Ebene>/
        if hasStab(in: FolderNames.stabilizedDir(forClipDir: dir)) { return true }
        // c) alte Logik: Original liegt in „Original“, Stabilisiert daneben
        if dir.lastPathComponent == FolderNames.legacyOriginal { return true }
        if hasStab(in: dir.appendingPathComponent(FolderNames.stabilized)) || hasStab(in: dir.appendingPathComponent("Stabilisiert")) { return true }
        return false
    }

    /// Suffix für Gyroflows Ausgabe (-t) – nie leer, sonst würde die Ausgabe wie das Original heißen
    nonisolated static func safeSuffix(_ list: [String]) -> String {
        let s = (list.first ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "_stabilized" : s
    }

    // MARK: Drohnen → Tiefpassfilter

    /// Drohnen-Schlüsselwörter (ganze Wörter im Pfad, nur zusammen mit DJI-Bewegungsdaten bzw. „DJI“ im Pfad)
    nonisolated static let droneWords: Set<String> = ["avata", "avata2", "fpv", "mini", "air", "mavic", "neo", "phantom", "inspire", "spark", "flip", "m3p", "m3e", "m3t", "m30", "m30t", "lito"]
    /// Ordnernamen, die allein schon „Drohne“ bedeuten
    nonisolated static let droneFolderWords: Set<String> = ["drohne", "drohnen", "drone", "drones", "fpv", "avata", "avata2"]
    /// DJI-Bodenkameras: nie als Drohne
    nonisolated static let groundWords: Set<String> = ["osmo", "action", "pocket", "ronin", "mic"]

    /// Ist der Clip von einer Drohne? Kameraordnername (gelernte Kamera = Ordnername), Dateiname (z. B. DJI_…_D_M3P) und DJI-Bewegungsdaten.
    nonisolated static func isDrone(_ url: URL, source: String?) -> Bool {
        let comps = url.deletingLastPathComponent().pathComponents.suffix(6) + [url.deletingPathExtension().lastPathComponent]
        let tokens = Set(comps.flatMap { c in
            c.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        })
        if !tokens.isDisjoint(with: groundWords) { return false }
        if comps.contains(where: { droneFolderWords.contains(FolderNames.fold($0)) }) { return true }
        let dji = source == "DJI" || tokens.contains("dji")
        return dji && !tokens.isDisjoint(with: droneWords)
    }

    /// Tiefpass (Gyroflow: gyro_source.lpf in Hz, 0 = aus – core/lib.rs import_gyroflow_data/export_gyroflow_data,
    /// UI src/ui/menu/MotionData.qml „Low pass filter“, Standard 50 Hz) in die Inline-Preset-JSON setzen.
    /// Hat das Preset schon einen Wert > 0, bleibt er. Kein JSON (Pfad) → unverändert.
    nonisolated static func withLowPass(_ presetJSON: String, hz: Double) -> String {
        guard hz > 0, let data = presetJSON.replacingOccurrences(of: "\\u0027", with: "'").data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return presetJSON }
        var gs = obj["gyro_source"] as? [String: Any] ?? [:]
        if let cur = (gs["lpf"] as? NSNumber)?.doubleValue, cur > 0 { return presetJSON }
        gs["lpf"] = hz
        obj["gyro_source"] = gs
        return jsonString(obj) ?? presetJSON
    }

    /// Hat der Clip Bewegungsdaten, die Gyroflow lesen kann? Erkennung wie telemetry-parser (Gyroflow):
    /// Sony = XML mit manufacturer="Sony" (Begleitdatei oder eingebettet), DJI = "djmd" + "DJI meta",
    /// GoPro = "GPMFDEVC" bzw. "GoPro MET", Insta360 = Magic am Dateiende. Unsicher → nil (nicht anbieten).
    nonisolated static func gyroSource(_ url: URL) -> String? {
        if isSony(url) { return "Sony" }
        let data = headTail(url)
        func has(_ s: String) -> Bool { data.range(of: Data(s.utf8)) != nil }
        // Sony ohne XML-Begleitdatei: Bewegungsdaten stecken in der Echtzeit-Metadatenspur „rtmd“ der MP4
        if has("rtmd") && (has("Sony") || has("SONY")) { return "Sony" }
        if has("djmd") && has("DJI meta") { return "DJI" }
        if has("GPMFDEVC") || has("GoPro MET") { return "GoPro" }
        let magic = Data("8db42d694ccc418790edff439fe026bf".utf8)
        if data.count > magic.count && data.suffix(magic.count) == magic { return "Insta360" }
        return nil
    }

    nonisolated static func headTail(_ url: URL) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        let chunk = 2 * 1_048_576
        var data = (try? h.read(upToCount: chunk)) ?? Data()
        if let size = try? h.seekToEnd(), size > UInt64(chunk) {
            try? h.seek(toOffset: size - UInt64(chunk))
            data.append((try? h.read(upToCount: chunk)) ?? Data())
        }
        return data
    }

    /// Sony erkennt man am eingebetteten XML in der MP4 (unabhängig vom Ordnernamen).
    nonisolated static func isSony(_ url: URL) -> Bool {
        // a) Begleit-XML: liegt nach dem Sortieren in „XML“ bzw. „Begleitdateien“ weiter oben
        let stem = url.deletingPathExtension().lastPathComponent
        var dir = url.deletingLastPathComponent()
        let sideDirs = Array(Set(["XML", "Begleitdateien", FolderNames.side]))
        for _ in 0..<8 {
            for name in [stem + "M01.XML", stem + "M01.xml"] {
                for cand in sideDirs.map({ dir.appendingPathComponent($0).appendingPathComponent(name) }) + [dir.appendingPathComponent(name)] {
                    if let s = try? String(contentsOf: cand, encoding: .utf8),
                       s.range(of: "manufacturer=\"Sony\"", options: .caseInsensitive) != nil { return true }
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // b) In der MP4 eingebettetes XML
        return isSonyEmbedded(url)
    }

    nonisolated static func isSonyEmbedded(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var data = (try? h.read(upToCount: 1_048_576)) ?? Data()
        if let size = try? h.seekToEnd(), size > 1_048_576 {
            try? h.seek(toOffset: size - 1_048_576)
            data.append((try? h.read(upToCount: 1_048_576)) ?? Data())
        }
        return data.range(of: Data("manufacturer=\"Sony\"".utf8)) != nil
    }

    // MARK: Ablauf

    func start(folders: [URL]) async { await start(folders: folders, clips: nil) }

    /// Mit fester Liste (z. B. aus dem Fertig-Bildschirm „X Clips enthalten Gyrodaten“)
    func start(clips list: [URL], folders: [URL]) async { await start(folders: folders, clips: list) }

    /// Verhindert einen zweiten Start, während die Clips (asynchron) gesammelt werden
    private var preparing = false

    private func start(folders: [URL], clips list: [URL]?) async {
        guard !preparing else { return }
        FolderNames.load()   // eigene Ordnernamen (Hochkant/Quer/Videos) für die Clip-Suche
        errors = []; done = []; placed = []; stabilizedDirs = []; skippedExisting = 0; cancelled = false; pauseRequested = false
        guard let app = appURL, let exe = executable(in: app) else {
            state = .failed("Gyroflow wurde nicht gefunden. Bitte unter Einstellungen › Gyroflow die Gyroflow-App auswählen.")
            return
        }
        // App-Store-Version (Sandbox) vor dem ersten Clip sicher erkennen statt raten
        let sb = await Self.sandboxInfo(app: app)
        if sb.sandboxed {
            state = .failed(Self.sandboxMessage(app: app, evidence: sb.evidence))
            return
        }
        store.migratePresetIfNeeded()
        let preset = store.gyroPresetPath
        guard !preset.isEmpty else {
            state = .failed("Es ist noch kein Gyroflow-Preset hinterlegt. Bitte unter Einstellungen › Gyroflow das Preset auswählen (dort steht Schritt für Schritt, wie).")
            return
        }
        guard FileManager.default.isReadableFile(atPath: preset) else {
            state = .failed("Das Preset „\((preset as NSString).lastPathComponent)“ ist nicht lesbar (\(preset)). Bitte unter Einstellungen › Gyroflow einmal neu wählen – CamSort speichert sich dann eine eigene Kopie.")
            return
        }
        // „Ausgabe wie Eingabeclip“: aus Tims Preset nur Glättung + dynamisches Zoomen in eine eigene Kopie übernehmen.
        // Das Original bleibt unangetastet; klappt das nicht, wird wie bisher das Original verwendet.
        var usedPreset = preset
        if store.gyroMatchSource {
            let target = LearnedStore.presetDir.appendingPathComponent(Self.reducedPresetName)
            switch Self.writeReducedPreset(from: URL(fileURLWithPath: preset), to: target) {
            case .success(let u): usedPreset = u.path
            case .failure(let e):
                errors.append("Hinweis: \(e.message) – Gyroflow nutzt deshalb dein Preset komplett (inkl. Objektiv und Export-Format daraus).")
            }
        }
        var clips: (hochkant: [URL], quer: [URL]) = ([], [])
        preparing = true
        if list == nil { clips = await collectSonyClips(in: folders) }
        if let list {
            let fm = FileManager.default
            let keep = list.filter { fm.fileExists(atPath: $0.path) }
            var h: [URL] = [], q: [URL] = []
            for u in keep {
                if await Self.isPortraitFolder(u) { h.append(u) } else { q.append(u) }
            }
            clips = (h.sorted { $0.path < $1.path }, q.sorted { $0.path < $1.path })
        }
        preparing = false
        queue = clips.hochkant + clips.quer
        guard !queue.isEmpty else {
            state = .failed("Keine unstabilisierten Clips mit Gyrodaten gefunden. Entweder sind schon alle stabilisiert, oder der Ordner wurde noch nicht sortiert.")
            return
        }
        index = 0
        state = .running
        eta.begin()
        lastLogURL = nil
        Task { await runAll(exe: exe, preset: usedPreset, originalPreset: preset, hochkantCount: clips.hochkant.count, folders: folders) }
    }

    nonisolated static func isPortraitFolder(_ u: URL) async -> Bool {
        let dirs = u.pathComponents.dropLast()
        if dirs.contains(where: { FolderNames.fold($0) == FolderNames.fold(FolderNames.portrait) || $0.contains("Hochkant") }) { return true }
        if dirs.contains(where: { FolderNames.fold($0) == FolderNames.fold(FolderNames.landscape) || $0.contains("Quer") }) { return false }
        return await videoOrientation(u) == FolderNames.portrait
    }

    // MARK: Preset reduzieren / Ausgabe pro Clip

    nonisolated static let reducedPresetName = ".camsort-nur-stabilisierung.gyroflow"

    struct PresetError: Error { let message: String }

    /// Schlüssel unter "stabilization", die CamSort aus dem Preset übernimmt (Whitelist).
    /// Belegt in gyroflow/src/core/lib.rs (export_gyroflow_data / import_gyroflow_data):
    /// Glättung: method, smoothing_params, Horizont-Ausgleich (gehört in Gyroflow zur Glättung);
    /// dynamisches Zoomen: fov, adaptive_zoom_*, max_zoom (Zoom-Grenze), max_zoom_iterations, fixed_zoom, zoom_limit_whole_clip.
    /// Nicht übernommen u. a.: calibration_data (Objektiv), frame_readout_* (kommt vom Objektivprofil),
    /// lens_correction_amount, video_speed (würde Framerate/Ton ändern), output (Größe/Codec), synchronization.
    nonisolated static let presetStabilizationKeys: Set<String> = [
        "method", "smoothing_params",
        "horizon_lock_amount", "horizon_lock_roll", "horizon_lock_pitch_enabled", "horizon_lock_pitch",
        "automatic_lock", "turn_threshold", "turn_smoothing_ms", "turn_multiplier", "tilt_accel_limit",
        "use_gravity_vectors", "horizon_lock_integration_method",
        "fov", "adaptive_zoom_window", "adaptive_zoom_center_offset", "adaptive_zoom_method",
        "max_zoom", "max_zoom_iterations", "fixed_zoom", "zoom_limit_whole_clip",
    ]

    /// Liest Tims Preset (nur lesend) und schreibt eine reduzierte Kopie nach `target`.
    nonisolated static func writeReducedPreset(from source: URL, to target: URL) -> Result<URL, PresetError> {
        guard let data = try? Data(contentsOf: source), !data.isEmpty else {
            return .failure(PresetError(message: "Preset „\(source.lastPathComponent)“ ließ sich nicht lesen"))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(PresetError(message: "Preset „\(source.lastPathComponent)“ ist kein gültiges Gyroflow-JSON"))
        }
        guard let stab = obj["stabilization"] as? [String: Any] else {
            return .failure(PresetError(message: "Preset „\(source.lastPathComponent)“ enthält keinen Abschnitt „stabilization“"))
        }
        let kept = stab.filter { presetStabilizationKeys.contains($0.key) }
        guard !kept.isEmpty else {
            return .failure(PresetError(message: "Preset „\(source.lastPathComponent)“ enthält keine Glättungs-/Zoom-Werte"))
        }
        // Minimalstruktur: ohne "videofile" behandelt Gyroflow die Datei als Preset (cli.rs detect_types)
        var out: [String: Any] = ["title": "CamSort: nur Stabilisierung + dynamischer Zoom", "stabilization": kept]
        out["version"] = obj["version"] ?? 2
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: target, options: .atomic)
            return .success(target)
        } catch {
            return .failure(PresetError(message: "Reduziertes Preset konnte nicht gespeichert werden (\(error.localizedDescription))"))
        }
    }

    /// Gyroflow-Ausgabeparameter (-p) passend zum Clip: ANGEZEIGTE Größe (nach Rotation), gleiche Codec-Familie, Bitrate ≈ Quelle, Ton an (Original kopieren, sonst AAC).
    /// Framerate: Gyroflow rendert immer mit der Quell-Framerate (kein -p-Schlüssel dafür nötig).
    nonisolated static func outputParams(for clip: URL) async -> String? {
        guard let p = await outputParamsDict(for: clip) else { return nil }
        return jsonString(p)
    }

    /// JSON ohne einfache Anführungszeichen: Gyroflow ersetzt in -p und Inline-Presets ' durch " (cli.rs) –
    /// deshalb ' als \u0027 maskieren, sonst wird das JSON kaputt und Gyroflow bricht mit „Invalid json“-Panic ab.
    nonisolated static func jsonString(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s.replacingOccurrences(of: "'", with: "\\u0027")
    }

    nonisolated static func outputParamsDict(for clip: URL) async -> [String: Any]? {
        let a = AVURLAsset(url: clip)
        guard let found = try? await a.loadTracks(withMediaType: .video), let t = found.first,
              let props = try? await t.load(.naturalSize, .estimatedDataRate, .formatDescriptions),
              let tf = try? await t.load(.preferredTransform) else { return nil }
        // Gyroflow erwartet die Ausgabegröße in ANGEZEIGTER Ausrichtung: core/lib.rs set_output_size vergleicht mit
        // params.size, bei video_rotation 90/270 mit getauschten Maßen (render_queue.rs: set_video_rotation((360 - info.rotation) % 360)).
        // Kodierte Größe (3840×2160) bei einem Hochkant-Clip (Matrix 90°) ergab eine quer beschnittene Ausgabe.
        let (w, h) = Self.displaySize(natural: props.0, transform: tf)
        guard w > 0, h > 0 else { return nil }
        var p: [String: Any] = ["output_width": w, "output_height": h, "audio": true, "audio_codec": "Copy"]
        let sub: FourCharCode = props.2.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        switch sub {
        case kCMVideoCodecType_H264:
            p["codec"] = "H.264/AVC"
        case kCMVideoCodecType_AppleProRes422Proxy: p["codec"] = "ProRes"; p["codec_options"] = "Proxy"
        case kCMVideoCodecType_AppleProRes422LT:    p["codec"] = "ProRes"; p["codec_options"] = "LT"
        case kCMVideoCodecType_AppleProRes422:      p["codec"] = "ProRes"; p["codec_options"] = "Standard"
        case kCMVideoCodecType_AppleProRes422HQ:    p["codec"] = "ProRes"; p["codec_options"] = "HQ"
        case kCMVideoCodecType_AppleProRes4444:     p["codec"] = "ProRes"; p["codec_options"] = "4444"
        case kCMVideoCodecType_AppleProRes4444XQ:   p["codec"] = "ProRes"; p["codec_options"] = "4444XQ"
        default:
            p["codec"] = "H.265/HEVC"   // HEVC und alles andere
        }
        if p["codec"] as? String != "ProRes" {
            // Mbit/s, aufgerundet, mindestens 10 – RenderOptions.bitrate ist f64 (render_queue.rs), daher als Double
            let mbps = Double(props.1) / 1_000_000
            p["bitrate"] = Double(max(10, Int(mbps.rounded(.up))))
        }
        return p
    }

    /// Angezeigte Größe: naturalSize mit preferredTransform (Beträge) – bei 90°/270° Breite/Höhe getauscht.
    /// So weiß auch CamSort „Hochkant“ (Sorter.videoProps): aus der Rotationsmatrix der Videospur – dieselbe Angabe, die Gyroflow
    /// über ffmpeg als `rotation` liest. Gerade Maße (Encoder verlangen das).
    nonisolated static func displaySize(natural: CGSize, transform: CGAffineTransform) -> (Int, Int) {
        let r = natural.applying(transform)
        var w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }
        return (w, h)
    }

    /// Komplettes Original-Preset als Inline-JSON, nur die Ausgabegröße ersetzt. Inline, weil das Preset in apply_to_all
    /// nach -p angewendet wird und dessen "output" sonst die Größe überschreiben würde (render_queue.rs apply_to_all).
    nonisolated static func fullPresetInline(original: String, width: Int, height: Int) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: original)),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out = obj["output"] as? [String: Any] ?? [:]
        out["output_width"] = width; out["output_height"] = height
        obj["output"] = out
        return jsonString(obj)
    }

    /// Inhalt einer Preset-Datei als Inline-JSON (Gyroflow muss dann keine Datei lesen: cli.rs liest Presets sonst mit
    /// `read_to_string(preset).expect("Reading preset file")` – ein Lesefehler ist ein Panic = Exit-Code 101).
    nonisolated static func presetInline(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return jsonString(obj)
    }

    // MARK: App-Store-/Sandbox-Erkennung

    struct SandboxInfo { let sandboxed: Bool; let evidence: String }

    /// Eindeutig statt geraten: App-Store-Beleg (Contents/_MASReceipt/receipt) oder Entitlement com.apple.security.app-sandbox.
    nonisolated static func sandboxInfo(app: URL) async -> SandboxInfo {
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            return SandboxInfo(sandboxed: true, evidence: "App-Store-Beleg (_MASReceipt) im App-Paket")
        }
        let out = await runTool("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        if entitlementsSandboxed(out) {
            return SandboxInfo(sandboxed: true, evidence: "Entitlement com.apple.security.app-sandbox")
        }
        return SandboxInfo(sandboxed: false, evidence: "")
    }

    /// Entitlements-Plist (XML) auswerten: Schlüssel app-sandbox mit <true/>
    nonisolated static func entitlementsSandboxed(_ plist: String) -> Bool {
        guard let r = plist.range(of: "com.apple.security.app-sandbox") else { return false }
        // nur bis zum nächsten Schlüssel schauen (sonst zählt das <true/> eines anderen Entitlements)
        var after = String(plist[r.upperBound...].prefix(200))
        if let next = after.range(of: "<key>") { after = String(after[..<next.lowerBound]) }
        return after.contains("<true/>")
    }

    nonisolated static func sandboxMessage(app: URL, evidence: String) -> String {
        "Diese Gyroflow-App („\(app.lastPathComponent)“) ist die App-Store-Version (\(evidence)). Sie läuft in Apples Sandbox und darf weder deine Clips noch das Preset aus „~/Library/Application Support/CamSort“ lesen – CamSort kann sie deshalb nicht steuern.\n\nSo geht’s: 1. Gyroflow kostenlos von gyroflow.xyz laden und in „Programme“ legen. 2. CamSort › Einstellungen › Gyroflow › Gyroflow-App wählen und diese Version auswählen. 3. Erneut stabilisieren."
    }

    /// Kommandozeilen-Werkzeug im Hintergrund ausführen (blockiert nie den Main-Thread), stdout+stderr zurück
    nonisolated static func runTool(_ path: String, _ args: [String]) async -> String {
        await Task.detached(priority: .utility) { () -> String in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return "" }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }.value
    }

    // MARK: Log & Fehlermeldung

    nonisolated static var logDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("CamSort/Gyroflow-Logs", isDirectory: true)
    }

    /// Argument für die Log-Zeile shell-tauglich quoten
    nonisolated static func shellQuote(_ a: String) -> String {
        let special = a.contains { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "{" || $0 == "(" }
        return special ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a
    }

    /// Log je Clip: Kommandozeile mit allen Argumenten, komplette Ausgabe, Exit-Code
    nonisolated static func writeLog(clip: URL, exe: URL, args: [String], output: String, status: Int32, note: String) -> URL? {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = logDir.appendingPathComponent("\(f.string(from: Date()))_\(clip.deletingPathExtension().lastPathComponent).log")
        let lines: [String] = [
            "CamSort – Gyroflow-Log",
            "Clip: \(clip.path)",
            "Variante: \(note)",
            "Exit-Code: \(status)" + (status == 101 ? " (Rust-Panic in Gyroflow)" : ""),
            "",
            "Kommandozeile:",
            ([exe.path] + args).map(shellQuote).joined(separator: " "),
            "",
            "---- Ausgabe (stdout + stderr) ----",
            output,
        ]
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    /// Aussagekräftige Zeilen: MDK-Banner/Copyright/„Build for“ und Fortschritt raus, Fehlerzeilen bevorzugt
    nonisolated static func meaningfulLines(_ out: String, max n: Int = 3) -> [String] {
        let noise = ["multimedia development kit", "copyright", "build for", "wangbin", "mdk-sdk", "github.com/wang-bin"]
        let lines = out.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { l in
                guard !l.isEmpty else { return false }
                let low = l.lowercased()
                if noise.contains(where: { low.contains($0) }) { return false }
                if l.range(of: #"^[\d.\s%/:|]+$"#, options: .regularExpression) != nil { return false }   // reiner Fortschritt
                return true
            }
        let keys = ["error", "failed", "panic", "denied", "not permitted", "unable", "invalid", "cannot", "can't"]
        let hot = lines.filter { l in let low = l.lowercased(); return keys.contains { low.contains($0) } }
        return Array((hot.isEmpty ? lines : hot).suffix(n))
    }

    private func runAll(exe: URL, preset: String, originalPreset: String, hochkantCount: Int, folders: [URL]) async {
        var variant: PresetVariant = store.gyroMatchSource && preset != originalPreset ? .reduced : .full
        var fallbackTried = false
        let suffix = Self.safeSuffix(store.gyroSuffixList)
        var plainForPortrait = false
        sorter?.beginGyroPlacement(folders: folders)
        while index < queue.count {
            if cancelled { break }
            while pauseRequested && !cancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
            if cancelled { break }
            let clip = queue[index]
            currentGroup = index < hochkantCount ? "Hochkant" : "Quer"
            currentFile = clip.lastPathComponent
            filePercent = 0
            // Nie überschreiben: gibt es die stabilisierte Fassung schon (Stabilisiert-Ordner oder neben dem Original), Clip überspringen
            let clipDir = clip.deletingLastPathComponent()
            if let existing = Self.existingOutput(of: clip, suffix: suffix) {
                skippedExisting += 1
                let where_ = existing.deletingLastPathComponent().standardizedFileURL.path == clipDir.standardizedFileURL.path ? "neben dem Original" : Self.shortPath(existing.deletingLastPathComponent())
                errors.append("Hinweis – \(clip.lastPathComponent): stabilisierte Fassung „\(existing.lastPathComponent)“ gibt es schon (\(where_)) – nicht neu gerendert, nichts überschrieben.")
                index += 1
                continue
            }
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: clipDir.path)) ?? [])
            let isPortrait = index < hochkantCount
            var res = await render(exe: exe, clip: clip, preset: preset, originalPreset: originalPreset,
                                   variant: plainForPortrait && isPortrait ? .plain : variant, before: before)
            if cancelled { break }
            // Fallback: reduziertes Preset + -p gescheitert → EINMAL mit komplettem Original-Preset (nur Ausgabegröße) versuchen
            if !res.ok && variant == .reduced && !fallbackTried && !(plainForPortrait && isPortrait) {
                fallbackTried = true
                let retry = await render(exe: exe, clip: clip, preset: preset, originalPreset: originalPreset, variant: .full, before: before)
                if cancelled { break }
                if retry.ok {
                    variant = .full
                    res = retry
                    errors.append("Hinweis – \(clip.lastPathComponent): Gyroflow akzeptierte die Ausgabe-Parameter nicht – mit komplettem Preset gerendert (gilt für den Rest des Laufs).")
                }
            }
            // Ausrichtung des Ergebnisses prüfen: Hochkant-Clip darf nie als Quer-Clip (beschnitten) einsortiert werden
            if res.ok, let out = res.outputs.first {
                let want = await Self.videoOrientation(clip)
                let got = await Self.videoOrientation(out)
                if want != got {
                    res.ok = false
                    var msg = "\(clip.lastPathComponent): Ausgabe falsch ausgerichtet (\(got) statt \(want)) – nicht einsortiert"
                    if let sorter, let q = await sorter.quarantineStabilized(res.outputs + res.projects, clipDir: clipDir) { msg += ", liegt in „\(Self.shortPath(q))“" }
                    if want == FolderNames.portrait && !plainForPortrait {
                        plainForPortrait = true
                        msg += ". Weitere Hochkant-Clips dieses Laufs: komplettes Preset ohne Größenvorgabe."
                    }
                    res.message = msg
                }
            }
            if res.ok {
                done.append(clip.lastPathComponent)
                // Sofort ablegen: <Eltern>/Stabilisiert/<Ebene>/ – über das sichere Verschieben mit Protokoll (Rückgängig möglich)
                if let sorter, let dest = await sorter.placeStabilized(res.outputs, projects: res.projects, clipDir: clipDir) {
                    placed.append("\(clip.lastPathComponent) → \(Self.shortPath(dest))")
                    let stabRoot = dest.deletingLastPathComponent()
                    if !stabilizedDirs.contains(stabRoot) { stabilizedDirs.append(stabRoot) }
                } else {
                    errors.append("\(clip.lastPathComponent): stabilisiert, aber nicht in „\(FolderNames.stabilized)“ verschoben – die Datei liegt neben dem Original (Details unter Hinweise).")
                }
            } else { errors.append(res.message) }
            index += 1
            // Nur Zusatzhinweis – die eigentliche App-Store-Erkennung läuft vor dem Start
            if !res.ok && done.isEmpty && index == 1 && fullOutput.lowercased().contains("not permitted") {
                errors.append("Hinweis: Gyroflow meldet „Operation not permitted“ – fehlender Zugriff (Sandbox oder Datenschutz-Freigabe für Ordner/Laufwerk). Details im Log.")
            }
        }
        currentFile = ""
        // Kein nachträgliches Trennen mehr: jeder Clip wurde schon direkt nach dem Rendern abgelegt, Originale bleiben, wo sie sind.
        sorter?.endGyroPlacement(placedOriginals: queue.prefix(index).filter { done.contains($0.lastPathComponent) })
        if cancelled { state = .idle; return }
        if !done.isEmpty { sorter?.hints.append("Gyroflow: \(done.count) von \(queue.count) Clips stabilisiert – in „\(FolderNames.stabilized)“, Originale unverändert") }
        state = .finished
    }

    /// „A1/Stabilisiert/Hochkant“ – die letzten drei Ordner für die Anzeige
    nonisolated static func shortPath(_ dir: URL) -> String {
        dir.standardizedFileURL.pathComponents.suffix(3).joined(separator: "/")
    }

    /// Gibt es schon eine stabilisierte Fassung (Name = Stamm + Suffix + „.“) im Stabilisiert-Ordner oder neben dem Original?
    nonisolated static func existingOutput(of clip: URL, suffix: String) -> URL? {
        let dir = clip.deletingLastPathComponent()
        let prefix = (clip.deletingPathExtension().lastPathComponent + suffix + ".").lowercased()
        for d in [FolderNames.stabilizedDir(forClipDir: dir), dir] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            if let n = names.first(where: { $0.lowercased().hasPrefix(prefix) && $0.lowercased().hasSuffix(".gyroflow") == false }) {
                return d.appendingPathComponent(n)
            }
        }
        return nil
    }

    struct RenderResult { var ok: Bool; var message: String; var outputs: [URL] = []; var projects: [URL] = [] }

    /// before: Dateinamen im Clip-Ordner VOR dem ersten Versuch (damit auch beim Fallback-Versuch alles Neue erkannt wird)
    private func render(exe: URL, clip: URL, preset: String, originalPreset: String, variant: PresetVariant, before: Set<String>) async -> RenderResult {
        // Suffix nie leer → Ausgabe heißt nie wie das Original (Gyroflow: Ausgabe = Ordner des Clips + Stamm + Suffix)
        let suffix = Self.safeSuffix(store.gyroSuffixList)
        let outDir = clip.deletingLastPathComponent()
        let stem = clip.deletingPathExtension().lastPathComponent
        guard !stem.lowercased().contains(suffix.lowercased()) else {
            return RenderResult(ok: false, message: "\(clip.lastPathComponent): ist schon eine stabilisierte Fassung – übersprungen")
        }
        let p = Process()
        p.executableURL = exe
        // Preset inline übergeben (Gyroflow liest dann keine Datei → kein „Reading preset file“-Panic)
        var presetArg = Self.presetInline(preset) ?? preset
        var note = "Preset: " + (preset as NSString).lastPathComponent
        var outParams: String? = nil
        if variant == .plain {
            presetArg = Self.presetInline(originalPreset) ?? originalPreset
            note = "Preset: " + (originalPreset as NSString).lastPathComponent + " (komplett, ohne Größenvorgabe)"
        } else if store.gyroMatchSource {
            if variant == .reduced {
                // Ausgabe wie Eingabeclip: Größe/Codec/Bitrate/Ton pro Clip über -p/--out-params (gyroflow src/cli.rs).
                outParams = await Self.outputParams(for: clip)
                note += " (reduziert) + -p"
            } else if let d = await Self.outputParamsDict(for: clip), let w = d["output_width"] as? Int, let h = d["output_height"] as? Int,
                      let full = Self.fullPresetInline(original: originalPreset, width: w, height: h) {
                presetArg = full
                note = "Preset: " + (originalPreset as NSString).lastPathComponent + " (komplett, nur Ausgabegröße \(w)×\(h))"
            }
        }
        // Drohnen-Clip: Tiefpassfilter an (gilt für reduziertes, komplettes und Fallback-Preset)
        if store.gyroDroneLPF && Self.isDrone(clip, source: Self.gyroSource(clip)) {
            let prevArg = presetArg
            presetArg = Self.withLowPass(presetArg, hz: store.gyroDroneLPFHz)
            if presetArg != prevArg { note += " + Tiefpass \(Int(store.gyroDroneLPFHz)) Hz (Drohne)" }
        }
        // -f (overwrite) betrifft nur Gyroflows Ausgabedatei (cli.rs: Fehler „file_exists:“ des Render-Jobs). Vorher ist geprüft,
        // dass es keine Datei „Stamm+Suffix.*“ gibt – -f kann also nur eine Teil-Ausgabe dieses Laufs (Fallback-Versuch) ersetzen.
        var args = [clip.path, "--preset", presetArg, "-t", suffix, "-f", "--stdout-progress"]
        if let json = outParams { args += ["-p", json] }
        p.arguments = args
        p.standardInput = FileHandle.nullDevice   // keine Rückfragen – nichts kann auf Eingabe warten
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        lastOutput = ""; fullOutput = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleOutput(s) }
        }
        do { try p.run() } catch {
            return RenderResult(ok: false, message: "\(clip.lastPathComponent): Gyroflow konnte nicht gestartet werden (\(error.localizedDescription))")
        }
        process = p
        while p.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = nil
        // Rest der Ausgabe im Hintergrund lesen (Prozess ist beendet → EOF)
        let rest = await Task.detached { () -> Data in reader.readDataToEndOfFile() }.value
        if !rest.isEmpty { handleOutput(String(decoding: rest, as: UTF8.self)) }
        process = nil
        if cancelled { return RenderResult(ok: false, message: "") }
        let found = Self.newOutputs(in: outDir, before: before, clip: clip, suffix: suffix)
        let produced = !found.videos.isEmpty
        let status = p.terminationStatus
        let log = Self.writeLog(clip: clip, exe: exe, args: args, output: fullOutput, status: status, note: note)
        if status == 0 && produced { filePercent = 1; return RenderResult(ok: true, message: "", outputs: found.videos, projects: found.projects) }
        if let log { lastLogURL = log }
        var lines = Self.meaningfulLines(fullOutput)
        if status == 0 && !produced { lines.append("keine Ausgabedatei „\(stem + suffix)…“ entstanden") }
        let panic = status == 101 ? " – Gyroflow ist abgestürzt (Rust-Panic)" : ""
        let detail = lines.isEmpty ? " – keine Fehlermeldung von Gyroflow" : " – " + lines.joined(separator: " | ")
        let logNote = log.map { " (Log: \($0.lastPathComponent))" } ?? ""
        return RenderResult(ok: false, message: "\(clip.lastPathComponent): Gyroflow-Fehler (Code \(status))\(panic)\(detail)\(logNote)")
    }

    /// Was Gyroflow für diesen Clip neu erzeugt hat: Video „Stamm+Suffix.*“ (nicht leer, nie das Original) und ggf. .gyroflow-Projekt
    nonisolated static func newOutputs(in dir: URL, before: Set<String>, clip: URL, suffix: String) -> (videos: [URL], projects: [URL]) {
        let fm = FileManager.default
        let stem = clip.deletingPathExtension().lastPathComponent.lowercased()
        let prefix = (stem + suffix + ".").lowercased()
        let now = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var v: [URL] = [], g: [URL] = []
        for n in now where !before.contains(n) && n != clip.lastPathComponent {
            let low = n.lowercased()
            let u = dir.appendingPathComponent(n)
            if low.hasSuffix(".gyroflow") && low.hasPrefix(stem) { g.append(u); continue }
            guard low.hasPrefix(prefix), Sorter.videoExt.contains(u.pathExtension.lowercased()) else { continue }
            let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0 && u.standardizedFileURL.path != clip.standardizedFileURL.path { v.append(u) }
        }
        return (v.sorted { $0.path < $1.path }, g.sorted { $0.path < $1.path })
    }

    private func handleOutput(_ s: String) {
        lastOutput = String((lastOutput + s).suffix(2000))
        if fullOutput.utf8.count < 8_000_000 { fullOutput += s }
        // Fortschritt als Prozent oder als „aktuell/gesamt“ erkennen
        if let r = s.range(of: #"(\d{1,3}(\.\d+)?)\s*%"#, options: .regularExpression, range: nil, locale: nil) {
            let n = s[r].filter { "0123456789.".contains($0) }
            if let v = Double(n), v <= 100 { filePercent = v / 100 }
        } else if let r = s.range(of: #"(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
            let parts = s[r].split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[1] > 0 { filePercent = min(1, parts[0] / parts[1]) }
        }
    }

    func pause() {
        pauseRequested = true
        if let p = process, p.isRunning { _ = p.suspend() }
        eta.pause()
        state = .paused
    }

    func resume() {
        pauseRequested = false
        if let p = process, p.isRunning { _ = p.resume() }
        eta.resume()
        state = .running
    }

    func cancel() {
        cancelled = true
        if let p = process, p.isRunning {
            if pauseRequested { _ = p.resume() }
            p.terminate()
        }
        pauseRequested = false
    }

    func close() { state = .idle; queue = []; errors = []; done = []; placed = []; stabilizedDirs = []; skippedExisting = 0; lastLogURL = nil }
}

// MARK: - Ansicht

struct GyroView: View {
    @EnvironmentObject var gyro: GyroRunner

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: gyro.overall)
                    .stroke(AngularGradient(colors: [Theme.mint, Theme.orange, Theme.mint], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: gyro.overall)
                VStack(spacing: 4) {
                    Image(systemName: "gyroscope").font(.system(size: 26)).foregroundStyle(Theme.mint)
                    Text("\(Int(gyro.overall * 100)) %").font(.system(size: 34, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text(gyro.queue.isEmpty ? " " : "Clip \(min(gyro.index + 1, gyro.queue.count)) von \(gyro.queue.count)")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 180, height: 180)

            switch gyro.state {
            case .running, .paused:
                VStack(spacing: 6) {
                    Text(gyro.state == .paused ? "Pausiert" : "Gyroflow stabilisiert \(gyro.currentGroup)-Clips …")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(gyro.currentFile).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: gyro.filePercent).tint(Theme.orange).frame(maxWidth: 300)
                    Label(gyro.state == .paused ? "pausiert" : gyro.remainingText, systemImage: "clock")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mint)
                    Text("Clips werden einzeln nacheinander gerendert – erst Hochkant, dann Quer. Jeder fertige Clip kommt sofort nach „\(FolderNames.stabilized)“, die Originale bleiben, wo sie sind.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                }
                if !gyro.placed.isEmpty { GyroPlacedList(lines: gyro.placed) }
                HStack(spacing: 12) {
                    Button { gyro.state == .paused ? gyro.resume() : gyro.pause() } label: {
                        Label(gyro.state == .paused ? "Fortsetzen" : "Pause",
                              systemImage: gyro.state == .paused ? "play.fill" : "pause.fill")
                            .frame(width: 140, height: 40)
                            .background(Capsule().fill(Theme.orange))
                    }.buttonStyle(.plain)
                    Button { gyro.cancel() } label: {
                        Label("Abbrechen", systemImage: "stop.fill")
                            .frame(width: 140, height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
                .font(.system(size: 14, weight: .semibold))
            case .finished:
                VStack(spacing: 10) {
                    Text(gyro.placed.isEmpty
                         ? "Gyroflow ist fertig – \(gyro.done.count) von \(gyro.queue.count) Clips stabilisiert."
                         : "\(gyro.placed.count) \(gyro.placed.count == 1 ? "Clip" : "Clips") stabilisiert – in „\(FolderNames.stabilized)“ neben Hochkant/Quer; Originale unverändert")
                        .font(.system(size: 15, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                    if gyro.skippedExisting > 0 {
                        Text("\(gyro.skippedExisting) übersprungen – stabilisierte Fassung gab es schon (nichts überschrieben)")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    if !gyro.placed.isEmpty { GyroPlacedList(lines: gyro.placed) }
                    if !gyro.stabilizedDirs.isEmpty {
                        Button { NSWorkspace.shared.activateFileViewerSelecting(gyro.stabilizedDirs) } label: {
                            Label("Im Finder zeigen", systemImage: "folder")
                        }.buttonStyle(.bordered)
                    }
                }
            case .failed(let msg):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(Theme.orange)
                    Text(msg).font(.system(size: 13)).multilineTextAlignment(.center)
                }
            case .idle: EmptyView()
            }

            if !gyro.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(gyro.errors, id: \.self) { Text("• " + $0).font(.system(size: 11)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
                if let log = gyro.lastLogURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([log]) } label: {
                        Label("Log zeigen", systemImage: "doc.text.magnifyingglass")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }

            Spacer(minLength: 0)

            if gyro.state != .running && gyro.state != .paused {
                Button { gyro.close() } label: {
                    Text("Schließen").frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Liste „C0001.MP4 → A1/Stabilisiert/Hochkant“ (neueste unten)
struct GyroPlacedList: View {
    let lines: [String]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.mint)
                        .lineLimit(1).truncationMode(.middle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 90).padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.mint.opacity(0.08)))
    }
}

// MARK: - Hilfe-Knopf

struct HelpButton: View {
    let title: String
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// Zeile mit Inhalt + ?-Knopf
struct WithHelp<Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content
            Spacer(minLength: 4)
            HelpButton(title: title, text: text)
        }
    }
}
