import Foundation

/// Ordnernamen und Benennung – in den Einstellungen änderbar. Alte/Standardnamen werden weiter erkannt,
/// damit bereits sortierte Ordner nach einer Umbenennung nicht doppelt sortiert werden.
enum FolderNames {
    static var videos = "Videos"
    static var photos = "Fotos"
    static var side = "Begleitdateien"
    static var extras = "Extras"
    static var separator = " · "
    static var showCamera = true
    static var showOrientation = true
    static var sceneWord = "Szene"
    static var sceneShowTime = true
    static var sceneShowCams = true

    static var videoAliases: Set<String> { ["Videos", videos] }
    static func isVideos(_ s: String) -> Bool { videoAliases.contains(s) }
    static var outputNames: Set<String> { [videos, photos, side, extras, "Videos", "Fotos", "Begleitdateien", "Extras", square, "Quadratisch"] }

    /// Ausrichtungs-Ordner (fest, wie überall in CamSort)
    static let portrait = "Hochkant"
    static let landscape = "Quer"
    /// Quadratisch (Seitenverhältnis 0,9–1,1, z. B. DJI Osmo Action 6 mit 3840×3840) – einstellbar
    static var square = "Quadratisch"
    static var squareAliases: Set<String> { ["Quadratisch", square] }
    /// Vergleich unabhängig von Groß/Klein und Unicode-Form (NFC/NFD, z. B. Umlaute vom Volume)
    static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
    static func isOrientation(_ s: String) -> Bool { let f = fold(s); return f == fold(portrait) || f == fold(landscape) || squareAliases.contains { fold($0) == f } }
    /// Ausrichtung aus der (gedrehten) Bildgröße: ≤ 1,1 : 1 → Quadratisch; sonst Hochkant/Quer (4:3 = Quer, 3:4 = Hochkant)
    static func orientation(width w: Double, height h: Double) -> String? {
        guard w > 0, h > 0 else { return nil }
        let r = max(w, h) / min(w, h)
        if r <= 1.1 { return square }
        return h > w ? portrait : landscape
    }
    /// Liegt der Clip in einem sortierten Bereich? (unter „Videos“ oder – Modus „Meine Kameraordner“ – unter Hochkant/Quer)
    static func isSortedVideoPath(_ comps: [String]) -> Bool {
        comps.contains(where: isVideos) || comps.dropLast().contains(where: isOrientation)
    }

    static func load(_ d: UserDefaults = .standard) {
        func s(_ k: String, _ def: String) -> String { let v = d.string(forKey: k)?.trimmingCharacters(in: .whitespaces) ?? ""; return v.isEmpty ? def : v.replacingOccurrences(of: "/", with: "-") }
        videos = s("fnVideos", "Videos"); photos = s("fnPhotos", "Fotos"); side = s("fnSide", "Begleitdateien"); extras = s("fnExtras", "Extras")
        square = s("fnSquare", "Quadratisch")
        separator = d.string(forKey: "fnSeparator") ?? " · "
        showCamera = d.object(forKey: "fnShowCamera") as? Bool ?? true
        showOrientation = d.object(forKey: "fnShowOrientation") as? Bool ?? true
        sceneWord = s("fnSceneWord", "Szene")
        sceneShowTime = d.object(forKey: "fnSceneTime") as? Bool ?? true
        sceneShowCams = d.object(forKey: "fnSceneCams") as? Bool ?? true
    }
}
