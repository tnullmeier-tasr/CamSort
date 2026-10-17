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
    static var outputNames: Set<String> { [videos, photos, side, extras, "Videos", "Fotos", "Begleitdateien", "Extras"] }

    static func load(_ d: UserDefaults = .standard) {
        func s(_ k: String, _ def: String) -> String { let v = d.string(forKey: k)?.trimmingCharacters(in: .whitespaces) ?? ""; return v.isEmpty ? def : v.replacingOccurrences(of: "/", with: "-") }
        videos = s("fnVideos", "Videos"); photos = s("fnPhotos", "Fotos"); side = s("fnSide", "Begleitdateien"); extras = s("fnExtras", "Extras")
        separator = d.string(forKey: "fnSeparator") ?? " · "
        showCamera = d.object(forKey: "fnShowCamera") as? Bool ?? true
        showOrientation = d.object(forKey: "fnShowOrientation") as? Bool ?? true
        sceneWord = s("fnSceneWord", "Szene")
        sceneShowTime = d.object(forKey: "fnSceneTime") as? Bool ?? true
        sceneShowCams = d.object(forKey: "fnSceneCams") as? Bool ?? true
    }
}
