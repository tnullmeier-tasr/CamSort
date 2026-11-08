#if E2E
import SwiftUI
import AVFoundation
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
        store.compactLayout = false
        store.ownCameraFolders = false
        store.dateMode = "off"; store.renameMode = "off"   // Rückfragen nur im eigenen Test
        let sorter = Sorter(store: store)
        let gyro = GyroRunner(store: store, sorter: sorter)
        let tagger = TagRunner()
        let theme = ThemeSettings()
        let timelineM = TimelineModel()
        let selM = SelectsRunner()

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
            .environmentObject(gyro).environmentObject(tagger).environmentObject(timelineM).environmentObject(ClipBrowser()).environmentObject(selM)
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

        // 6c) Zeitleiste: zwei Clips mit überlappender Aufnahmezeit → „parallel“
        let tlClips = await TimelineModel.collect([root])
        let tlGroups = TimelineModel.group(tlClips)
        check(tlClips.count >= 5, "Zeitleiste liest Aufnahmezeiten aus allen Unterordnern (\(tlClips.count) Clips)")
        let base = Date()
        let fake = [
            TimelineModel.Clip(url: URL(fileURLWithPath: "/a/C0001.MP4"), camera: "Sony Alpha 1", start: base, end: base.addingTimeInterval(60), fromMetadata: true),
            TimelineModel.Clip(url: URL(fileURLWithPath: "/b/C0002.MP4"), camera: "Sony ZV-E1", start: base.addingTimeInterval(20), end: base.addingTimeInterval(90), fromMetadata: true),
            TimelineModel.Clip(url: URL(fileURLWithPath: "/a/C0003.MP4"), camera: "Sony Alpha 1", start: base.addingTimeInterval(300), end: base.addingTimeInterval(320), fromMetadata: true),
        ]
        let fg = TimelineModel.group(fake)
        check(fg.count == 2 && fg[0].isParallel && !fg[1].isParallel, "Überlappende Clips zweier Kameras → als „parallel“ erkannt")
        timelineM.groups = fg + tlGroups; timelineM.count = 3 + tlClips.count
        render(TimelineSheet(), "16-zeitleiste", w: 620, h: 680, sheet: true)
        if let sm = TimelineModel.makeSmartFolder(in: root) { check(FileManager.default.fileExists(atPath: sm.path), "Finder-Ansicht „Alle Clips nach Zeit“ angelegt") }

        // 6d) Kompakte Struktur mit Kunden- und Dreh-Ordnern
        do {
            let fmx = FileManager.default
            let kunde = root.deletingLastPathComponent().appendingPathComponent("Kunde Müller")
            let d1 = kunde.appendingPathComponent("Dreh 1"), d2 = kunde.appendingPathComponent("Dreh 2")
            let card = d2.appendingPathComponent("Karte A/PRIVATE/M4ROOT/CLIP")
            for d in [d1, d2, card] { try? fmx.createDirectory(at: d, withIntermediateDirectories: true) }
            let a1q = root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4")
            let zvh = root.appendingPathComponent("Videos/Sony ZV-E1/Hochkant/C0002.MP4")
            try? fmx.copyItem(at: a1q, to: d1.appendingPathComponent("C0101.MP4"))           // Dreh 1: nur A1, nur quer
            try? fmx.copyItem(at: a1q, to: d1.appendingPathComponent("C0102.MP4"))
            try? fmx.copyItem(at: a1q, to: card.appendingPathComponent("C0201.MP4"))         // Dreh 2: A1 quer (auf Karte) …
            try? fmx.copyItem(at: zvh, to: d2.appendingPathComponent("C0202.MP4"))           // … + ZV-E1 hochkant
            try? fmx.copyItem(at: root.appendingPathComponent("XML/C0002M01.XML"), to: d2.appendingPathComponent("C0202M01.XML"))
            store.compactLayout = true
            store.groupByScene = false
            store.droneBySpeed = false
            sorter.reset(); sorter.addFolders([kunde]); sorter.start()
            while sorter.phase != .done && sorter.phase != .cancelled {
                if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
                if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            func ex(_ p: String) -> Bool { fmx.fileExists(atPath: kunde.appendingPathComponent(p).path) }
            check(ex("Dreh 1/Videos/Sony Alpha 1 · Quer/C0101.MP4") && ex("Dreh 1/Videos/Sony Alpha 1 · Quer/C0102.MP4"), "Kompakt: eine Ebene, Name mit Kamera und Ausrichtung → Dreh 1/Videos/Sony Alpha 1 · Quer")
            check(ex("Dreh 2/Videos/Sony Alpha 1 · Quer/C0201.MP4"), "Kompakt: Clip von der Karte zählt zum Dreh 2 → Videos/Sony Alpha 1 · Quer")
            check(ex("Dreh 2/Videos/Sony ZV-E1 · Hochkant/C0202.MP4"), "Kompakt: zweite Kamera → Videos/Sony ZV-E1 · Hochkant")
            check(ex("Dreh 2/Begleitdateien/C0202M01.XML"), "Kompakt: XML → Begleitdateien")
            check(!ex("Videos"), "Kunden-Ordner selbst bleibt unangetastet (kein Videos-Ordner auf Kundenebene)")
            // später kommt in Dreh 1 ein Hochkant-Clip dazu → Dreh 1 wird passend neu geordnet
            try? fmx.copyItem(at: zvh, to: d1.appendingPathComponent("C0103.MP4"))
            try? "<NonRealTimeMeta><Device manufacturer=\"Sony\" modelName=\"ZV-E1\"/></NonRealTimeMeta>".write(to: d1.appendingPathComponent("C0103M01.XML"), atomically: true, encoding: .utf8)
            sorter.reset(); sorter.addFolders([kunde]); sorter.start()
            while sorter.phase != .done && sorter.phase != .cancelled {
                if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
                if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let tree = ((try? fmx.subpathsOfDirectory(atPath: kunde.path)) ?? []).filter { !$0.hasSuffix(".DS_Store") }.sorted()
            check(ex("Dreh 1/Videos/Sony Alpha 1 · Quer/C0101.MP4") && ex("Dreh 1/Videos/Sony ZV-E1 · Hochkant/C0103.MP4"),
                  "Aktualisieren: neuer Clip in Dreh 1 bekommt eigenen Ordner, bestehende bleiben")
            report.append("ℹ️ Kompakt-Struktur: " + tree.joined(separator: " | "))
            store.compactLayout = false
        }

        // 6e) Verlustfrei drehen
        do {
            let fmx = FileManager.default
            let src = root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4")
            let t = root.deletingLastPathComponent().appendingPathComponent("Drehtest.MP4")
            try? fmx.removeItem(at: t); try? fmx.copyItem(at: src, to: t)
            let before = try? Data(contentsOf: t)
            let mBefore = (try? fmx.attributesOfItem(atPath: t.path))?[.modificationDate] as? Date
            var ok = true
            do { try LosslessRotate.rotate(t, clockwise: true) } catch { ok = false; report.append("ℹ️ Drehfehler: \(error)") }
            let after1 = try? Data(contentsOf: t)
            let tr = AVURLAsset(url: t).tracks(withMediaType: .video).first
            let r = tr.map { $0.naturalSize.applying($0.preferredTransform) }
            check(ok && r != nil && abs(r!.height) > abs(r!.width), "Drehen: Quer-Clip ist danach Hochkant")
            check(before?.count == after1?.count, "Drehen: Dateigröße identisch (nichts neu berechnet)")
            var diff = 0
            if let b = before, let a = after1 { for i in 0..<min(b.count, a.count) where b[i] != a[i] { diff += 1 } }
            check(diff > 0 && diff <= 36, "Drehen: nur die Dreh-Angabe geändert (\(diff) Byte von \(before?.count ?? 0))")
            check(after1?.range(of: Data("manufacturer=\"Sony\"".utf8)) != nil, "Drehen: eingebettete Sony-Metadaten erhalten")
            for _ in 0..<3 { try? LosslessRotate.rotate(t, clockwise: true) }
            check(try! Data(contentsOf: t) == before, "Viermal drehen = bitgenau die Originaldatei")
            let mAfter = (try? fmx.attributesOfItem(atPath: t.path))?[.modificationDate] as? Date
            check(mBefore != nil && mAfter != nil && abs(mBefore!.timeIntervalSince(mAfter!)) < 1, "Drehen: Dateidatum bleibt unverändert (\(mBefore?.description ?? "-") / \(mAfter?.description ?? "-"))")
        }

        // 6f) Final-Cut-Mediathek: wird erkannt, bleibt bitgenau unverändert, Hinweis erscheint
        do {
            let fmx = FileManager.default
            let proj = root.deletingLastPathComponent().appendingPathComponent("FCP-Projekt")
            let lib = proj.appendingPathComponent("Kunde.fcpbundle")
            let inner = lib.appendingPathComponent("Event 1")
            try? fmx.createDirectory(at: inner, withIntermediateDirectories: true)
            try? Data((0..<5000).map { UInt8($0 % 251) }).write(to: inner.appendingPathComponent("CurrentVersion.fcpevent"))
            try? "Settings".write(to: lib.appendingPathComponent("Settings.plist"), atomically: true, encoding: .utf8)
            try? fmx.createSymbolicLink(at: inner.appendingPathComponent("Original Media"), withDestinationURL: proj)
            func snapshot(_ u: URL) -> [String: String] {
                var m: [String: String] = [:]
                let en = fmx.enumerator(at: u, includingPropertiesForKeys: nil, options: [])
                while let f = en?.nextObject() as? URL {
                    let rel = String(f.path.dropFirst(u.path.count))
                    if let dest = try? fmx.destinationOfSymbolicLink(atPath: f.path) { m[rel] = "link:" + dest; en?.skipDescendants() }
                    else if let d = try? Data(contentsOf: f) { m[rel] = ImportRunner.sha256(f) ?? "\(d.count)" }
                    else { m[rel] = "dir" }
                }
                return m
            }
            let before = snapshot(lib)
            try? fmx.copyItem(at: root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4"), to: proj.appendingPathComponent("C0301.MP4"))
            store.compactLayout = true
            store.groupByScene = false
            sorter.reset(); sorter.addFolders([proj]); sorter.start()
            while sorter.phase != .done && sorter.phase != .cancelled {
                if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
                if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let movedLib = proj.appendingPathComponent("Extras/FCP/Kunde.fcpbundle")
            let libNow = fmx.fileExists(atPath: movedLib.path) ? movedLib : lib
            check(!sorter.fcpLibraries.isEmpty, "Final-Cut-Mediathek im Ordner erkannt")
            check(sorter.movedVideos > 0, "Clips wurden verschoben → Hinweis „Neu verknüpfen“ erscheint")
            check(snapshot(libNow) == before, "Mediathek-Inhalt bitgenau unverändert (inkl. Verknüpfungen), nur als Ganzes verschoben")
            check(!fmx.fileExists(atPath: libNow.appendingPathComponent("Videos").path), "CamSort sortiert nichts IN die Mediathek hinein")
            render(DoneView(), "17-fertig-finalcut-hinweis")
            store.compactLayout = false
        }

        // 6g) Szenen: Kamera A Einblendungen, dann Wechsel auf Kamera B, später neue Szene
        do {
            let fmx = FileManager.default
            let dreh = root.deletingLastPathComponent().appendingPathComponent("Szenen-Dreh")
            try? fmx.createDirectory(at: dreh, withIntermediateDirectories: true)
            let a1 = root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4")
            let zv = root.appendingPathComponent("Videos/Sony ZV-E1/Hochkant/C0002.MP4")
            let t0 = Date(timeIntervalSince1970: 1_760_000_000)
            func put(_ src: URL, _ name: String, _ mins: Double, xml: String? = nil) {
                let u = dreh.appendingPathComponent(name)
                try? fmx.copyItem(at: src, to: u)
                if let m = xml { try? "<NonRealTimeMeta><Device manufacturer=\"Sony\" modelName=\"\(m)\"/></NonRealTimeMeta>".write(to: dreh.appendingPathComponent(name.replacingOccurrences(of: ".MP4", with: "M01.XML")), atomically: true, encoding: .utf8) }
                try? fmx.setAttributes([.modificationDate: t0.addingTimeInterval(mins * 60)], ofItemAtPath: u.path)
            }
            put(a1, "C0401.MP4", 0)                     // A: Einblendung 1
            put(a1, "C0402.MP4", 1)                     // A: Einblendung 2
            put(zv, "C0501.MP4", 3, xml: "ZV-E1")       // Wechsel auf B
            put(a1, "C0403.MP4", 40)                    // 40 Min. später: neue Szene
            store.compactLayout = true; store.groupByScene = true; store.sceneGapMinutes = 5
            sorter.reset(); sorter.addFolders([dreh]); sorter.start()
            while sorter.phase != .done && sorter.phase != .cancelled {
                if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
                if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let vids = (try? fmx.contentsOfDirectory(atPath: dreh.appendingPathComponent("Videos").path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            report.append("ℹ️ Szenen-Ordner: " + vids.joined(separator: " | "))
            let s1 = vids.first { $0.hasPrefix("Szene 01") } ?? "", s2 = vids.first { $0.hasPrefix("Szene 02") } ?? ""
            func inS(_ s: String, _ f: String) -> Bool { fmx.fileExists(atPath: dreh.appendingPathComponent("Videos/\(s)/\(f)").path) }
            check(vids.count == 2, "Szenen: 2 Szenen erkannt (Pause > 5 Min. trennt)")
            check(inS(s1, "C0401.MP4") && inS(s1, "C0402.MP4") && inS(s1, "C0501.MP4"), "Szene 01: Einblendungen Kamera A + Wechsel auf Kamera B zusammen")
            check(s1.contains("Sony Alpha 1 + Sony ZV-E1"), "Szenen-Name nennt beide Kameras in Reihenfolge („\(s1)“)")
            check(inS(s2, "C0403.MP4"), "Szene 02: späterer Clip")
            let tg = (try? dreh.appendingPathComponent("Videos/\(s1)/C0501.MP4").resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            check(tg.contains("Sony ZV-E1") && tg.contains("Hochkant"), "Kamera + Ausrichtung als Finder-Tag am Clip (\(tg))")
            let all = ((try? fmx.subpathsOfDirectory(atPath: dreh.path)) ?? []).filter { $0.hasSuffix(".MP4") }
            check(all.count == 4, "Keine Duplikate: 4 Clips rein, 4 Clips raus")
            store.groupByScene = false; store.compactLayout = false
        }

        // 6h) Gyroflow-Preset: wird in CamSorts eigenen Ordner übernommen, Original darf danach weg
        do {
            let fmx = FileManager.default
            let src = root.deletingLastPathComponent().appendingPathComponent("Sony.gyroflow")
            try? #"{"version":2,"stabilization":{"fov":1.0}}"#.write(to: src, atomically: true, encoding: .utf8)
            let err = store.importPreset(from: src)
            check(err == nil && store.gyroPresetPath.hasPrefix(LearnedStore.presetDir.path), "Preset wird in CamSorts eigenen Ordner übernommen")
            try? fmx.removeItem(at: src)
            check(fmx.isReadableFile(atPath: store.gyroPresetPath), "Preset bleibt nutzbar, auch wenn das Original gelöscht wurde")
            gyro.start(folders: [root])
            if case .failed(let m) = gyro.state { check(!m.contains("kein Gyroflow-Preset") && !m.contains("nicht lesbar"), "Mit Preset kommt keine Preset-Meldung mehr („\(m.prefix(50))…“)") }
            else { check(true, "Mit Preset kommt keine Preset-Meldung mehr") }
            gyro.close()
            check(store.importPreset(from: URL(fileURLWithPath: "/tmp/x.txt")) != nil, "Falsche Datei wird abgelehnt")
        }

        // 6i) Ordner-Baukasten: Szene › Länge als Unterordner (Einblendungen / Hauptspur)
        do {
            let fmx = FileManager.default
            let dreh = root.deletingLastPathComponent().appendingPathComponent("Baukasten-Dreh")
            try? fmx.createDirectory(at: dreh, withIntermediateDirectories: true)
            let shortSrc = root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4")   // 3 s
            let longSrc = root.appendingPathComponent("Videos/iPhone/Quer/IMG_0001.MOV")                // 7 s
            let t0 = Date(timeIntervalSince1970: 1_760_100_000)
            for (src, name, m) in [(shortSrc, "C0601.MP4", 0.0), (longSrc, "IMG_0601.MOV", 1.0)] {
                let u = dreh.appendingPathComponent(name); try? fmx.copyItem(at: src, to: u)
                try? fmx.setAttributes([.modificationDate: t0.addingTimeInterval(m * 60)], ofItemAtPath: u.path)
            }
            store.compactLayout = true
            store.levels = ["scene", "length"]; store.nestLevels = true
            store.lengthThreshold = 5; store.lengthShort = "Einblendungen"; store.lengthLong = "Hauptspur"
            sorter.reset(); sorter.addFolders([dreh]); sorter.start()
            while sorter.phase != .done && sorter.phase != .cancelled {
                if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
                if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let tree = ((try? fmx.subpathsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            report.append("ℹ️ Baukasten (Szene › Länge): " + tree.joined(separator: " | "))
            check(tree.contains { $0.hasSuffix("/Einblendungen/C0601.MP4") && $0.hasPrefix("Videos/Szene 01") }, "Baukasten: kurzer Clip → Szene 01/Einblendungen")
            check(tree.contains { $0.hasSuffix("/Hauptspur/IMG_0601.MOV") && $0.hasPrefix("Videos/Szene 01") }, "Baukasten: langer Clip → Szene 01/Hauptspur")
            // umschalten auf „ein Ordner“ + Kamera › Länge → bestehender Dreh wird neu geordnet
            store.levels = ["camera", "length"]; store.nestLevels = false
            sorter.reset(); sorter.addFolders([dreh]); sorter.start()
            while sorter.phase != .done && sorter.phase != .cancelled {
                if let r = sorter.pendingCamera { sorter.answerCamera(r.suggestion, remember: false) }
                if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let tree2 = ((try? fmx.subpathsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            report.append("ℹ️ Baukasten (Kamera + Länge): " + tree2.joined(separator: " | "))
            check(tree2.contains("Videos/Sony Alpha 1 · Einblendungen/C0601.MP4") && tree2.contains("Videos/iPhone · Hauptspur/IMG_0601.MOV"),
                  "Baukasten umgestellt → Dreh neu geordnet, ein Ordnername")
            check(tree2.filter { $0.hasSuffix(".MP4") || $0.hasSuffix(".MOV") }.count == 2, "Baukasten: keine Duplikate")
            check(!tree2.contains { $0.hasPrefix("Videos/Szene") }, "Alte leere Szenen-Ordner aufgeräumt")
            store.levels = ["scene"]; store.nestLevels = false; store.compactLayout = false
        }

        // 6j) Beste Momente: Analyse + FCPXML
        do {
            let fmx = FileManager.default
            selM.segmentLength = 1; selM.keepPercent = 50
            selM.start(folders: [root], suffixes: store.gyroSuffixList)
            let t0 = Date()
            while selM.state == .running && Date().timeIntervalSince(t0) < 300 { try? await Task.sleep(nanoseconds: 100_000_000) }
            render(SelectsView(), "18-beste-momente")
            check(selM.state == .finished, "Beste Momente: Analyse läuft durch (\(selM.total) Clips, \(Int(selM.analyzedSeconds)) s Material in \(String(format: "%.1f", selM.eta.elapsed)) s)")
            check(!selM.kept.isEmpty && !selM.outputs.isEmpty, "Beste Momente: \(selM.kept.count) Abschnitte behalten, \(selM.outputs.count) Final-Cut-Datei(en)")
            if let o = selM.outputs.first, let data = try? Data(contentsOf: o) {
                final class P: NSObject, XMLParserDelegate {
                    var srcs: [String] = []; var clips = 0; var ok = true
                    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                        if e == "media-rep", let s = a["src"] { srcs.append(s) }
                        if e == "asset-clip" { clips += 1; for k in ["offset", "start", "duration"] where !(a[k] ?? "").hasSuffix("s") { ok = false } }
                    }
                }
                let p = P(); let xp = XMLParser(data: data); xp.delegate = p
                check(xp.parse(), "FCPXML ist gültiges XML (\(o.lastPathComponent))")
                check(p.clips > 0 && p.ok, "FCPXML: \(p.clips) Abschnitte mit Zeitangaben im Final-Cut-Format")
                check(!p.srcs.isEmpty && p.srcs.allSatisfy { URL(string: $0).map { fmx.fileExists(atPath: $0.path) } ?? false }, "FCPXML verweist auf die echten Clips am Originalort (nichts kopiert)")
                try? fmx.copyItem(at: o, to: outDir.appendingPathComponent("beispiel-beste-momente.fcpxml"))
            }
            selM.close()
        }

        // 6k) Modus „Meine Kameraordner“: eigene Ordner = Kamera, darin nur Hochkant/Quer/Quadratisch
        do {
            let fmx = FileManager.default
            check(FolderNames.orientation(width: 3840, height: 3840) == "Quadratisch" && FolderNames.orientation(width: 1000, height: 1090) == "Quadratisch",
                  "1:1 (Osmo Action 6, 3840×3840) und fast quadratisch → Quadratisch")
            check(FolderNames.orientation(width: 3840, height: 2880) == "Quer" && FolderNames.orientation(width: 2880, height: 3840) == "Hochkant"
                  && FolderNames.orientation(width: 1000, height: 1120) == "Hochkant", "4:3 = Quer, 3:4 = Hochkant, Grenze 1,1")
            check(store.hasDateInName("2026-10-12 Pitbike") && store.hasDateInName("Pitbike 12.10.2026") && store.hasDateInName("20261012_Pitbike")
                  && store.hasDateInName("Pitbike 12.10.") && !store.hasDateInName("Pitbike") && !store.hasDateInName("A1"), "Datum im Ordnernamen wird erkannt")
            let dreh = root.deletingLastPathComponent().appendingPathComponent("Pitbike Ä 🏍")
            try? fmx.removeItem(at: dreh)
            let quer = root.appendingPathComponent("Videos/Sony Alpha 1/Quer/Original/C0001.MP4")
            let hoch = root.appendingPathComponent("Videos/Sony ZV-E1/Hochkant/C0002.MP4")
            let clip = dreh.appendingPathComponent("A1/PRIVATE/M4ROOT/CLIP")
            let dji = dreh.appendingPathComponent("Avata/DCIM/100MEDIA")
            try? fmx.createDirectory(at: clip, withIntermediateDirectories: true)
            try? fmx.createDirectory(at: dji, withIntermediateDirectories: true)
            try? fmx.createDirectory(at: dreh.appendingPathComponent("Avata/hochkant"), withIntermediateDirectories: true)   // klein geschrieben vorhanden
            try? fmx.copyItem(at: quer, to: clip.appendingPathComponent("C0101.MP4"))
            try? "<NonRealTimeMeta><Device manufacturer=\"Sony\" modelName=\"ILCE-1\"/></NonRealTimeMeta>".write(to: clip.appendingPathComponent("C0101M01.XML"), atomically: true, encoding: .utf8)
            try? fmx.copyItem(at: hoch, to: dji.appendingPathComponent("DJI_0001.MP4"))
            let sq = root.deletingLastPathComponent().appendingPathComponent("CamSort-Extra/Q0001.MP4")
            let hasSquare = fmx.fileExists(atPath: sq.path)
            if hasSquare { try? fmx.copyItem(at: sq, to: dji.appendingPathComponent("Q0001.MP4")) }
            try? fmx.copyItem(at: quer, to: dreh.appendingPathComponent("lose.MP4"))
            try? Data().write(to: dreh.appendingPathComponent("A1/leer.MP4"))   // 0 Byte → nicht verschieben

            store.ownCameraFolders = true; store.includeSubfolders = true; store.dateMode = "off"; store.renameMode = "off"
            var askedCamera = false
            func runOwn(answer: String? = nil, rename: String? = nil) async {
                sorter.reset(); sorter.addFolders([dreh]); sorter.start()
                let t0 = Date()
                while sorter.phase != .done && sorter.phase != .cancelled && Date().timeIntervalSince(t0) < 120 {
                    if let r = sorter.pendingCamera { askedCamera = true; sorter.answerCamera(r.suggestion, remember: false) }
                    if sorter.pendingExtensions != nil { sorter.answerExtensions([:], remember: false) }
                    if sorter.pendingDuplicate != nil { sorter.answerDuplicate(.skip, forAll: true) }
                    if let q = sorter.pendingQuestion {
                        let id = q.options.contains { $0.id == answer } ? answer : (q.options.contains { $0.id == rename } ? rename : "off")
                        if q.title.contains("Datum sortieren") { render(QuestionSheet(request: q), "19-rueckfrage-datum", w: 440, h: 360, sheet: true) }
                        sorter.answerQuestion(id ?? "off", remember: false)
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            await runOwn()
            func ex(_ p: String) -> Bool { fmx.fileExists(atPath: dreh.appendingPathComponent(p).path) }
            let tree = ((try? fmx.subpathsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.contains(".DS_Store") }.sorted()
            report.append("ℹ️ Meine Kameraordner: " + tree.joined(separator: " | "))
            check(sorter.phase == .done, "Meine Kameraordner: Lauf endet sauber")
            check(!askedCamera, "Meine Kameraordner: keine Kamera-Rückfrage")
            check(ex("A1/Quer/C0101.MP4"), "Kartenstruktur PRIVATE/M4ROOT/CLIP → A1/Quer")
            check(ex("A1/Begleitdateien/C0101M01.XML"), "Sony-XML → A1/Begleitdateien")
            check(GyroRunner.isSony(dreh.appendingPathComponent("A1/Quer/C0101.MP4")), "Gyroflow findet die Sony-XML im neuen Layout")
            let avataKids = ((try? fmx.contentsOfDirectory(atPath: dreh.appendingPathComponent("Avata").path)) ?? []).filter { $0.lowercased() == "hochkant" || $0.lowercased().hasPrefix("hochkant ") }
            check(avataKids.count == 1 && fmx.fileExists(atPath: dreh.appendingPathComponent("Avata/\(avataKids.first ?? "")/DJI_0001.MP4").path),
                  "DCIM/100MEDIA → Avata/Hochkant, vorhandenes „hochkant“ wiederverwendet (\(avataKids))")
            if hasSquare { check(ex("Avata/Quadratisch/Q0001.MP4"), "1:1-Clip → Avata/Quadratisch") }
            check(ex("lose.MP4") && sorter.hints.contains { $0.contains("außerhalb eines Kameraordners") }, "Lose Datei im Dreh-Ordner bleibt liegen und wird gemeldet")
            check(ex("A1/leer.MP4") && sorter.problems.contains { $0.contains("leer.MP4") }, "0-Byte-Datei bleibt liegen und wird gemeldet")
            check(!ex("A1/PRIVATE") && !ex("Avata/DCIM"), "Leere Kartenordner entfernt")
            check(sorter.folderStats.count == 2 && sorter.movedVideos >= 2, "Ergebnis je Kameraordner (\(sorter.folderStats.map { "\($0.name) H\($0.hochkant) Q\($0.quer) □\($0.quadrat)" }))")
            render(DoneView(), "20-fertig-kameraordner")

            // zweiter Lauf: nichts darf sich ändern
            await runOwn()
            let tree2 = ((try? fmx.subpathsOfDirectory(atPath: dreh.path)) ?? []).filter { !$0.contains(".DS_Store") }.sorted()
            check(tree == tree2, "Meine Kameraordner: zweiter Lauf verändert nichts")
            check(sorter.hints.contains { $0.contains("unverändert: A1") || $0.contains("unverändert: Avata") }, "Zweiter Lauf meldet „unverändert“")

            // neuer Kameraordner E1 mit Clips von zwei Tagen → Datumsfrage, Tagesordner unter der Kamera; dann Ordner umbenennen
            let e1 = dreh.appendingPathComponent("E1")
            try? fmx.createDirectory(at: e1, withIntermediateDirectories: true)
            try? fmx.copyItem(at: quer, to: e1.appendingPathComponent("C0201.MP4"))
            try? fmx.copyItem(at: quer, to: e1.appendingPathComponent("C0202.MP4"))
            let d1 = Date(timeIntervalSince1970: 1_791_800_000), d2 = d1.addingTimeInterval(2 * 86400)
            try? fmx.setAttributes([.modificationDate: d1], ofItemAtPath: e1.appendingPathComponent("C0201.MP4").path)
            try? fmx.setAttributes([.modificationDate: d2], ofItemAtPath: e1.appendingPathComponent("C0202.MP4").path)
            store.dateMode = "ask"; store.renameMode = "ask"
            await runOwn(answer: "under", rename: "front-start")
            let e1Kids = ((try? fmx.contentsOfDirectory(atPath: sorter.folders.first?.appendingPathComponent("E1").path ?? "")) ?? []).filter { store.isDayFolder($0) }
            check(e1Kids.count == 2, "Zwei Aufnahmetage → E1/<Tag>/Quer (\(e1Kids))")
            check(sorter.hints.contains { $0.contains("Neu sortiert: E1") && $0.contains("unverändert") }, "Ergebnis: „Neu sortiert: E1 – unverändert: …“")
            let renamed = sorter.folders.first ?? dreh
            check(renamed.lastPathComponent.hasSuffix("Pitbike Ä 🏍") && store.hasDateInName(renamed.lastPathComponent) && fmx.fileExists(atPath: renamed.path),
                  "Dreh-Ordner umbenannt → „\(renamed.lastPathComponent)“, Pfade nachgezogen")
            check(sorter.gyroOffer.allSatisfy { fmx.fileExists(atPath: $0.path) }, "Gyro-Angebot zeigt nach dem Umbenennen auf echte Dateien")
            store.ownCameraFolders = false; store.dateMode = "off"; store.renameMode = "off"
        }

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
