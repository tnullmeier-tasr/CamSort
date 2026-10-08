import Foundation

/// Vom Nutzer gelernte Regeln – dauerhaft in den App-Einstellungen gespeichert.
struct CameraRule: Codable, Hashable, Identifiable {
    var id: String { prefix + "|" + ext }
    let prefix: String      // Dateinamen-Anfang, z. B. "MVI_" – "#" = beginnt mit Ziffern
    let ext: String         // kleingeschrieben, z. B. "mp4"
    let camera: String
}

enum FileCategory: String, Codable, CaseIterable, Identifiable {
    case video, photo, side, ignore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: return "Video"
        case .photo: return "Foto"
        case .side: return "Begleitdatei (eigener Ordner)"
        case .ignore: return "Ignorieren"
        }
    }
}

@MainActor
final class LearnedStore: ObservableObject {
    @Published private(set) var rules: [CameraRule] = []
    @Published private(set) var extensions: [String: FileCategory] = [:]

    private let d = UserDefaults.standard
    init() {
        if let data = d.data(forKey: "cameraRules"), let r = try? JSONDecoder().decode([CameraRule].self, from: data) { rules = r }
        if let data = d.data(forKey: "extensions"), let e = try? JSONDecoder().decode([String: FileCategory].self, from: data) { extensions = e }
    }
    private func save() {
        d.set(try? JSONEncoder().encode(rules), forKey: "cameraRules")
        d.set(try? JSONEncoder().encode(extensions), forKey: "extensions")
    }

    static func prefix(of fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        if let f = stem.first, f.isNumber { return "#" }
        var p = ""
        for ch in stem { if ch.isNumber { break }; p.append(ch) }
        return p.isEmpty ? stem : p
    }
    static func prefixLabel(_ p: String) -> String { p == "#" ? "beginnt mit Ziffern" : "beginnt mit „\(p)“" }

    func camera(for fileName: String) -> String? {
        let p = Self.prefix(of: fileName), e = (fileName as NSString).pathExtension.lowercased()
        return rules.first { $0.prefix == p && $0.ext == e }?.camera
    }
    func learnCamera(fileName: String, camera: String) {
        let r = CameraRule(prefix: Self.prefix(of: fileName), ext: (fileName as NSString).pathExtension.lowercased(), camera: camera)
        rules.removeAll { $0.id == r.id }
        rules.append(r); save()
    }
    func remove(_ r: CameraRule) { rules.removeAll { $0 == r }; save() }

    func learnExtension(_ ext: String, as cat: FileCategory) { extensions[ext] = cat; save() }
    func removeExtension(_ ext: String) { extensions[ext] = nil; save() }
    var cameraNames: [String] { Array(Set(rules.map(\.camera))).sorted() }
}
