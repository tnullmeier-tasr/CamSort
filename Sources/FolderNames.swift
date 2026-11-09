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
    static var outputNames: Set<String> { [videos, photos, side, extras, "Videos", "Fotos", "Begleitdateien", "Extras", square, "Quadratisch", stabilized, "Stabilisiert"] }

    // MARK: Gyroflow / Stabilisiert
    /// Ordner für stabilisierte Clips – einstellbar (Key fnStabilized). Liegt auf derselben Ebene wie die Ausrichtungs-/Ebenen-Ordner.
    static var stabilized = "Stabilisiert"
    static var stabilizedAliases: Set<String> { ["Stabilisiert", stabilized] }
    static func isStabilizedFolder(_ s: String) -> Bool { let f = fold(s); return stabilizedAliases.contains { fold($0) == f } }
    /// Alte Logik (vor 2026-11): Originale wurden in „Original“ unterhalb der Ausrichtung verschoben – nur noch erkannt
    static let legacyOriginal = "Original"
    static let gyroProjects = "Gyroflow-Projekte"
    /// Stabilisierte Ausgaben mit falscher Ausrichtung (nicht einsortiert): <Eltern>/Stabilisiert/_Prüfen
    static let checkFolder = "_Prüfen"
    /// Ordner, in die CamSorts Gyroflow-Logik ablegt (beim Durchsuchen nach neuen Clips überspringen)
    static func isGyroFolder(_ s: String) -> Bool { isStabilizedFolder(s) || s == legacyOriginal || s == gyroProjects || s == checkFolder }

    /// Ebenen-Ordner, zu dem ein Clip-Ordner gehört (alte Struktur: „…/Quer/Original“ und „…/Quer/Stabilisiert“ → „…/Quer“)
    static func leafDir(_ dir: URL) -> URL {
        let n = dir.lastPathComponent
        return (n == legacyOriginal || isStabilizedFolder(n)) ? dir.deletingLastPathComponent() : dir
    }
    /// Regel: Der Stabilisiert-Ordner liegt im Elternordner des (letzten) Ebenen-Ordners, darunter derselbe Ordnername.
    /// `A1/Hochkant` → `A1/Stabilisiert/Hochkant`, `Videos/Sony A1 · Quer` → `Videos/Stabilisiert/Sony A1 · Quer`,
    /// `Videos/Sony A1/Quer/50 fps` → `Videos/Sony A1/Quer/Stabilisiert/50 fps`.
    static func stabilizedDir(forClipDir dir: URL) -> URL {
        let leaf = leafDir(dir)
        return leaf.deletingLastPathComponent().appendingPathComponent(stabilized).appendingPathComponent(leaf.lastPathComponent)
    }
    /// Gyroflow-Projektdateien stabilisierter Clips: `<Eltern>/Stabilisiert/Gyroflow-Projekte`
    static func stabilizedProjectsDir(forClipDir dir: URL) -> URL {
        leafDir(dir).deletingLastPathComponent().appendingPathComponent(stabilized).appendingPathComponent(gyroProjects)
    }
    /// Liegt der Ordner im neuen Schema `<Eltern>/Stabilisiert/<Ebene>`? Dann der Ebenen-Ordner der Originale, sonst nil.
    static func originalDir(forStabilizedDir dir: URL) -> URL? {
        let parent = dir.deletingLastPathComponent()
        guard isStabilizedFolder(parent.lastPathComponent), !isStabilizedFolder(dir.lastPathComponent), dir.lastPathComponent != gyroProjects, dir.lastPathComponent != checkFolder else { return nil }
        return parent.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent)
    }

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

    // MARK: Framerate (FPS)
    /// Schablone für FPS-Ordner, {n} = Framerate (z. B. „{n} fps“ → „50 fps“) – einstellbar
    static var fpsTemplate = "{n} fps"
    /// Ordner für Clips ohne feste Framerate (nominalFrameRate 0/unplausibel, z. B. manche Bildschirmaufnahmen)
    static var fpsVariable = "Variable fps"
    /// Standardklassen: (Klasse, Werte, die dazu gehören). Enge Toleranz → 23,976/24 nie 25, 48 nie 50, 119,88/120 nie 100.
    static let fpsClasses: [(n: Int, values: [Double])] = [
        (24, [23.976, 24]), (25, [25]), (30, [29.97, 30]), (48, [47.952, 48]), (50, [50]), (60, [59.94, 60]),
        (100, [100]), (120, [119.88, 120]), (200, [200]), (240, [239.76, 240]),
    ]
    /// Framerate → Klasse. nil = keine feste/plausible Framerate (variabel).
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
        stabilized = s("fnStabilized", "Stabilisiert")
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
