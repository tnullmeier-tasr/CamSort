import Foundation
import SwiftUI
import AppKit

/// Schickt Sony-Clips nacheinander über die Gyroflow-Kommandozeile zum Rendern.
@MainActor
final class GyroRunner: ObservableObject {
    enum State: Equatable { case idle, running, paused, finished, failed(String) }

    @Published var state: State = .idle
    @Published var queue: [URL] = []
    @Published var index = 0
    @Published var currentFile = ""
    @Published var currentGroup = ""      // Hochkant / Quer
    @Published var filePercent: Double = 0
    @Published var done: [String] = []
    @Published var errors: [String] = []

    var active: Bool { state != .idle }
    var overall: Double {
        queue.isEmpty ? 0 : (Double(index) + filePercent) / Double(queue.count)
    }

    private let store: LearnedStore
    private weak var sorter: Sorter?
    private var process: Process?
    private var cancelled = false
    private var pauseRequested = false
    private var lastOutput = ""

    init(store: LearnedStore, sorter: Sorter) { self.store = store; self.sorter = sorter }

    // MARK: Gyroflow finden

    static let defaultAppPaths = ["/Applications/Gyroflow.app", NSHomeDirectory() + "/Applications/Gyroflow.app"]

    var appURL: URL? {
        let custom = store.gyroAppPath
        for p in ([custom] + Self.defaultAppPaths) where !p.isEmpty && FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// Ausführbare Datei im App-Paket (Contents/MacOS/…)
    func executable(in app: URL) -> URL? {
        if let b = Bundle(url: app), let e = b.executableURL { return e }
        let dir = app.appendingPathComponent("Contents/MacOS")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.lastPathComponent.lowercased().hasPrefix("gyroflow") } ?? items.first
    }

    // MARK: Sony-Clips sammeln

    /// Unstabilisierte Sony-Videos in Hochkant/Quer-Ordnern – erst alle Hochkant, dann alle Quer.
    func collectSonyClips(in folders: [URL]) -> (hochkant: [URL], quer: [URL]) {
        let fm = FileManager.default
        let suffixes = store.gyroSuffixList
        var h: [URL] = [], q: [URL] = []
        for base in folders {
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                let name = u.lastPathComponent
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if ["Stabilisiert", "Original", "Gyroflow-Projekte"].contains(name) { en.skipDescendants() }
                    continue
                }
                guard Sorter.videoExt.contains(u.pathExtension.lowercased()) else { continue }
                let stem = u.deletingPathExtension().lastPathComponent.lowercased()
                if suffixes.contains(where: { stem.contains($0) }) { continue }       // schon stabilisiert
                let comps = u.pathComponents
                let group = comps.contains("Hochkant") ? "Hochkant" : comps.contains("Quer") ? "Quer" : nil
                guard let group, comps.contains("Videos") else { continue }
                guard hasStabilizedSibling(u, suffixes: suffixes) == false else { continue }
                guard Self.isSony(u) else { continue }
                if group == "Hochkant" { h.append(u) } else { q.append(u) }
            }
        }
        return (h.sorted { $0.path < $1.path }, q.sorted { $0.path < $1.path })
    }

    private func hasStabilizedSibling(_ u: URL, suffixes: [String]) -> Bool {
        let dir = u.deletingLastPathComponent()
        let stem = u.deletingPathExtension().lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { n in
            let s = (n as NSString).deletingPathExtension.lowercased()
            return s != stem && s.hasPrefix(stem) && suffixes.contains { s.contains($0) }
        }
    }

    /// Sony erkennt man am eingebetteten XML in der MP4 (unabhängig vom Ordnernamen).
    static func isSony(_ url: URL) -> Bool {
        // a) Begleit-XML: liegt nach dem Sortieren in einem „XML“-Ordner weiter oben
        let stem = url.deletingPathExtension().lastPathComponent
        var dir = url.deletingLastPathComponent()
        for _ in 0..<8 {
            for name in [stem + "M01.XML", stem + "M01.xml"] {
                for cand in [dir.appendingPathComponent("XML").appendingPathComponent(name), dir.appendingPathComponent(name)] {
                    if let s = try? String(contentsOf: cand, encoding: .utf8),
                       s.range(of: "manufacturer=\"Sony\"", options: .caseInsensitive) != nil { return true }
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // b) In der MP4 eingebettetes XML
        return isSonyEmbedded(url)
    }

    static func isSonyEmbedded(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var data = (try? h.read(upToCount: 1_048_576)) ?? Data()
        if let size = try? h.seekToEnd(), size > 1_048_576 {
            try? h.seek(toOffset: size - 1_048_576)
            data.append((try? h.read(upToCount: 1_048_576)) ?? Data())
        }
        return data.range(of: Data("manufacturer=\"Sony\"".utf8)) != nil
    }

    // MARK: Ablauf

    func start(folders: [URL]) {
        errors = []; done = []; cancelled = false; pauseRequested = false
        guard let app = appURL, let exe = executable(in: app) else {
            state = .failed("Gyroflow wurde nicht gefunden. Bitte unter Einstellungen › Gyroflow die Gyroflow-App auswählen.")
            return
        }
        let preset = store.gyroPresetPath
        guard !preset.isEmpty, FileManager.default.fileExists(atPath: preset) else {
            state = .failed("Es ist noch kein Gyroflow-Preset hinterlegt. Bitte unter Einstellungen › Gyroflow das Preset auswählen (dort steht Schritt für Schritt, wie).")
            return
        }
        let clips = collectSonyClips(in: folders)
        queue = clips.hochkant + clips.quer
        guard !queue.isEmpty else {
            state = .failed("Keine unstabilisierten Sony-Clips gefunden. Entweder sind schon alle stabilisiert, oder der Ordner wurde noch nicht sortiert.")
            return
        }
        index = 0
        state = .running
        Task { await runAll(exe: exe, preset: preset, hochkantCount: clips.hochkant.count, folders: folders) }
    }

    private func runAll(exe: URL, preset: String, hochkantCount: Int, folders: [URL]) async {
        while index < queue.count {
            if cancelled { break }
            while pauseRequested && !cancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
            if cancelled { break }
            let clip = queue[index]
            currentGroup = index < hochkantCount ? "Hochkant" : "Quer"
            currentFile = clip.lastPathComponent
            filePercent = 0
            let ok = await render(exe: exe, clip: clip, preset: preset)
            if cancelled { break }
            if ok { done.append(clip.lastPathComponent) }
            index += 1
            // App-Store-Sperre o. Ä.: sofort beim ersten Clip abbrechen statt alles fehlschlagen zu lassen
            if !ok && done.isEmpty && index == 1 && lastOutput.lowercased().contains("not permitted") {
                state = .failed("Gyroflow lässt sich von CamSort nicht steuern (vermutlich die App-Store-Version mit Apples Sandbox). Abhilfe: Gyroflow von gyroflow.xyz installieren.")
                return
            }
        }
        currentFile = ""
        if cancelled { state = .idle; return }
        // Danach automatisch Stabilisiert / Original trennen und Ergebnis zeigen
        if !done.isEmpty, let sorter {
            sorter.folders = folders
            sorter.startGyro()
            sorter.hints.append("Gyroflow: \(done.count) von \(queue.count) Sony-Clips stabilisiert")
            sorter.problems.append(contentsOf: errors)
            state = .idle
        } else {
            state = .finished
        }
    }

    private func render(exe: URL, clip: URL, preset: String) async -> Bool {
        let suffix = store.gyroSuffixList.first ?? "_stabilized"
        let p = Process()
        p.executableURL = exe
        p.arguments = [clip.path, "--preset", preset, "-t", suffix, "-f", "--stdout-progress"]
        p.standardInput = FileHandle.nullDevice   // keine Rückfragen – nichts kann auf Eingabe warten
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        lastOutput = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleOutput(s) }
        }
        do { try p.run() } catch {
            errors.append("\(clip.lastPathComponent): Gyroflow konnte nicht gestartet werden (\(error.localizedDescription))")
            return false
        }
        process = p
        while p.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
        pipe.fileHandleForReading.readabilityHandler = nil
        process = nil
        if cancelled { return false }
        let out = clip.deletingLastPathComponent()
        let stem = clip.deletingPathExtension().lastPathComponent
        let produced = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [])
            .contains { $0.hasPrefix(stem + suffix) }
        if p.terminationStatus == 0 && produced { filePercent = 1; return true }
        let tail = lastOutput.split(separator: "\n").suffix(2).joined(separator: " ")
        errors.append("\(clip.lastPathComponent): Gyroflow-Fehler (Code \(p.terminationStatus))\(tail.isEmpty ? "" : " – " + tail)")
        return false
    }

    private func handleOutput(_ s: String) {
        lastOutput = String((lastOutput + s).suffix(2000))
        // Fortschritt als Prozent oder als „aktuell/gesamt“ erkennen
        if let r = s.range(of: #"(\d{1,3}(\.\d+)?)\s*%"#, options: .regularExpression, range: nil, locale: nil) {
            let n = s[r].filter { "0123456789.".contains($0) }
            if let v = Double(n), v <= 100 { filePercent = v / 100 }
        } else if let r = s.range(of: #"(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
            let parts = s[r].split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[1] > 0 { filePercent = min(1, parts[0] / parts[1]) }
        }
    }

    func pause() {
        pauseRequested = true
        if let p = process, p.isRunning { _ = p.suspend() }
        state = .paused
    }

    func resume() {
        pauseRequested = false
        if let p = process, p.isRunning { _ = p.resume() }
        state = .running
    }

    func cancel() {
        cancelled = true
        if let p = process, p.isRunning {
            if pauseRequested { _ = p.resume() }
            p.terminate()
        }
        pauseRequested = false
    }

    func close() { state = .idle; queue = []; errors = []; done = [] }
}

// MARK: - Ansicht

struct GyroView: View {
    @EnvironmentObject var gyro: GyroRunner

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: gyro.overall)
                    .stroke(AngularGradient(colors: [Theme.mint, Theme.orange, Theme.mint], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: gyro.overall)
                VStack(spacing: 4) {
                    Image(systemName: "gyroscope").font(.system(size: 26)).foregroundStyle(Theme.mint)
                    Text("\(Int(gyro.overall * 100)) %").font(.system(size: 34, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text(gyro.queue.isEmpty ? " " : "Clip \(min(gyro.index + 1, gyro.queue.count)) von \(gyro.queue.count)")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 180, height: 180)

            switch gyro.state {
            case .running, .paused:
                VStack(spacing: 6) {
                    Text(gyro.state == .paused ? "Pausiert" : "Gyroflow stabilisiert \(gyro.currentGroup)-Clips …")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(gyro.currentFile).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: gyro.filePercent).tint(Theme.orange).frame(maxWidth: 300)
                    Text("Clips werden einzeln nacheinander gerendert – erst Hochkant, dann Quer.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 12) {
                    Button { gyro.state == .paused ? gyro.resume() : gyro.pause() } label: {
                        Label(gyro.state == .paused ? "Fortsetzen" : "Pause",
                              systemImage: gyro.state == .paused ? "play.fill" : "pause.fill")
                            .frame(width: 140, height: 40)
                            .background(Capsule().fill(Theme.orange))
                    }.buttonStyle(.plain)
                    Button { gyro.cancel() } label: {
                        Label("Abbrechen", systemImage: "stop.fill")
                            .frame(width: 140, height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
                .font(.system(size: 14, weight: .semibold))
            case .finished:
                Text("Gyroflow ist fertig – \(gyro.done.count) von \(gyro.queue.count) Clips stabilisiert.")
                    .font(.system(size: 15, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
            case .failed(let msg):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(Theme.orange)
                    Text(msg).font(.system(size: 13)).multilineTextAlignment(.center)
                }
            case .idle: EmptyView()
            }

            if !gyro.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(gyro.errors, id: \.self) { Text("• " + $0).font(.system(size: 11)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
            }

            Spacer(minLength: 0)

            if gyro.state != .running && gyro.state != .paused {
                Button { gyro.close() } label: {
                    Text("Schließen").frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Hilfe-Knopf

struct HelpButton: View {
    let title: String
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// Zeile mit Inhalt + ?-Knopf
struct WithHelp<Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content
            Spacer(minLength: 4)
            HelpButton(title: title, text: text)
        }
    }
}
