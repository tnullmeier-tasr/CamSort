import Foundation
import AVFoundation
import CoreVideo
import SwiftUI
import AppKit

/// „Beste Momente“: misst lokal (ohne KI) pro Abschnitt Schärfe, Belichtung und Ruhe, behält die besten
/// und schreibt eine Final-Cut-Timeline (FCPXML). Die Clips werden nur verknüpft, nicht kopiert oder verändert.
@MainActor
final class SelectsRunner: ObservableObject {
    enum State: Equatable { case idle, running, finished, failed(String) }
    struct Segment { let url: URL; let start: Double; let end: Double; let score: Double; let focus: Double; let exposure: Double; let calm: Double }

    @Published var state: State = .idle
    @Published var total = 0
    @Published var index = 0
    @Published var currentFile = ""
    @Published var analyzedSeconds = 0.0
    @Published var kept: [Segment] = []
    @Published var outputs: [URL] = []
    @Published var errors: [String] = []
    var eta = ETA()
    private var cancelled = false

    var active: Bool { state != .idle }
    var progress: Double { total == 0 ? 0 : Double(index) / Double(total) }

    // Einstellungen
    private static let d = UserDefaults.standard
    @Published var segmentLength: Double = d.object(forKey: "selSegment") as? Double ?? 4 { didSet { Self.d.set(segmentLength, forKey: "selSegment") } }
    @Published var keepPercent: Double = d.object(forKey: "selKeepPercent") as? Double ?? 30 { didSet { Self.d.set(keepPercent, forKey: "selKeepPercent") } }
    @Published var wFocus: Double = d.object(forKey: "selWFocus") as? Double ?? 1 { didSet { Self.d.set(wFocus, forKey: "selWFocus") } }
    @Published var wExposure: Double = d.object(forKey: "selWExposure") as? Double ?? 1 { didSet { Self.d.set(wExposure, forKey: "selWExposure") } }
    @Published var wCalm: Double = d.object(forKey: "selWCalm") as? Double ?? 1 { didSet { Self.d.set(wCalm, forKey: "selWCalm") } }
    @Published var preferStabilized: Bool = d.object(forKey: "selPreferStabilized") as? Bool ?? true { didSet { Self.d.set(preferStabilized, forKey: "selPreferStabilized") } }

    func start(folders: [URL], suffixes: [String]) {
        cancelled = false; kept = []; outputs = []; errors = []; index = 0; analyzedSeconds = 0
        // pro Dreh sammeln (Ordner über „Videos“)
        var byDreh: [URL: [URL]] = [:]
        for f in folders {
            for u in Self.videos(in: f, suffixes: suffixes, preferStabilized: preferStabilized) {
                // „Meine Kameraordner“ (kein „Videos“ im Pfad): gewählter Ordner = Dreh
                let own = !u.pathComponents.contains(where: FolderNames.isVideos)
                byDreh[own ? f : Sorter.drehRoot(u.deletingLastPathComponent()), default: []].append(u)
            }
        }
        total = byDreh.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { state = .failed("Keine Videos gefunden – bitte zuerst sortieren."); return }
        state = .running
        eta.begin()
        Task { await run(byDreh) }
    }

    func cancel() { cancelled = true }
    func close() { state = .idle }

    /// Videos unter „Videos“; mit Gyroflow-Version bevorzugt die stabilisierte Datei
    nonisolated static func videos(in base: URL, suffixes: [String], preferStabilized: Bool) -> [URL] {
        var all: [URL] = []
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        while let u = en.nextObject() as? URL {
            if Sorter.videoExt.contains(u.pathExtension.lowercased()), FolderNames.isSortedVideoPath(u.pathComponents) { all.append(u) }
        }
        func isStab(_ u: URL) -> Bool { let s = u.deletingPathExtension().lastPathComponent.lowercased(); return suffixes.contains { s.contains($0) } }
        let stab = all.filter(isStab)
        var out: [URL] = []
        for u in all {
            if isStab(u) { if preferStabilized { out.append(u) }; continue }
            let stem = u.deletingPathExtension().lastPathComponent.lowercased()
            let hasStab = stab.contains { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(stem) }
            if !(preferStabilized && hasStab) { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    private func run(_ byDreh: [URL: [URL]]) async {
        for (dreh, clips) in byDreh.sorted(by: { $0.key.path < $1.key.path }) {
            var raw: [(URL, [Window])] = []
            for c in clips {
                if cancelled { state = .idle; return }
                currentFile = c.lastPathComponent
                let seg = segmentLength
                let w = await Task.detached(priority: .userInitiated) { await Self.analyze(c, segment: seg) }.value
                if w.isEmpty { errors.append("\(c.lastPathComponent): nicht lesbar – übersprungen") }
                analyzedSeconds += w.last?.end ?? 0
                raw.append((c, w))
                index += 1
            }
            // Schärfe relativ zum Dreh normalisieren (95. Perzentil = 1.0)
            let sharp = raw.flatMap { $0.1.map(\.sharpness) }.sorted()
            let ref = sharp.isEmpty ? 1 : max(sharp[Int(Double(sharp.count - 1) * 0.95)], 1e-6)
            let sum = max(wFocus + wExposure + wCalm, 0.01)
            var segs: [Segment] = []
            for (u, ws) in raw {
                for w in ws {
                    let f = min(1, w.sharpness / ref)
                    let s = (wFocus * f + wExposure * w.exposure + wCalm * w.calm) / sum
                    segs.append(Segment(url: u, start: w.start, end: w.end, score: s, focus: f, exposure: w.exposure, calm: w.calm))
                }
            }
            let n = max(1, Int((Double(segs.count) * keepPercent / 100).rounded()))
            let best = Set(segs.sorted { $0.score > $1.score }.prefix(n).map { "\($0.url.path)#\($0.start)" })
            // chronologisch (Datei, dann Zeit) und direkt aufeinanderfolgende Abschnitte zusammenfassen
            var chosen: [Segment] = []
            for s in segs where best.contains("\(s.url.path)#\(s.start)") {
                if let last = chosen.last, last.url == s.url, abs(last.end - s.start) < 0.01 {
                    chosen[chosen.count - 1] = Segment(url: s.url, start: last.start, end: s.end, score: max(last.score, s.score),
                                                       focus: max(last.focus, s.focus), exposure: max(last.exposure, s.exposure), calm: max(last.calm, s.calm))
                } else { chosen.append(s) }
            }
            kept += chosen
            if !chosen.isEmpty {
                let name = dreh.lastPathComponent
                let out = dreh.appendingPathComponent("\(name) – Beste Momente.fcpxml")
                do {
                    try await FCPXML.write(segments: chosen, eventName: "CamSort – \(name)", projectName: "Beste Momente", to: out)
                    outputs.append(out)
                } catch { errors.append("FCPXML für \(name) konnte nicht geschrieben werden: \(error.localizedDescription)") }
            }
        }
        currentFile = ""
        state = .finished
    }

    // MARK: Analyse (ohne KI, nur Bildstatistik)

    struct Window { let start: Double; let end: Double; let sharpness: Double; let exposure: Double; let calm: Double }

    nonisolated static func analyze(_ url: URL, segment: Double) async -> [Window] {
        let asset = AVURLAsset(url: url)
        guard let found = try? await asset.loadTracks(withMediaType: .video), let track = found.first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 0
        let assetDuration = (try? await asset.load(.duration))?.seconds ?? 0
        let W = 160, H = 90
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }
        let fps = Double(nominalFPS > 0 ? nominalFPS : 25)
        let step = max(1, Int((fps / 4).rounded()))      // ~4 Bilder pro Sekunde auswerten
        var frame = 0
        var prev: [Float]? = nil
        var samples: [(t: Double, sharp: Double, expo: Double, calm: Double)] = []
        while let sb = out.copyNextSampleBuffer() {
            defer { frame += 1 }
            guard frame % step == 0, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { CVPixelBufferUnlockBaseAddress(pb, .readOnly); continue }
            let p = base.assumingMemoryBound(to: UInt8.self)
            var gray = [Float](repeating: 0, count: w * h)
            var sum: Float = 0, clipped = 0
            for y in 0..<h { for x in 0..<w {
                let o = y * bpr + x * 4
                let v = (0.114 * Float(p[o]) + 0.587 * Float(p[o + 1]) + 0.299 * Float(p[o + 2])) / 255
                gray[y * w + x] = v; sum += v
                if v < 0.03 || v > 0.97 { clipped += 1 }
            } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            // Schärfe: mittlere Laplace-Antwort
            var lap: Float = 0
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                lap += abs(4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - w] - gray[i + w])
            } }
            let sharp = Double(lap) / Double((w - 2) * (h - 2))
            // Belichtung: Mitte gut, Ausfressen/Absaufen schlecht
            let mean = Double(sum) / Double(w * h)
            let clipRatio = Double(clipped) / Double(w * h)
            let expo = max(0, 1 - abs(mean - 0.5) * 1.6 - clipRatio * 2)
            // Ruhe: wenig Bildänderung zum vorherigen Messbild (kein Wackeln/Schwenk-Ruckeln)
            var calm = 1.0
            if let pv = prev, pv.count == gray.count {
                var d: Float = 0
                for i in 0..<gray.count { d += abs(gray[i] - pv[i]) }
                calm = max(0, 1 - Double(d) / Double(gray.count) / 0.12)
            }
            prev = gray
            samples.append((t, sharp, expo, calm))
        }
        guard reader.status == .completed || reader.status == .reading, !samples.isEmpty else { return [] }
        let dur = max(assetDuration, samples.last!.t + 0.25)
        var wins: [Window] = []
        var s = 0.0
        while s < dur - 0.5 {
            let e = min(dur, s + segment)
            let inWin = samples.filter { $0.t >= s && $0.t < e }
            if !inWin.isEmpty {
                let c = Double(inWin.count)
                wins.append(Window(start: s, end: e,
                                   sharpness: inWin.map(\.sharp).reduce(0, +) / c,
                                   exposure: inWin.map(\.expo).reduce(0, +) / c,
                                   calm: inWin.map(\.calm).reduce(0, +) / c))
            }
            s = e
        }
        return wins
    }
}

// MARK: - FCPXML (Final Cut Pro) – Clips werden nur verknüpft

enum FCPXML {
    struct Rate { let num: Int; let den: Int }   // Bilddauer = num/den Sekunden
    static func rate(_ fps: Float) -> Rate {
        let table: [(Double, Rate)] = [(23.976, .init(num: 1001, den: 24000)), (24, .init(num: 100, den: 2400)), (25, .init(num: 100, den: 2500)),
                                       (29.97, .init(num: 1001, den: 30000)), (30, .init(num: 100, den: 3000)), (47.952, .init(num: 1001, den: 48000)),
                                       (48, .init(num: 100, den: 4800)), (50, .init(num: 100, den: 5000)), (59.94, .init(num: 1001, den: 60000)),
                                       (60, .init(num: 100, den: 6000)), (100, .init(num: 100, den: 10000)), (119.88, .init(num: 1001, den: 120000)),
                                       (120, .init(num: 100, den: 12000))]
        let f = Double(fps > 0 ? fps : 25)
        return table.min { abs($0.0 - f) < abs($1.0 - f) }!.1
    }
    static func frames(_ sec: Double, _ r: Rate) -> Int { Int((sec * Double(r.den) / Double(r.num)).rounded()) }
    static func t(_ frames: Int, _ r: Rate) -> String { frames == 0 ? "0s" : "\(frames * r.num)/\(r.den)s" }
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Startzeitcode der Datei (Sony & Co. schreiben einen), damit Final Cut die richtigen Stellen trifft
    static func timecodeStart(_ asset: AVURLAsset, rate r: Rate) async -> Int {
        guard let tcs = try? await asset.loadTracks(withMediaType: .timecode), let tc = tcs.first, let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let out = AVAssetReaderTrackOutput(track: tc, outputSettings: nil)
        guard reader.canAdd(out) else { return 0 }
        reader.add(out); reader.startReading()
        guard let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var v: UInt32 = 0
        guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: 4, destination: &v) == noErr else { return 0 }
        // Zeitcode-Bildnummer = Bilder in der Bildrate des Clips (NDF), passt direkt zu Final Cut
        return Int(UInt32(bigEndian: v))
    }

    static func write(segments: [SelectsRunner.Segment], eventName: String, projectName: String, to out: URL) async throws {
        var formats: [String: (id: String, r: Rate, w: Int, h: Int)] = [:]
        var assets: [URL: (id: String, fmt: String, r: Rate, start: Int, dur: Int, audio: Bool)] = [:]
        var res = ""
        var n = 1
        for s in segments where assets[s.url] == nil {
            let a = AVURLAsset(url: s.url)
            guard let vts = try? await a.loadTracks(withMediaType: .video), let vt = vts.first,
                  let props = try? await vt.load(.nominalFrameRate, .naturalSize, .preferredTransform) else { continue }
            let r = rate(props.0)
            let sz = props.1.applying(props.2)
            let w = Int(abs(sz.width)), h = Int(abs(sz.height))
            let key = "\(r.num)/\(r.den)-\(w)x\(h)"
            if formats[key] == nil {
                let id = "r\(n)"; n += 1
                formats[key] = (id, r, w, h)
                res += "    <format id=\"\(id)\" frameDuration=\"\(r.num)/\(r.den)s\" width=\"\(w)\" height=\"\(h)\"/>\n"
            }
            let fmt = formats[key]!
            let id = "r\(n)"; n += 1
            let start = await timecodeStart(a, rate: r)
            let dur = frames((try? await a.load(.duration))?.seconds ?? 0, r)
            let audio = !((try? await a.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            assets[s.url] = (id, fmt.id, r, start, dur, audio)
            res += "    <asset id=\"\(id)\" name=\"\(esc(s.url.deletingPathExtension().lastPathComponent))\" start=\"\(t(start, r))\" duration=\"\(t(dur, r))\" hasVideo=\"1\" hasAudio=\"\(audio ? 1 : 0)\" format=\"\(fmt.id)\"\(audio ? " audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"" : "")>\n"
            res += "      <media-rep kind=\"original-media\" src=\"\(esc(s.url.absoluteString))\"/>\n"
            res += "    </asset>\n"
        }
        guard let first = segments.first, let seqA = assets[first.url], let seqFmt = formats.values.first(where: { $0.id == seqA.fmt }) else {
            throw NSError(domain: "CamSort", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine lesbaren Clips"])
        }
        let sr = seqFmt.r
        var spine = ""
        var offset = 0
        for s in segments {
            guard let a = assets[s.url] else { continue }
            let st = frames(s.start, a.r), en = min(frames(s.end, a.r), a.dur)
            guard en > st else { continue }
            let durSeq = max(1, frames(Double(en - st) * Double(a.r.num) / Double(a.r.den), sr))
            let durClip = en - st
            let label = String(format: "%@ · Score %d", s.url.deletingPathExtension().lastPathComponent, Int(s.score * 100))
            spine += "            <asset-clip ref=\"\(a.id)\" name=\"\(esc(label))\" offset=\"\(t(offset, sr))\" start=\"\(t(a.start + st, a.r))\" duration=\"\(t(durClip, a.r))\" format=\"\(a.fmt)\" tcFormat=\"NDF\">\n"
            spine += "              <marker start=\"\(t(a.start + st, a.r))\" duration=\"\(t(1, a.r))\" value=\"\(esc(String(format: "Score %d · Schärfe %d · Belichtung %d · Ruhe %d", Int(s.score * 100), Int(s.focus * 100), Int(s.exposure * 100), Int(s.calm * 100))))\"/>\n"
            spine += "            </asset-clip>\n"
            offset += durSeq
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
        \(res)  </resources>
          <library>
            <event name="\(esc(eventName))">
              <project name="\(esc(projectName))">
                <sequence format="\(seqFmt.id)" duration="\(t(offset, sr))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>
        \(spine)          </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """
        try xml.write(to: out, atomically: true, encoding: .utf8)
    }
}

// MARK: - Ansicht

struct SelectsView: View {
    @EnvironmentObject var sel: SelectsRunner
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle().trim(from: 0, to: sel.progress)
                    .stroke(AngularGradient(colors: [Theme.mint, Theme.orange, Theme.mint], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: sel.progress)
                VStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(Theme.mint)
                    Text("\(Int(sel.progress * 100)) %").font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("Clip \(min(sel.index + 1, max(sel.total, 1))) von \(sel.total)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }.frame(width: 180, height: 180)

            switch sel.state {
            case .running:
                Text("Suche die besten Momente … (lokal, ohne KI)").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(sel.currentFile).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Label(ETA.text(sel.eta.remaining(done: Double(sel.index), total: Double(sel.total))), systemImage: "clock")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mint)
                Button { sel.cancel() } label: {
                    Label("Abbrechen", systemImage: "stop.fill").frame(width: 160, height: 40).background(Capsule().fill(Color.white.opacity(0.12)))
                }.buttonStyle(.plain)
            case .finished:
                let secs = sel.kept.reduce(0.0) { $0 + ($1.end - $1.start) }
                Text("\(ETA.duration(sel.analyzedSeconds)) Material in \(ETA.duration(sel.eta.elapsed)) analysiert")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("\(sel.kept.count) beste Momente behalten · zusammen \(ETA.duration(secs))")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                ForEach(sel.outputs, id: \.self) { o in
                    Button { NSWorkspace.shared.open(o) } label: {
                        Label("In Final Cut öffnen: \(o.deletingPathExtension().lastPathComponent)", systemImage: "film.stack")
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.orange))
                    }.buttonStyle(.plain)
                }
                Text("Final Cut legt ein Projekt „Beste Momente“ an – die Clips bleiben am Ort, nichts wird kopiert. Jeder Abschnitt trägt einen Marker mit seinem Score.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            case .failed(let m):
                Text(m).font(.system(size: 13)).multilineTextAlignment(.center)
            case .idle: EmptyView()
            }
            if !sel.errors.isEmpty {
                VStack(alignment: .leading, spacing: 3) { ForEach(sel.errors, id: \.self) { Text("• " + $0).font(.system(size: 11)) } }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
            }
            Spacer(minLength: 0)
            if sel.state != .running {
                Button { sel.close() } label: {
                    Text("Schließen").frame(maxWidth: .infinity).frame(height: 44).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Einstellungen für „Beste Momente“
struct SelectsSettings: View {
    @EnvironmentObject var sel: SelectsRunner
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WithHelp(title: "Beste Momente", text: "Nach dem Sortieren analysiert CamSort jeden Clip in Abschnitten – lokal und ohne KI – nach Schärfe, Belichtung und Ruhe (wenig Wackeln). Die besten Abschnitte landen als Projekt „Beste Momente“ in einer Final-Cut-Datei im Dreh-Ordner. Ein Doppelklick öffnet sie in Final Cut; die Clips werden nur verknüpft. Mit den Gewichten bestimmst du, was dir wichtiger ist.") {
                Text("Wie ausgewählt wird").font(.system(size: 12))
            }
            Stepper("Abschnittslänge: \(Int(sel.segmentLength)) s", value: $sel.segmentLength, in: 1...30, step: 1)
            Stepper("Behalten: beste \(Int(sel.keepPercent)) %", value: $sel.keepPercent, in: 5...90, step: 5)
            weight("Schärfe", $sel.wFocus)
            weight("Belichtung", $sel.wExposure)
            weight("Ruhe (wenig Wackeln)", $sel.wCalm)
            Toggle("Stabilisierte Gyroflow-Version bevorzugen", isOn: $sel.preferStabilized).toggleStyle(.switch)
        }
        .font(.system(size: 12)).controlSize(.small)
    }
    private func weight(_ t: String, _ b: Binding<Double>) -> some View {
        HStack { Text(t).frame(width: 150, alignment: .leading); Slider(value: b, in: 0...2, step: 0.25); Text(String(format: "%.2g×", b.wrappedValue)).frame(width: 34) }
    }
}
