import Foundation

/// Vom Nutzer gelernte Kamera-Zuordnung – dauerhaft gespeichert.
struct CameraRule: Codable, Hashable, Identifiable {
    var id: String { signature }
    let signature: String   // z. B. "auto:Sony Alpha 1", "dji:DJI FC8482+srt", "name:MVI_|mp4"
    let label: String       // menschenlesbar: woran erkannt
    let camera: String      // Ordnername, den der Nutzer gewählt hat
}

enum FileCategory: String, Codable, CaseIterable, Identifiable {
    case video, photo, music, archive, project, side, ignore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: return "Video"
        case .photo: return "Foto"
        case .music: return "Musik"
        case .archive: return "ZIP / Archiv"
        case .project: return "Final-Cut-Projekt"
        case .side: return "Begleitdatei (eigener Ordner)"
        case .ignore: return "Ignorieren"
        }
    }
    /// Zielordner für alles außer Video/Begleitdatei
    var folder: String? {
        switch self {
        case .photo: return "Fotos"
        case .music: return "Musik"
        case .archive: return "ZIP"
        case .project: return "FCP"
        default: return nil
        }
    }
}

@MainActor
final class LearnedStore: ObservableObject {
    @Published private(set) var rules: [CameraRule] = []
    @Published private(set) var extensions: [String: FileCategory] = [:]
    @Published var confirmCameras: Bool { didSet { d.set(confirmCameras, forKey: "confirmCameras") } }
    @Published var includeSubfolders: Bool { didSet { d.set(includeSubfolders, forKey: "includeSubfolders") } }
    @Published var sortByLens: Bool { didSet { d.set(sortByLens, forKey: "sortByLens") } }
    @Published var droneBySpeed: Bool { didSet { d.set(droneBySpeed, forKey: "droneBySpeed") } }
    @Published var standMin: Double { didSet { d.set(standMin, forKey: "standMin") } }
    @Published var standMax: Double { didSet { d.set(standMax, forKey: "standMax") } }
    @Published var moveMin: Double { didSet { d.set(moveMin, forKey: "moveMin") } }
    @Published var moveMax: Double { didSet { d.set(moveMax, forKey: "moveMax") } }
    @Published var gyroPresetPath: String { didSet { d.set(gyroPresetPath, forKey: "gyroPresetPath") } }
    @Published var gyroPresetSource: String { didSet { d.set(gyroPresetSource, forKey: "gyroPresetSource") } }
    @Published var gyroAppPath: String { didSet { d.set(gyroAppPath, forKey: "gyroAppPath") } }
    @Published var showGyroButton: Bool { didSet { d.set(showGyroButton, forKey: "showGyroButton") } }
    @Published var enableTagging: Bool { didSet { d.set(enableTagging, forKey: "enableTagging") } }
    /// Kompakt: nur Unterscheidungen als Ordner, die es im Dreh wirklich gibt (Standard)
    @Published var compactLayout: Bool { didSet { d.set(compactLayout, forKey: "compactLayout") } }
    /// Eigene Ordner für Videos, die nicht von einer Kamera stammen (Exporte, Bildschirmaufnahmen …)
    @Published var specialFolders: [String] { didSet { d.set(specialFolders, forKey: "specialFolders") } }
    static let folderPrefix = "📁 "
    /// Videos nach Szenen (zusammenhängende Drehzeit, alle Kameras) statt nach Kamera ordnen
    @Published var groupByScene: Bool { didSet {
        d.set(groupByScene, forKey: "groupByScene")
        if !syncing { levels = groupByScene ? ["scene"] : ["camera", "orientation"] }
    } }
    /// Ordner-Baukasten: aktive Kriterien in Reihenfolge – scene, camera, lens, length, orientation, speed
    @Published var levels: [String] { didSet {
        d.set(levels, forKey: "levels")
        syncing = true
        groupByScene = levels.contains("scene"); sortByLens = levels.contains("lens"); droneBySpeed = levels.contains("speed")
        syncing = false
    } }
    @Published var nestLevels: Bool { didSet { d.set(nestLevels, forKey: "nestLevels") } }
    @Published var lengthThreshold: Double { didSet { d.set(lengthThreshold, forKey: "lengthThreshold") } }
    @Published var lengthShort: String { didSet { d.set(lengthShort, forKey: "lengthShort") } }
    @Published var lengthLong: String { didSet { d.set(lengthLong, forKey: "lengthLong") } }
    private var syncing = false
    static let allLevels: [(id: String, name: String, icon: String)] = [
        ("scene", "Szene (zusammenhängende Drehzeit)", "film.stack"),
        ("camera", "Kamera", "camera.fill"),
        ("lens", "Objektiv", "camera.aperture"),
        ("length", "Länge (Einblendung / Hauptspur)", "timer"),
        ("orientation", "Hochkant / Quer", "rectangle.portrait.on.rectangle.portrait"),
        ("speed", "Drohne: Stand / Fahrt", "airplane"),
    ]
    @Published var sceneGapMinutes: Double { didSet { d.set(sceneGapMinutes, forKey: "sceneGapMinutes") } }
    @Published var autoGyro: Bool { didSet { d.set(autoGyro, forKey: "autoGyro") } }
    @Published var gyroSuffixes: String { didSet { d.set(gyroSuffixes, forKey: "gyroSuffixes") } }
    var gyroSuffixList: [String] {
        gyroSuffixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private let d = UserDefaults.standard
    init() {
        confirmCameras = d.object(forKey: "confirmCameras") as? Bool ?? true
        includeSubfolders = d.object(forKey: "includeSubfolders") as? Bool ?? true
        sortByLens = d.object(forKey: "sortByLens") as? Bool ?? false
        droneBySpeed = d.object(forKey: "droneBySpeed") as? Bool ?? false
        standMin = d.object(forKey: "standMin") as? Double ?? 0
        standMax = d.object(forKey: "standMax") as? Double ?? 3
        moveMin = d.object(forKey: "moveMin") as? Double ?? 5
        moveMax = d.object(forKey: "moveMax") as? Double ?? 100
        autoGyro = d.object(forKey: "autoGyro") as? Bool ?? true
        groupByScene = d.object(forKey: "groupByScene") as? Bool ?? true
        sceneGapMinutes = d.object(forKey: "sceneGapMinutes") as? Double ?? 5
        nestLevels = d.object(forKey: "nestLevels") as? Bool ?? false
        lengthThreshold = d.object(forKey: "lengthThreshold") as? Double ?? 30
        lengthShort = d.string(forKey: "lengthShort") ?? "Einblendungen"
        lengthLong = d.string(forKey: "lengthLong") ?? "Hauptspur"
        if let l = d.stringArray(forKey: "levels") { levels = l }
        else {
            let scene = d.object(forKey: "groupByScene") as? Bool ?? true
            var l: [String] = scene ? ["scene"] : ["camera"]
            if d.bool(forKey: "sortByLens") && !scene { l.append("lens") }
            if !scene { l.append("orientation") }
            if d.bool(forKey: "droneBySpeed") { l.append("speed") }
            levels = l
        }
        specialFolders = d.stringArray(forKey: "specialFolders") ?? ["Finale Videos", "Soundeffekte", "Bildschirmaufnahmen"]
        compactLayout = d.object(forKey: "compactLayout") as? Bool ?? true
        enableTagging = d.object(forKey: "enableTagging") as? Bool ?? false
        showGyroButton = d.object(forKey: "showGyroButton") as? Bool ?? true
        gyroPresetPath = d.string(forKey: "gyroPresetPath") ?? ""
        gyroAppPath = d.string(forKey: "gyroAppPath") ?? ""
        gyroPresetSource = d.string(forKey: "gyroPresetSource") ?? ""
        gyroSuffixes = d.string(forKey: "gyroSuffixes") ?? "_stabilized, _stabilisiert, _gyroflow, _gyro"
        if let data = d.data(forKey: "cameraRules2"), let r = try? JSONDecoder().decode([CameraRule].self, from: data) { rules = r }
        if let data = d.data(forKey: "extensions2"), let e = try? JSONDecoder().decode([String: FileCategory].self, from: data) { extensions = e }
    }
    private func save() {
        d.set(try? JSONEncoder().encode(rules), forKey: "cameraRules2")
        d.set(try? JSONEncoder().encode(extensions), forKey: "extensions2")
    }

    static func prefix(of fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        if let f = stem.first, f.isNumber { return "#" }
        var p = ""
        for ch in stem { if ch.isNumber { break }; p.append(ch) }
        return p.isEmpty ? stem : p
    }
    static func prefixLabel(_ p: String) -> String { p == "#" ? "beginnt mit Ziffern" : "beginnt mit „\(p)“" }

    func camera(for signature: String) -> String? { rules.first { $0.signature == signature }?.camera }
    func learn(signature: String, label: String, camera: String) {
        rules.removeAll { $0.signature == signature }
        rules.append(CameraRule(signature: signature, label: label, camera: camera)); save()
    }
    func remove(_ r: CameraRule) { rules.removeAll { $0 == r }; save() }

    /// Preset in CamSorts eigenen Ordner kopieren (Application Support) – dort braucht es keine
    /// Ordner-Freigabe von macOS, auch nicht nach einem App-Update. Gibt eine Fehlermeldung zurück oder nil.
    @discardableResult
    func importPreset(from url: URL) -> String? {
        guard url.pathExtension.lowercased() == "gyroflow" else { return "Bitte eine Datei mit der Endung .gyroflow wählen." }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "Die Datei ließ sich nicht lesen. Bitte erneut wählen und die macOS-Nachfrage nach dem Zugriff mit „Erlauben“ bestätigen."
        }
        let dir = Self.presetDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try data.write(to: dst, options: .atomic)
            gyroPresetPath = dst.path
            gyroPresetSource = url.path
            return nil
        } catch { return "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }
    static var presetDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamSort/Gyroflow-Presets")
    }
    /// Altes Preset (aus früheren Versionen direkt verlinkt) einmalig übernehmen
    func migratePresetIfNeeded() {
        guard !gyroPresetPath.isEmpty, !gyroPresetPath.hasPrefix(Self.presetDir.path) else { return }
        _ = importPreset(from: URL(fileURLWithPath: gyroPresetPath))
    }

    func learnExtension(_ ext: String, as cat: FileCategory) { extensions[ext] = cat; save() }
    func removeExtension(_ ext: String) { extensions[ext] = nil; save() }
    var cameraNames: [String] { Array(Set(rules.map(\.camera).filter { !$0.hasPrefix(Self.folderPrefix) })).sorted() }
    func addFolder(_ n: String) {
        let t = n.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        if !t.isEmpty && !specialFolders.contains(t) { specialFolders.append(t) }
    }
}
