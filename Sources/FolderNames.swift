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
    /// Videos-Sammelordner anlegen (Dreh/Videos/…). Aus: Ebenen liegen direkt im Dreh-Ordner (Dreh/Kamera/Quer).
    static var useVideosFolder = true

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
    /// Auch ohne „Videos“-Ordner: Ausrichtungs-/FPS-Ordner (auch als Teil eines zusammengesetzten Namens „Sony · Quer“)
    static func isSortedVideoPath(_ comps: [String]) -> Bool {
        comps.contains(where: isVideos) || comps.dropLast().contains(where: hasOrientationPart) || comps.dropLast().contains(where: hasFpsPart)
    }
    /// Ausrichtung als ganzer Name oder als Teil eines zusammengesetzten Namens („Sony · Quer“)
    static func hasOrientationPart(_ s: String) -> Bool {
        isOrientation(s) || (s.contains(separator) && s.components(separatedBy: separator).contains(where: isOrientation))
    }
    /// Szenen-Ordner, den CamSort anlegt („Szene 03“, „Szene 03 · 14.20 · Sony“)
    static func isSceneFolder(_ s: String) -> Bool {
        let first = s.components(separatedBy: separator).first ?? s
        let pat = "^" + NSRegularExpression.escapedPattern(for: fold(sceneWord)) + #" \d{2,3}$"#
        return fold(first).range(of: pat, options: .regularExpression) != nil
    }

    // MARK: Bildrate (FPS)
    /// Schablone für FPS-Ordner, {n} = Bildrate (z. B. „{n} fps“ → „50 fps“) – einstellbar
    static var fpsTemplate = "{n} fps"
    /// Ordner für Clips ohne feste Bildrate (nominalFrameRate 0/unplausibel, z. B. manche Bildschirmaufnahmen)
    static var fpsVariable = "Variable fps"
    /// Standardklassen: (Klasse, Werte, die dazu gehören). Enge Toleranz → 23,976/24 nie 25, 48 nie 50, 119,88/120 nie 100.
    static let fpsClasses: [(n: Int, values: [Double])] = [
        (24, [23.976, 24]), (25, [25]), (30, [29.97, 30]), (48, [47.952, 48]), (50, [50]), (60, [59.94, 60]),
        (100, [100]), (120, [119.88, 120]), (200, [200]), (240, [239.76, 240]),
    ]
    /// Bildrate → Klasse. nil = keine feste/plausible Bildrate (variabel).
    static func fpsClass(_ v: Double) -> Int? {
        guard v.isFinite, v >= 1, v <= 1000 else { return nil }
        for c in fpsClasses where c.values.contains(where: { abs($0 - v) <= 0.3 }) { return c.n }
        return Int(v.rounded())
    }
    /// Ordnername für eine Klasse (nil = variabel)
    static func fpsName(_ n: Int?) -> String {
        guard let n else { return fpsVariable }
        let t = fpsTemplate.contains("{n}") ? fpsTemplate : "{n} fps"
        return t.replacingOccurrences(of: "{n}", with: String(n)).replacingOccurrences(of: "/", with: "-")
    }
    /// Ist dieser Name (oder ein Teil davon bei „Ein Ordner“) ein FPS-Ordner? Schablone, Standard „{n} fps“, „Variable fps“ – Groß/Klein egal.
    static func isFpsFolder(_ s: String) -> Bool {
        let f = fold(s)
        if f == fold(fpsVariable) || f == "variable fps" { return true }
        for t in Set([fpsTemplate, "{n} fps"]) where t.contains("{n}") {
            let parts = t.components(separatedBy: "{n}")
            let pat = "^" + parts.map { NSRegularExpression.escapedPattern(for: fold($0)) }.joined(separator: #"\d{1,4}"#) + "$"
            if f.range(of: pat, options: .regularExpression) != nil { return true }
        }
        return false
    }
    /// Enthält ein Ordnername (auch zusammengesetzt mit Trennzeichen) einen FPS-Teil?
    static func hasFpsPart(_ s: String) -> Bool {
        isFpsFolder(s) || s.components(separatedBy: separator).contains(where: isFpsFolder)
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
        useVideosFolder = d.object(forKey: "useVideosFolder") as? Bool ?? true
        fpsTemplate = s("fnFps", "{n} fps")
        if !fpsTemplate.contains("{n}") { fpsTemplate = "{n} fps" }
    }
}
