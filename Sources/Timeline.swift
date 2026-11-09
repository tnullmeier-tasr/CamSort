import Foundation
import AVFoundation
import SwiftUI
import AppKit

/// Zeitleiste: alle Clips aus allen Unterordnern nach Aufnahmezeit – parallel gefilmte Clips werden gruppiert.
@MainActor
final class TimelineModel: ObservableObject {
    struct Clip: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        let camera: String
        let start: Date
        let end: Date
        let fromMetadata: Bool
    }
    struct Group: Identifiable {
        let id = UUID()
        let clips: [Clip]
        var start: Date { clips.map(\.start).min()! }
        var end: Date { clips.map(\.end).max()! }
        var cameras: [String] { Array(Set(clips.map(\.camera))).sorted() }
        var isParallel: Bool { cameras.count > 1 }
    }

    @Published var show = false
    @Published var loading = false
    @Published var groups: [Group] = []
    @Published var onlyParallel = false
    @Published var count = 0

    func open(folders: [URL]) {
        show = true; loading = true; groups = []
        Task {
            let clips = await Self.collect(folders)
            count = clips.count
            groups = Self.group(clips)
            loading = false
        }
    }

    nonisolated static func collect(_ folders: [URL]) async -> [Clip] {
        var urls: [URL] = []
        for base in folders {
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                if u.lastPathComponent == FolderNames.checkFolder { en.skipDescendants(); continue }
                if Sorter.videoExt.contains(u.pathExtension.lowercased()) { urls.append(u) }
            }
        }
        var out: [Clip] = []
        for u in urls {
            let asset = AVURLAsset(url: u)
            let dur = (try? await asset.load(.duration))?.seconds ?? 0
            var start: Date?
            var meta = false
            // Aufnahmezeit aus den Video-Metadaten (zuverlässiger als das Dateidatum)
            if let d = try? await asset.load(.creationDate), let v = try? await d.load(.dateValue) { start = v; meta = true }
            if start == nil {
                let rv = try? u.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                // Kameras schreiben beim Beenden der Aufnahme → Änderungsdatum minus Dauer ≈ Start
                if let m = rv?.contentModificationDate { start = m.addingTimeInterval(-(dur.isFinite ? dur : 0)) }
                else { start = rv?.creationDate }
            }
            guard let s = start else { continue }
            out.append(Clip(url: u, camera: camera(of: u), start: s, end: s.addingTimeInterval(max(1, dur.isFinite ? dur : 1)),
                            fromMetadata: meta))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Kamera = Ordner direkt unter „Videos“, sonst Elternordner
    nonisolated static func camera(of u: URL) -> String {
        // „Stabilisiert“ (neu: <Eltern>/Stabilisiert/<Ebene>, alt: <Ebene>/Stabilisiert) und „Original“ sind keine Kamera
        let c = u.pathComponents.filter { !FolderNames.isStabilizedFolder($0) && $0 != FolderNames.legacyOriginal }
        if let i = c.lastIndex(where: FolderNames.isVideos), i + 1 < c.count - 1 {
            let n = c[i + 1].components(separatedBy: FolderNames.separator).first ?? c[i + 1]
            return ["Hochkant", "Quer", "Quadratisch", FolderNames.square, "Stand", "Fahrt", "Dazwischen", "Ohne GPS"].contains(n) || FolderNames.isFpsFolder(n) ? "Kamera" : n
        }
        if c.contains(where: FolderNames.isVideos) { return "Kamera" }
        // ohne Videos-Sammelordner, zusammengesetzter Ordnername: <Dreh>/Sony · Quer/Clip → erster Teil
        if c.count >= 2, !FolderNames.isOrientation(c[c.count - 2]), FolderNames.hasOrientationPart(c[c.count - 2]) {
            let first = c[c.count - 2].components(separatedBy: FolderNames.separator).first ?? ""
            return first.isEmpty || FolderNames.isSceneFolder(first) ? "Kamera" : first
        }
        // Modus „Meine Kameraordner“: <Kamera>/[Zusatzebenen]/Hochkant|Quer/Clip
        if let i = c.dropLast().lastIndex(where: FolderNames.isOrientation), i > 0 {
            let d = UserDefaults.standard
            let extra: Set<String> = ["Stand", "Fahrt", "Dazwischen", "Ohne GPS", "Objektiv unbekannt",
                                      d.string(forKey: "lengthShort") ?? "Einblendungen", d.string(forKey: "lengthLong") ?? "Hauptspur"]
            var j = i - 1
            while j > 0 && c[j].components(separatedBy: FolderNames.separator).allSatisfy({ extra.contains($0) || FolderNames.isFpsFolder($0) || $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }) { j -= 1 }
            return c[j]
        }
        // Clip direkt im Projektordner: Projektname ist keine Kamera
        if FileManager.default.fileExists(atPath: u.deletingLastPathComponent().appendingPathComponent(Sorter.projectMarker).path) { return "Kamera" }
        return u.deletingLastPathComponent().lastPathComponent
    }

    /// Clips, deren Zeiten sich überschneiden (± 2 s Toleranz), bilden eine Gruppe.
    nonisolated static func group(_ clips: [Clip]) -> [Group] {
        var groups: [[Clip]] = []
        var curEnd = Date.distantPast
        for c in clips {
            if let last = groups.indices.last, c.start <= curEnd.addingTimeInterval(2) {
                groups[last].append(c); curEnd = max(curEnd, c.end)
            } else {
                groups.append([c]); curEnd = c.end
            }
        }
        return groups.map { Group(clips: $0) }
    }

    // MARK: Finder-Ansicht

    /// Legt im Ordner eine intelligente Finder-Suche „Alle Clips“ an (alle Videos aller Unterordner in einer Liste).
    static func makeSmartFolder(in folder: URL) -> URL? {
        let q = "(kMDItemContentTypeTree == \"public.movie\")"
        let plist: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": q,
            "RawQueryDict": ["FinderFilesOnly": true, "RawQuery": q, "SearchScopes": [folder.path], "UserFilesOnly": true],
            "SearchCriteria": ["CurrentFolderPath": [folder.path], "FXScope": 0],
            "ViewSettings": ["ViewStyle": "Nlsv", "SortColumn": "kMDItemContentCreationDate"],
        ]
        let url = folder.appendingPathComponent("Alle Clips nach Zeit.savedSearch")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: - Ansicht

struct TimelineSheet: View {
    @EnvironmentObject var tl: TimelineModel
    @EnvironmentObject var sorter: Sorter
    @Environment(\.dismiss) private var dismiss
    @State private var smartMsg = ""

    private let dayF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM yyyy"; return f }()
    private let timeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    private var shown: [TimelineModel.Group] { tl.onlyParallel ? tl.groups.filter(\.isParallel) : tl.groups }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Zeitleiste", systemImage: "clock.arrow.2.circlepath").font(.title2.bold())
                Spacer()
                HelpButton(title: "Zeitleiste",
                           text: "Zeigt alle Clips aus allen Unterordnern nach Aufnahmezeit – egal, in welchem Kamera- oder Hochkant/Quer-Ordner sie liegen. Clips, die sich zeitlich überschneiden, stehen zusammen in einem Block. Kommen sie von verschiedenen Kameras, ist der Block grün markiert: „Parallel gefilmt“.\n\nDoppelklick auf einen Clip zeigt ihn im Finder.\n\n„Finder-Ansicht anlegen“ erstellt im Ordner eine intelligente Suche „Alle Clips nach Zeit“: alle Videos in einer Liste, im Finder nach Datum sortierbar.")
            }
            HStack {
                Toggle("Nur parallel gefilmte zeigen", isOn: $tl.onlyParallel).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Text("\(tl.count) Clips · \(tl.groups.filter(\.isParallel).count) parallel-Blöcke")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if tl.loading {
                HStack { ProgressView().controlSize(.small); Text("Lese Aufnahmezeiten …") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, g in
                            if i == 0 || !Calendar.current.isDate(shown[i - 1].start, inSameDayAs: g.start) {
                                Text(dayF.string(from: g.start)).font(.system(size: 13, weight: .bold)).padding(.top, 6)
                            }
                            GroupCard(group: g, timeF: timeF)
                        }
                    }
                }
            }
            HStack {
                Button("Finder-Ansicht anlegen") {
                    if let f = sorter.folders.first, let u = TimelineModel.makeSmartFolder(in: f) {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                        smartMsg = "„Alle Clips nach Zeit“ liegt jetzt im Ordner"
                    }
                }
                if !smartMsg.isEmpty { Text(smartMsg).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 680)
    }
}

private struct GroupCard: View {
    let group: TimelineModel.Group
    let timeF: DateFormatter
    private let palette: [Color] = [Theme.mint, Theme.orange, Color(red: 0.6, green: 0.7, blue: 1), .pink, .yellow, .purple]

    var body: some View {
        let cams = group.cameras
        let span = max(1, group.end.timeIntervalSince(group.start))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(timeF.string(from: group.start)) – \(timeF.string(from: group.end))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if group.isParallel {
                    Label("Parallel gefilmt · \(cams.count) Kameras", systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.mint.opacity(0.25)))
                }
                Spacer()
            }
            ForEach(group.clips) { c in
                let color = palette[(cams.firstIndex(of: c.camera) ?? 0) % palette.count]
                HStack(spacing: 8) {
                    Text(c.camera).font(.system(size: 11, weight: .semibold)).frame(width: 120, alignment: .leading).lineLimit(1)
                    // Balken: Lage innerhalb des Blocks
                    GeometryReader { geo in
                        let x = CGFloat(c.start.timeIntervalSince(group.start) / span) * geo.size.width
                        let w = max(4, CGFloat(c.end.timeIntervalSince(c.start) / span) * geo.size.width)
                        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: w, height: 10).offset(x: x, y: 3)
                    }
                    .frame(height: 16)
                    Text(c.url.lastPathComponent).font(.system(size: 11, design: .monospaced)).frame(width: 150, alignment: .leading)
                        .lineLimit(1).truncationMode(.middle)
                    Text(timeF.string(from: c.start)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    if !c.fromMetadata { Image(systemName: "questionmark.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Zeit aus dem Dateidatum geschätzt (keine Aufnahmezeit in den Metadaten)") }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
                .help(c.url.path)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(group.isParallel ? Theme.mint.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(group.isParallel ? Theme.mint.opacity(0.6) : .clear))
    }
}
