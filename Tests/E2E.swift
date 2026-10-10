#if E2E
import SwiftUI
import AppKit

/// End-to-End-Test: sortiert einen echten Testordner, prüft das Ergebnis und rendert alle Ansichten als Bilder.
@main
struct E2E {
    static var report: [String] = []
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        report.append((ok ? "✅ " : "❌ ") + what)
        if !ok { failures += 1 }
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.png") { NSApplication.shared.applicationIconImage = icon }
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Frische Einstellungen
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        for k in ["cameraRules2", "extensions2", "confirmCameras", "includeSubfolders", "sortByLens", "droneBySpeed"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        let store = LearnedStore()
        store.confirmCameras = false
        store.includeSubfolders = true
        store.sortByLens = false
        store.droneBySpeed = true
        let sorter = Sorter(store: store)
        let gyro = GyroRunner(store: store, sorter: sorter)
        let tagger = TagRunner()
        let theme = ThemeSettings()

        func render<V: View>(_ v: V, _ name: String, w: CGFloat = 580, h: CGFloat = 780, sheet: Bool = false) {
            let content = Group {
                if sheet {
                    AnyView(v.background(Color(nsColor: .windowBackgroundColor)))
                } else {
                    AnyView(ZStack {
                        LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
                        VStack(spacing: 0) { Header().padding(.top, 34); v.padding(.horizontal, 32).padding(.bottom, 28) }
                    }.foregroundStyle(.white))
                }
            }
            .environmentObject(sorter).environmentObject(store).environmentObject(theme)
            .environmentObject(gyro).environmentObject(tagger)
            .frame(width: w, height: h)
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: content)
            r.scale = 2
            if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: outDir.appendingPathComponent(name + ".png"))
            }
        }

        // 1) Startbildschirm
        sorter.addFolders([root])
        render(IdleView(), "01-start")

        // 2) Sortieren – Rückfragen automatisch beantworten
        sorter.start()
        var sawSorting = false
        var askedExt: [String] = []
        let t0 = Date()
        while sorter.phase != .done && sorter.phase != .cancelled && Date().timeIntervalSince(t0) < 120 {
            if let r = sorter.pendingExtensions {
                askedExt = r.extensions.map(\.ext)
                render(ExtensionSheet(request: r), "05-rueckfrage-dateityp", w: 460, h: 380, sheet: true)
                sorter.answerExtensions([:], remember: false)
            }
            if let r = sorter.pendingCamera {
                render(CameraSheet(request: r), "06-rueckfrage-kamera", w: 440, h: 360, sheet: true)
                sorter.answerCamera(r.suggestion.isEmpty ? nil : r.suggestion, remember: false)
            }
            if let r = sorter.pendingDuplicate {
                render(DuplicateSheet(request: r), "07-rueckfrage-duplikat", w: 380, h: 320, sheet: true)
                sorter.answerDuplicate(.skip, forAll: true)
            }
            if sorter.phase == .sorting && !sawSorting && sorter.processed > 0 {
                sawSorting = true
                render(SortingView(), "02-sortieren")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        check(sorter.phase == .done, "Sortierung läuft durch (Ende: \(sorter.phase))")
        check(askedExt.contains("abc"), "Unbekannter Dateityp .abc wird abgefragt (gefragt: \(askedExt))")
        render(DoneView(), "03-fertig")

        // 3) Ergebnis prüfen
        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path) }
        check(exists("Videos/Sony Alpha 1/Quer/C0001.MP4"), "Sony A1 (Modell in MP4 eingebettet) → Videos/Sony Alpha 1/Quer")
        check(exists("Videos/Sony ZV-E1/Hochkant/C0002.MP4"), "Sony ZV-E1 (Begleit-XML), Hochkant-Auflösung → Hochkant")
        check(exists("Videos/Sony Alpha 1/Hochkant/C0003.MP4"), "Quer gespeichert + 90°-Rotations-Flag → Hochkant")
        check(exists("XML/C0002M01.XML"), "Sony-XML → XML/")
        let djiFahrt = exists("Videos/DJI/Fahrt/Quer/DJI_20250426155228_0038_D_M3P.MP4")
            || ((try? FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("Videos").path)) ?? [])
                .contains { $0.hasSuffix("Fahrt/Quer/DJI_20250426155228_0038_D_M3P.MP4") }
        check(djiFahrt, "DJI mit GPS-SRT (36 km/h) → …/Fahrt/Quer")
        let noGPS = ((try? FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("Videos").path)) ?? [])
            .contains { $0.hasSuffix("Ohne GPS/Quer/DJI_0162.MP4") }
        check(noGPS, "DJI Mini 3 Pro (echte SRT ohne GPS) → …/Ohne GPS/Quer")
        check(exists("SRT/DJI_0162.SRT") && exists("SRT/DJI_20250426155228_0038_D_M3P.SRT"), "SRT-Dateien → SRT/")
        check(exists("LRF/DJI_20250426155228_0038_D_M3P.LRF"), "LRF → LRF/")
        check(exists("Fotos/IMG_0002.JPG"), "Foto → Fotos/")
        check(exists("Musik/Musik_Intro.mp3"), "MP3 → Musik/")
        check(exists("ZIP/Projekt.zip"), "ZIP → ZIP/")
        check(exists("Notiz.abc"), "Ignorierter Typ bleibt liegen")
        check(exists("Unterordner/Videos/Canon/Quer/MVI_1234.MP4"), "Unterordner: Canon-Clip im eigenen Ordner sortiert")
        check(exists("Videos/iPhone/Quer/IMG_0001.MOV"), "IMG_xxxx.MOV → iPhone")
        let speedHint = sorter.hints.first { $0.contains("km/h") } ?? "–"
        report.append("ℹ️ Geschwindigkeits-Hinweis: \(speedHint)")
        report.append("ℹ️ Probleme: \(sorter.problems.isEmpty ? "keine" : sorter.problems.joined(separator: " | "))")

        // 4) Zweiter Lauf = Aktualisieren: darf nichts kaputt machen
        let before = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.sorted() ?? []
        sorter.start()
        while sorter.phase != .done && sorter.phase != .cancelled {
            if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
            if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
            if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let after = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.sorted() ?? []
        check(before == after, "Zweiter Lauf (Aktualisieren) verändert nichts (\(sorter.movedTotal) verschoben)")

        // 5) Gyroflow: Sony-Clips finden (Hochkant zuerst), dann stabilisierte Datei trennen
        let clips = gyro.collectSonyClips(in: [root])
        check(clips.hochkant.map(\.lastPathComponent).sorted() == ["C0002.MP4", "C0003.MP4"] && clips.quer.map(\.lastPathComponent) == ["C0001.MP4"],
              "Gyroflow-Auswahl: nur Sony, Hochkant=\(clips.hochkant.map(\.lastPathComponent)) Quer=\(clips.quer.map(\.lastPathComponent))")
        gyro.start(folders: [root])  // ohne Preset → verständliche Meldung erwartet
        if case .failed(let m) = gyro.state { check(m.contains("Preset") || m.contains("nicht gefunden"), "Ohne Gyroflow/Preset: klare Meldung statt Absturz („\(m.prefix(60))…“)") } else { check(false, "Ohne Gyroflow/Preset: Meldung erwartet") }
        render(GyroView(), "08-gyroflow-hinweis")
        gyro.queue = clips.hochkant + clips.quer; gyro.index = 1; gyro.currentGroup = "Hochkant"
        gyro.currentFile = "C0003.MP4"; gyro.filePercent = 0.42; gyro.state = .running
        render(GyroView(), "09-gyroflow-laeuft")
        gyro.close()

        let q = root.appendingPathComponent("Videos/Sony Alpha 1/Quer")
        try? FileManager.default.copyItem(at: q.appendingPathComponent("C0001.MP4"), to: q.appendingPathComponent("C0001_gyro.mp4"))
        try? "{}".write(to: q.appendingPathComponent("C0001.gyroflow"), atomically: true, encoding: .utf8)
        sorter.folders = [root]
        sorter.startGyro()
        while sorter.phase != .done && sorter.phase != .cancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        check(FileManager.default.fileExists(atPath: q.appendingPathComponent("Stabilisiert/C0001_gyro.mp4").path), "Gyroflow-Datei _gyro → Stabilisiert/")
        check(FileManager.default.fileExists(atPath: q.appendingPathComponent("Original/C0001.MP4").path), "Original → Original/")
        check(FileManager.default.fileExists(atPath: q.appendingPathComponent("Gyroflow-Projekte/C0001.gyroflow").path), ".gyroflow → Gyroflow-Projekte/")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("Videos/Sony ZV-E1/Hochkant/C0002.MP4").path),
              "Ordner ohne Gyroflow-Clips bleiben unverändert")
        render(DoneView(), "04-fertig-gyroflow-getrennt")

        // 6) Verschlagworten (Bilderkennung + Schriftzüge) mit echtem Ablauf
        tagger.start(folders: [root])
        var shotTag = false
        while tagger.state == .running {
            if !shotTag && tagger.index > 0 { shotTag = true; render(TagView(), "10-verschlagworten-laeuft") }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        render(TagView(), "11-verschlagworten-fertig")
        func tags(_ p: String) -> [String] {
            (try? root.appendingPathComponent(p).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        }
        let porscheTags = tags("Videos/iPhone/Quer/IMG_0001.MOV")
        check(porscheTags.contains("Porsche"), "Schriftzug „PORSCHE“ im Bild → Finder-Tag Porsche (Tags: \(porscheTags))")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Videos/Unbekannt/Quer/Auto_Foto_Clip.mp4").path) {
            let t = tags("Videos/Unbekannt/Quer/Auto_Foto_Clip.mp4")
            check(t.contains("Auto"), "Echtes Autofoto → Tag Auto (Tags: \(t))")
        } else { report.append("ℹ️ Autofoto nicht verfügbar (Download) – Bilderkennung von Fahrzeugen nicht geprüft") }
        report.append("ℹ️ Vergebene Tags gesamt: \(tagger.tagCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
        report.append("ℹ️ Tag-Fehler: \(tagger.errors.isEmpty ? "keine" : tagger.errors.joined(separator: " | "))")
        let sizeOK: Bool = {
            let u = root.appendingPathComponent("Videos/iPhone/Quer/IMG_0001.MOV")
            let s = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return s > 0
        }()
        check(sizeOK, "Video nach dem Taggen unverändert lesbar")

        // 6b) Speicherkarten-Import mit Tagesauswahl
        let card = root.deletingLastPathComponent().appendingPathComponent("FakeKarte")
        let clipDir = card.appendingPathComponent("PRIVATE/M4ROOT/CLIP")
        let thumbs = card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL")
        try? FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let src = root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4")
        let fmx = FileManager.default
        try? fmx.copyItem(at: src, to: clipDir.appendingPathComponent("C0101.MP4"))
        try? fmx.copyItem(at: src, to: clipDir.appendingPathComponent("C0050.MP4"))
        try? "<NonRealTimeMeta><Device manufacturer=\"Sony\" modelName=\"ILCE-1\"/></NonRealTimeMeta>".write(to: clipDir.appendingPathComponent("C0101M01.XML"), atomically: true, encoding: .utf8)
        try? Data([0xFF, 0xD8]).write(to: thumbs.appendingPathComponent("C0101T01.JPG"))
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        try? fmx.setAttributes([.modificationDate: old], ofItemAtPath: clipDir.appendingPathComponent("C0050.MP4").path)
        let imp = ImportRunner(sorter: sorter)
        imp.source = card
        let days = ImportRunner.collectDays(card)
        imp.days = days
        check(days.count == 2, "Karte: 2 Aufnahmetage erkannt (\(days.map { "\($0.label): \($0.files.count)" }))")
        check(!days.flatMap(\.files).contains { $0.lastPathComponent.hasPrefix("C0101T01") }, "Sony-Vorschaubilder (THMBNL) werden nicht importiert")
        imp.selected = [days.first!.key]
        imp.state = .choosing
        render(ImportChooser().environmentObject(imp), "15-import-tage")
        let dest = root.deletingLastPathComponent().appendingPathComponent("ImportZiel")
        try? fmx.createDirectory(at: dest, withIntermediateDirectories: true)
        imp.destination = dest
        imp.startCopy()
        while imp.state == .copying { try? await Task.sleep(nanoseconds: 50_000_000) }
        while sorter.phase != .done && sorter.phase != .cancelled {
            if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
            if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        check(fmx.fileExists(atPath: dest.appendingPathComponent("Videos/Sony Alpha 1/Quer/C0101.MP4").path), "Import: neuer Tag kopiert, geprüft und einsortiert")
        check(!fmx.fileExists(atPath: dest.appendingPathComponent("C0050.MP4").path) &&
              ((try? fmx.subpathsOfDirectory(atPath: dest.path)) ?? []).allSatisfy { !$0.hasSuffix("C0050.MP4") }, "Import: alter Tag NICHT kopiert")
        check(fmx.fileExists(atPath: clipDir.appendingPathComponent("C0101.MP4").path), "Karte bleibt unverändert")
        report.append("ℹ️ Import-Fehler: \(imp.errors.isEmpty ? "keine" : imp.errors.joined(separator: " | "))")

        // 7) Weitere Ansichten
        render(SettingsView(), "12-einstellungen", w: 480, h: 620, sheet: true)
        store.droneBySpeed = true
        render(GuideView(), "13-anleitung", w: 500, h: 600, sheet: true)
        render(ThemePicker(), "14-farben", w: 250, h: 330, sheet: true)

        let text = "# CamSort Cloud-Test\n\n" + report.map { "- " + $0 }.joined(separator: "\n") + "\n\nFehlgeschlagen: \(failures)\n"
        try? text.write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print(text)
        exit(0)
    }
}
#endif
