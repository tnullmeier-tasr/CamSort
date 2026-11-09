import Foundation
import SwiftUI
import AppKit
import CryptoKit

/// Import von Speicherkarten: Tage auswählen, kopieren, prüfen, dann sortieren. Die Karte wird nie verändert.
@MainActor
final class ImportRunner: ObservableObject {
    struct Day: Identifiable, Hashable {
        var id: String { key }
        let key: String          // yyyy-MM-dd
        let label: String        // „Sa, 10.10.2026“
        var files: [URL]
        var bytes: Int64
    }
    enum State: Equatable { case idle, choosing, copying, paused, finished, failed(String) }

    @Published var state: State = .idle
    @Published var source: URL?
    @Published var destination: URL?
    @Published var days: [Day] = []
    @Published var selected: Set<String> = []
    @Published var scanning = false
    @Published var total = 0
    @Published var index = 0
    @Published var copiedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var currentFile = ""
    @Published var copied = 0
    @Published var skipped = 0
    @Published var errors: [String] = []
    @Published var verify = true
    @Published var tick = Date()          // aktualisiert Zeitanzeige
    var eta = ETA()
    var speedText: String {
        let e = eta.elapsed
        guard e > 2, copiedBytes > 0 else { return "" }
        return ImportRunner.fmt(Int64(Double(copiedBytes) / e)) + "/s"
    }
    var remainingText: String { ETA.text(eta.remaining(done: Double(copiedBytes), total: Double(totalBytes))) }

    var active: Bool { state != .idle }
    var progress: Double { totalBytes == 0 ? 0 : Double(copiedBytes) / Double(totalBytes) }
    private var cancelled = false
    private var paused = false
    private weak var sorter: Sorter?

    init(sorter: Sorter) { self.sorter = sorter }

    // MARK: Karten finden

    static func cards() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeNameKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return vols.filter { v in
            let r = try? v.resourceValues(forKeys: Set(keys))
            let fm = FileManager.default
            let looksLikeCard = fm.fileExists(atPath: v.appendingPathComponent("DCIM").path)
                || fm.fileExists(atPath: v.appendingPathComponent("PRIVATE/M4ROOT").path)
            return (r?.volumeIsRemovable == true || r?.volumeIsEjectable == true || r?.volumeIsInternal == false) && looksLikeCard
        }
    }

    func open() {
        state = .choosing
        errors = []
        if source == nil, let c = Self.cards().first { setSource(c) }
    }

    func setSource(_ url: URL) {
        source = url
        scan()
    }

    func chooseSource() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        p.message = "Speicherkarte (oder Ordner) wählen, von der importiert werden soll"
        NSApp.activate()
        p.begin { [weak self] r in Task { @MainActor in if r == .OK, let u = p.url { self?.setSource(u) } } }
    }

    func chooseDestination() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Hierhin importieren"
        p.message = "Zielordner wählen – am besten ein neuer Ordner pro Projekt/Shooting"
        NSApp.activate()
        p.begin { [weak self] r in Task { @MainActor in if r == .OK, let u = p.url { self?.destination = u } } }
    }

    // MARK: Tage ermitteln

    private func scan() {
        guard let src = source else { return }
        scanning = true; days = []; selected = []
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.collectDays(src) }.value
            days = found
            // Vorauswahl: der neueste Tag
            if let newest = found.first { selected = [newest.key] }
            scanning = false
        }
    }

    nonisolated static func collectDays(_ root: URL) -> [Day] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let media = Sorter.videoExt.union(Sorter.photoExt).union(Sorter.sideExt).union(Sorter.musicExt)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let lf = DateFormatter(); lf.locale = Locale(identifier: "de_DE"); lf.dateFormat = "EE, dd.MM.yyyy"
        var map: [String: Day] = [:]
        while let u = en.nextObject() as? URL {
            // Sony-Vorschaubilder (THMBNL) und Systemordner nicht importieren
            if ["THMBNL", "SUB", "GENERAL", "AVF_INFO", "CANONMSC", "MISC"].contains(u.lastPathComponent.uppercased()) {
                en.skipDescendants(); continue
            }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  media.contains(u.pathExtension.lowercased()) else { continue }
            // Aufnahmedatum: Änderungsdatum ist auf Karten das Aufnahmedatum (Erstellung kann beim Kopieren springen)
            let date = v.contentModificationDate ?? v.creationDate ?? Date()
            let key = df.string(from: date)
            var d = map[key] ?? Day(key: key, label: lf.string(from: date), files: [], bytes: 0)
            d.files.append(u); d.bytes += Int64(v.fileSize ?? 0)
            map[key] = d
        }
        return map.values.sorted { $0.key > $1.key }
    }

    // MARK: Kopieren

    func startCopy() {
        guard let src = source, let dst = destination else { return }
        let files = days.filter { selected.contains($0.key) }.flatMap(\.files)
        guard !files.isEmpty else { return }
        total = files.count; index = 0; copied = 0; skipped = 0; errors = []
        totalBytes = days.filter { selected.contains($0.key) }.reduce(0) { $0 + $1.bytes }
        copiedBytes = 0; cancelled = false; paused = false
        state = .copying
        eta.begin()
        Task { await copyAll(files, from: src, to: dst) }
        Task { while state == .copying || state == .paused { tick = Date(); try? await Task.sleep(nanoseconds: 1_000_000_000) } }
    }

    private func copyAll(_ files: [URL], from src: URL, to dst: URL) async {
        let fm = FileManager.default
        for f in files {
            if cancelled { break }
            while paused && !cancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
            if cancelled { break }
            currentFile = f.lastPathComponent
            let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let target = dst.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                let tsize = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                if tsize == size {
                    skipped += 1; copiedBytes += size; index += 1; continue   // schon importiert
                }
                errors.append("\(f.lastPathComponent): im Ziel existiert eine andere Datei mit gleichem Namen – nicht kopiert")
                copiedBytes += size; index += 1; continue
            }
            let doVerify = verify
            let result: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try fm.copyItem(at: f, to: target)
                    if doVerify, let a = Self.sha256(f), let b = Self.sha256(target), a != b {
                        try? fm.removeItem(at: target)
                        return "Prüfsumme stimmt nicht – Kopie verworfen"
                    }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let r = result { errors.append("\(f.lastPathComponent): \(r)") } else { copied += 1 }
            copiedBytes += size
            index += 1
        }
        currentFile = ""
        if cancelled { state = .idle; return }
        let took = ETA.duration(eta.elapsed)
        state = .finished
        // Danach direkt sortieren
        if copied + skipped > 0, let sorter {
            sorter.reset()
            sorter.addFolders([dst])
            sorter.start()
            sorter.hints.append("Import: \(copied) Dateien kopiert\(verify ? " und geprüft" : "")\(skipped > 0 ? ", \(skipped) waren schon da" : "") – Dauer \(took)")
            sorter.problems.append(contentsOf: errors)
            state = .idle
        }
    }

    nonisolated static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 8 * 1024 * 1024), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func pause() { paused = true; eta.pause(); state = .paused }
    func resume() { paused = false; eta.resume(); state = .copying }
    func cancel() { cancelled = true; paused = false; if state == .choosing { state = .idle } }
    func close() { state = .idle }

    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

// MARK: - Ansichten

struct ImportView: View {
    @EnvironmentObject var imp: ImportRunner

    var body: some View {
        switch imp.state {
        case .choosing: ImportChooser()
        default: ImportProgress()
        }
    }
}

struct ImportChooser: View {
    @EnvironmentObject var imp: ImportRunner
    private var selBytes: Int64 { imp.days.filter { imp.selected.contains($0.key) }.reduce(0) { $0 + $1.bytes } }
    private var selFiles: Int { imp.days.filter { imp.selected.contains($0.key) }.reduce(0) { $0 + $1.files.count } }
    /// Grobe Schätzung mit typischen Kartenlesern (~150 MB/s; mit Prüfung etwa doppelte Lesezeit)
    private var estimate: String {
        let mbps = 150.0 * 1_000_000
        var secs = Double(selBytes) / mbps
        if imp.verify { secs *= 1.8 }
        if secs < 60 { return "unter 1 Minute" }
        let m = Int(secs / 60 + 0.5)
        return m < 60 ? "ca. \(m) Min." : "ca. \(m / 60) Std. \(m % 60) Min."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Von Speicherkarte importieren", systemImage: "sdcard.fill")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                HelpButton(title: "Import von der Speicherkarte",
                           text: "CamSort kopiert die Dateien der gewählten Aufnahmetage von der Karte in deinen Zielordner, prüft jede Kopie per Prüfsumme auf Fehler und sortiert danach automatisch.\n\nDie Karte wird dabei nie verändert oder gelöscht – formatieren musst du sie später selbst in der Kamera. Dateien, die schon im Zielordner liegen, werden übersprungen.")
            }

            // Quelle
            box {
                HStack {
                    Image(systemName: "sdcard").foregroundStyle(Theme.mint)
                    Text(imp.source?.lastPathComponent ?? "Keine Speicherkarte gefunden").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Andere wählen …") { imp.chooseSource() }.buttonStyle(.plain).foregroundStyle(Theme.mint)
                }
            }

            // Tage
            Text("Welche Aufnahmetage importieren?").font(.system(size: 13, weight: .semibold))
            if imp.scanning {
                HStack { ProgressView().controlSize(.small); Text("Karte wird gelesen …").font(.system(size: 12)) }
            } else if imp.days.isEmpty {
                Text(imp.source == nil ? "Karte einstecken oder „Andere wählen …“" : "Keine Fotos oder Videos gefunden.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            } else {
                HStack(spacing: 8) {
                    chip("Nur neuester Tag") { if let f = imp.days.first { imp.selected = [f.key] } }
                    chip("Alle") { imp.selected = Set(imp.days.map(\.key)) }
                    chip("Keine") { imp.selected = [] }
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(imp.days) { d in
                            let on = imp.selected.contains(d.key)
                            Button {
                                if on { imp.selected.remove(d.key) } else { imp.selected.insert(d.key) }
                            } label: {
                                HStack {
                                    Image(systemName: on ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(on ? Theme.mint : .white.opacity(0.5))
                                    Text(d.label).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text("\(d.files.count) Dateien · \(ImportRunner.fmt(d.bytes))")
                                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.mint.opacity(0.15) : Theme.card))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            // Ziel
            box {
                HStack {
                    Image(systemName: "externaldrive.fill").foregroundStyle(Theme.orange)
                    Text(imp.destination?.path ?? "Zielordner wählen …").font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Wählen …") { imp.chooseDestination() }.buttonStyle(.plain).foregroundStyle(Theme.orange)
                }
            }
            if selFiles > 0 {
                Text("Geschätzte Dauer: \(estimate) – die genaue Restzeit siehst du beim Kopieren.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Toggle("Jede Kopie per Prüfsumme kontrollieren (sicherer, etwas langsamer)", isOn: $imp.verify)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button { imp.cancel() } label: {
                    Text("Abbrechen").frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
                Button { imp.startCopy() } label: {
                    Text(selFiles == 0 ? "Importieren" : "\(selFiles) Dateien importieren (\(ImportRunner.fmt(selBytes)))")
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.orange))
                        .opacity(selFiles == 0 || imp.destination == nil ? 0.4 : 1)
                }.buttonStyle(.plain)
                .disabled(selFiles == 0 || imp.destination == nil)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
    }

    private func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }
    private func chip(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.card))
        }.buttonStyle(.plain)
    }
}

struct ImportProgress: View {
    @EnvironmentObject var imp: ImportRunner
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle().trim(from: 0, to: imp.progress)
                    .stroke(AngularGradient(colors: [Theme.mint, Theme.orange, Theme.mint], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: imp.progress)
                VStack(spacing: 4) {
                    Image(systemName: "sdcard.fill").font(.system(size: 24)).foregroundStyle(Theme.mint)
                    Text("\(Int(imp.progress * 100)) %").font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("\(ImportRunner.fmt(imp.copiedBytes)) von \(ImportRunner.fmt(imp.totalBytes))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 180, height: 180)
            Text(imp.state == .paused ? "Pausiert" : imp.state == .finished ? "Import fertig" : "Kopiere und prüfe … (Datei \(min(imp.index + 1, imp.total)) von \(imp.total))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(imp.currentFile).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.middle)
            if imp.state == .copying || imp.state == .paused {
                HStack(spacing: 14) {
                    Label(imp.state == .paused ? "pausiert" : imp.remainingText, systemImage: "clock")
                    if !imp.speedText.isEmpty { Label(imp.speedText, systemImage: "speedometer") }
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mint)
                .id(imp.tick)
            }
            if !imp.errors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(imp.errors, id: \.self) { Text("• " + $0).font(.system(size: 11)) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
            }
            Spacer(minLength: 0)
            if imp.state == .copying || imp.state == .paused {
                HStack(spacing: 12) {
                    Button { imp.state == .paused ? imp.resume() : imp.pause() } label: {
                        Label(imp.state == .paused ? "Fortsetzen" : "Pause", systemImage: imp.state == .paused ? "play.fill" : "pause.fill")
                            .frame(width: 140, height: 40).background(Capsule().fill(Theme.orange))
                    }.buttonStyle(.plain)
                    Button { imp.cancel() } label: {
                        Label("Abbrechen", systemImage: "stop.fill")
                            .frame(width: 140, height: 40).background(Capsule().fill(Color.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                }.font(.system(size: 14, weight: .semibold))
            } else {
                Button { imp.close() } label: {
                    Text("Schließen").frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
            }
        }
    }
}
