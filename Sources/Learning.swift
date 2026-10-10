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

    func learnExtension(_ ext: String, as cat: FileCategory) { extensions[ext] = cat; save() }
    func removeExtension(_ ext: String) { extensions[ext] = nil; save() }
    var cameraNames: [String] { Array(Set(rules.map(\.camera))).sorted() }
}
