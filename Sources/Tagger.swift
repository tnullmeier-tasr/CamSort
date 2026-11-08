import Foundation
import AVFoundation
import Vision
import SwiftUI
import AppKit

/// Erkennt lokal (Apple Vision, offline), was in Clips zu sehen ist, und ergänzt Finder-Tags.
/// Die Videodatei selbst wird NICHT verändert – Finder-Tags liegen in den Dateiattributen.
@MainActor
final class TagRunner: ObservableObject {
    enum State: Equatable { case idle, running, paused, finished }
    @Published var state: State = .idle
    @Published var queue: [URL] = []
    @Published var index = 0
    @Published var currentFile = ""
    @Published var tagCounts: [String: Int] = [:]
    @Published var errors: [String] = []
    var eta = ETA()
    var remainingText: String { ETA.text(eta.remaining(done: Double(index), total: Double(queue.count))) }

    var active: Bool { state != .idle }
    var progress: Double { queue.isEmpty ? 0 : Double(index) / Double(queue.count) }
    private var cancelled = false
    private var paused = false

    // Vision-Begriffe (englisch) → deutsche Tags. Nur diese werden übernommen, damit keine Flut an Tags entsteht.
    nonisolated static let labelMap: [String: String] = [
        "people": "Person", "person": "Person", "adult": "Person", "child": "Person", "portrait": "Person", "crowd": "Personen",
        "car": "Auto", "automobile": "Auto", "sports_car": "Auto", "convertible": "Auto", "suv": "Auto", "sedan": "Auto",
        "coupe": "Auto", "jeep": "Auto", "pickup_truck": "Auto", "race_car": "Auto", "vehicle": "Fahrzeug",
        "motorcycle": "Motorrad", "motorbike": "Motorrad", "scooter": "Roller", "bicycle": "Fahrrad",
        "truck": "LKW", "bus": "Bus", "train": "Zug", "boat": "Boot", "aircraft": "Flugzeug", "helicopter": "Hubschrauber",
        "engine": "Motorraum", "motor": "Motorraum", "car_engine": "Motorraum",
        "seat": "Sitz", "car_seat": "Sitz", "chair": "Sitz",
        "door": "Türe", "car_door": "Türe",
        "steering_wheel": "Lenkrad", "dashboard": "Armaturenbrett", "speedometer": "Tacho", "button": "Knopf",
        "tire": "Reifen", "wheel": "Rad", "rim": "Felge", "headlight": "Scheinwerfer",
        "road": "Straße", "highway": "Straße", "street": "Straße", "race_track": "Rennstrecke",
        "garage": "Garage", "parking_lot": "Parkplatz", "showroom": "Showroom",
        "building": "Gebäude", "city": "Stadt", "mountain": "Berge", "forest": "Wald", "beach": "Strand",
        "sky": "Himmel", "sunset": "Sonnenuntergang", "night": "Nacht", "snow": "Schnee", "water": "Wasser",
        "dog": "Hund", "cat": "Katze", "food": "Essen", "indoor": "Innen", "interior_room": "Innen",
    ]

    nonisolated static let brands: [String] = [
        "Porsche", "BMW", "Mercedes", "Mercedes-Benz", "AMG", "Audi", "Volkswagen", "VW", "Maserati", "Ferrari",
        "Lamborghini", "Ford", "Opel", "Toyota", "Tesla", "MINI", "Jaguar", "Land Rover", "Range Rover", "Bentley",
        "Rolls-Royce", "Aston Martin", "McLaren", "Bugatti", "Ducati", "Harley-Davidson", "KTM", "Kawasaki", "Honda",
        "Yamaha", "Suzuki", "Triumph", "Volvo", "Skoda", "SEAT", "Cupra", "Peugeot", "Renault", "Fiat", "Alfa Romeo",
        "Hyundai", "Kia", "Mazda", "Nissan", "Lexus", "Polestar", "Lotus", "Alpine", "Jeep", "Dodge", "Chevrolet",
        "Cadillac", "Smart", "Dacia", "Citroën", "Abarth", "Genesis", "BYD", "Aprilia", "Moto Guzzi", "MV Agusta",
    ]

    func start(folders: [URL]) {
        cancelled = false; paused = false; errors = []; tagCounts = [:]; index = 0
        queue = Self.collectVideos(folders)
        guard !queue.isEmpty else {
            errors = ["Keine Videos in sortierten Ordnern gefunden – bitte zuerst sortieren."]
            state = .finished; return
        }
        state = .running
        eta.begin()
        Task { await run() }
    }

    static func collectVideos(_ folders: [URL]) -> [URL] {
        var out: [URL] = []
        for base in folders {
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                if Sorter.videoExt.contains(u.pathExtension.lowercased()), FolderNames.isSortedVideoPath(u.pathComponents) { out.append(u) }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private func run() async {
        while index < queue.count {
            if cancelled { break }
            while paused && !cancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
            if cancelled { break }
            let clip = queue[index]
            currentFile = clip.lastPathComponent
            let tags = await Task.detached(priority: .userInitiated) { Self.analyze(clip) }.value
            if !tags.isEmpty {
                if Self.addFinderTags(tags, to: clip) {
                    for t in tags { tagCounts[t, default: 0] += 1 }
                } else {
                    errors.append("\(clip.lastPathComponent): Tags konnten nicht gesetzt werden")
                }
            }
            index += 1
        }
        currentFile = ""
        state = cancelled ? .idle : .finished
    }

    func pause() { paused = true; eta.pause(); state = .paused }
    func resume() { paused = false; eta.resume(); state = .running }
    func cancel() { cancelled = true; paused = false }
    func close() { state = .idle; queue = []; tagCounts = [:]; errors = [] }

    // MARK: Analyse (läuft im Hintergrund)

    nonisolated static func analyze(_ url: URL) -> [String] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 768, height: 768)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let duration = durationSeconds(asset)
        guard duration > 0 else { return [] }
        // Alle ~3 s ein Bild, höchstens 12 pro Clip
        let n = max(1, min(12, Int(duration / 3)))
        var counts: [String: Int] = [:]
        var brands = Set<String>()
        for i in 0..<n {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
            guard let img = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
            let handler = VNImageRequestHandler(cgImage: img, options: [:])
            let classify = VNClassifyImageRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            try? handler.perform([classify, text])
            for o in classify.results ?? [] where o.confidence > 0.35 {
                if let tag = labelMap[o.identifier.lowercased()] { counts[tag, default: 0] += 1 }
            }
            for o in text.results ?? [] {
                guard let c = o.topCandidates(1).first, c.confidence > 0.5 else { continue }
                if let b = brand(in: c.string) { brands.insert(b) }
            }
        }
        // Begriff zählt, wenn er in mind. 1 Bild (kurze Clips) bzw. 2 Bildern (längere) erkannt wurde
        let minHits = n >= 4 ? 2 : 1
        var tags = counts.filter { $0.value >= minHits }.map(\.key)
        tags.append(contentsOf: brands)
        return Array(Set(tags)).sorted()
    }

    nonisolated static func durationSeconds(_ asset: AVURLAsset) -> Double {
        let d = asset.duration.seconds
        return d.isFinite ? d : 0
    }

    nonisolated static func brand(in s: String) -> String? {
        let up = " " + s.uppercased().replacingOccurrences(of: "-", with: " ") + " "
        for b in brands {
            let key = " " + b.uppercased().replacingOccurrences(of: "-", with: " ") + " "
            if up.contains(key) {
                if b == "VW" { return "Volkswagen" }
                if b == "Mercedes-Benz" || b == "Mercedes" { return "Mercedes-Benz" }
                return b
            }
        }
        return nil
    }

    /// Ergänzt Finder-Tags – vorhandene Tags bleiben erhalten, der Dateiinhalt wird nicht angefasst.
    static func addFinderTags(_ tags: [String], to url: URL) -> Bool {
        let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        let merged = Array(NSOrderedSet(array: existing + tags)) as? [String] ?? existing + tags
        do { try (url as NSURL).setResourceValue(merged, forKey: .tagNamesKey); return true }
        catch { return false }
    }
}

// MARK: - Ansicht

struct TagView: View {
    @EnvironmentObject var tagger: TagRunner
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle().trim(from: 0, to: tagger.progress)
                    .stroke(AngularGradient(colors: [Theme.mint, Theme.orange, Theme.mint], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: tagger.progress)
                VStack(spacing: 4) {
                    Image(systemName: "tag.fill").font(.system(size: 24)).foregroundStyle(Theme.mint)
                    Text("\(Int(tagger.progress * 100)) %").font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("Clip \(min(tagger.index + 1, max(tagger.queue.count, 1))) von \(tagger.queue.count)")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 180, height: 180)

            Text(tagger.state == .finished ? "Verschlagworten fertig" :
                 tagger.state == .paused ? "Pausiert" : "Analysiere Clips (lokal, offline) …")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            if tagger.state == .running {
                Label(tagger.remainingText, systemImage: "clock")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mint)
            } else if tagger.state == .finished {
                Text("Dauer: \(ETA.duration(tagger.eta.elapsed))").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            if !tagger.currentFile.isEmpty {
                Text(tagger.currentFile).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle)
            }

            if !tagger.tagCounts.isEmpty {
                FlowChips(items: tagger.tagCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }, icon: "tag")
            }
            if !tagger.errors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tagger.errors, id: \.self) { Text("• " + $0).font(.system(size: 11)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.orange.opacity(0.12)))
            }

            Spacer(minLength: 0)

            if tagger.state == .running || tagger.state == .paused {
                HStack(spacing: 12) {
                    Button { tagger.state == .paused ? tagger.resume() : tagger.pause() } label: {
                        Label(tagger.state == .paused ? "Fortsetzen" : "Pause",
                              systemImage: tagger.state == .paused ? "play.fill" : "pause.fill")
                            .frame(width: 140, height: 40).background(Capsule().fill(Theme.orange))
                    }.buttonStyle(.plain)
                    Button { tagger.cancel() } label: {
                        Label("Abbrechen", systemImage: "stop.fill")
                            .frame(width: 140, height: 40).background(Capsule().fill(Color.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
                .font(.system(size: 14, weight: .semibold))
            } else {
                Text("Die Tags siehst du im Finder. In Final Cut beim Import „Finder-Tags als Schlagwörter“ anhaken.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                Button { tagger.close() } label: {
                    Text("Schließen").frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
            }
        }
    }
}
