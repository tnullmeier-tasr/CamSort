import Foundation
import AVFoundation
import AVKit
import SwiftUI
import AppKit

/// Verlustfreies Drehen: Es wird NUR die Dreh-Angabe (36 Byte im MP4/MOV-Kopf) geändert.
/// Bild, Ton, Gyro-/Metadaten-Spuren (Sony rtmd, GoPro GPMF, DJI …) bleiben bitgenau erhalten.
/// Viermal drehen ergibt wieder exakt die Originaldatei.
enum LosslessRotate {
    enum Err: LocalizedError {
        case notMP4, noVideoTrack, io(String)
        var errorDescription: String? {
            switch self {
            case .notMP4: return "Kein MP4/MOV-Aufbau gefunden"
            case .noVideoTrack: return "Keine Videospur gefunden"
            case .io(let s): return s
            }
        }
    }

    /// Dreht um +90° (rechts) oder −90° (links).
    /// beforeWrite: bekommt Position und bisherige 36 Byte der Matrix, BEVOR geschrieben wird (für das Bewegungsprotokoll).
    static func rotate(_ url: URL, clockwise: Bool, beforeWrite: ((UInt64, Data) -> Void)? = nil) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fh = try FileHandle(forUpdating: url)
        var closed = false
        defer { if !closed { try? fh.close() } }
        let size = try fh.seekToEnd()

        // 1) moov suchen (darf am Anfang oder Ende liegen)
        var off: UInt64 = 0
        var moov: (UInt64, UInt64)?
        while off + 8 <= size {
            try fh.seek(toOffset: off)
            guard let h = try fh.read(upToCount: 16), h.count >= 8 else { break }
            var boxSize = UInt64(be32(h, 0))
            let type = String(bytes: h[4..<8], encoding: .ascii) ?? ""
            var header: UInt64 = 8
            if boxSize == 1, h.count >= 16 { boxSize = be64(h, 8); header = 16 }
            if boxSize == 0 { boxSize = size - off }
            guard boxSize >= header else { throw Err.notMP4 }
            if type == "moov" { moov = (off, boxSize); break }
            off += boxSize
        }
        guard let (moovOff, moovSize) = moov, moovSize < 512 * 1024 * 1024 else { throw Err.notMP4 }
        try fh.seek(toOffset: moovOff)
        guard let m = try fh.read(upToCount: Int(moovSize)) else { throw Err.notMP4 }

        // 2) Videospur (hdlr = vide) und ihr tkhd finden
        guard let tkhdPos = findVideoTkhd(in: m, from: 8, to: m.count) else { throw Err.noVideoTrack }
        let version = m[tkhdPos + 8]
        let matrixPos = tkhdPos + (version == 1 ? 60 : 48)
        let dimPos = matrixPos + 36
        guard dimPos + 8 <= m.count else { throw Err.notMP4 }
        let a = Int32(bitPattern: be32(m, matrixPos)), b = Int32(bitPattern: be32(m, matrixPos + 4))
        let w = Int32(bitPattern: be32(m, dimPos)), h = Int32(bitPattern: be32(m, dimPos + 4))

        // aktuelle Drehung bestimmen und um 90° weiterdrehen
        let current: Int = (a > 0 && b == 0) ? 0 : (a == 0 && b > 0) ? 90 : (a < 0 && b == 0) ? 180 : (a == 0 && b < 0) ? 270 : 0
        let next = (current + (clockwise ? 90 : 270)) % 360
        let one: Int32 = 0x10000, wOne: Int32 = 0x4000_0000
        let mtx: [Int32]
        switch next {
        case 90:  mtx = [0, one, 0, -one, 0, 0, h, 0, wOne]
        case 180: mtx = [-one, 0, 0, 0, -one, 0, w, h, wOne]
        case 270: mtx = [0, -one, 0, one, 0, 0, 0, w, wOne]
        default:  mtx = [one, 0, 0, 0, one, 0, 0, 0, wOne]
        }
        var bytes = Data()
        for v in mtx { var be = UInt32(bitPattern: v).bigEndian; bytes.append(Data(bytes: &be, count: 4)) }

        // 3) nur diese 36 Byte überschreiben (alte Werte vorher ins Protokoll)
        let oldBytes = m.subdata(in: (m.startIndex + matrixPos)..<(m.startIndex + matrixPos + 36))
        beforeWrite?(moovOff + UInt64(matrixPos), oldBytes)
        try fh.seek(toOffset: moovOff + UInt64(matrixPos))
        try fh.write(contentsOf: bytes)
        try fh.synchronize()
        try fh.close(); closed = true
        // Datum unverändert lassen (wichtig für Zeitleiste/Sortierung)
        if let md = attrs[.modificationDate] { try? FileManager.default.setAttributes([.modificationDate: md], ofItemAtPath: url.path) }
    }

    /// Rückgängig: die protokollierten 36 Byte wieder an ihre Stelle schreiben (Datum bleibt).
    static func restore(_ url: URL, offset: UInt64, bytes: Data) throws {
        guard bytes.count == 36 else { throw Err.io("Protokoll-Eintrag unvollständig") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        guard offset + 36 <= size else { throw Err.io("Datei ist kürzer als erwartet") }
        try fh.seek(toOffset: offset)
        try fh.write(contentsOf: bytes)
        try fh.synchronize()
        if let md = attrs[.modificationDate] { try? FileManager.default.setAttributes([.modificationDate: md], ofItemAtPath: url.path) }
    }

    private static func findVideoTkhd(in d: Data, from: Int, to: Int) -> Int? {
        var p = from
        while p + 8 <= to {
            let sz = Int(be32(d, p)); let type = String(bytes: d[(d.startIndex + p + 4)..<(d.startIndex + p + 8)], encoding: .ascii) ?? ""
            guard sz >= 8, p + sz <= to else { return nil }
            if type == "trak" {
                var tkhd: Int?; var isVideo = false
                var q = p + 8
                while q + 8 <= p + sz {
                    let s2 = Int(be32(d, q)); let t2 = String(bytes: d[(d.startIndex + q + 4)..<(d.startIndex + q + 8)], encoding: .ascii) ?? ""
                    guard s2 >= 8 else { break }
                    if t2 == "tkhd" { tkhd = q }
                    if t2 == "mdia" { isVideo = handlerIsVideo(d, q + 8, q + s2) }
                    q += s2
                }
                if isVideo, let t = tkhd { return t }
            }
            p += sz
        }
        return nil
    }

    private static func handlerIsVideo(_ d: Data, _ from: Int, _ to: Int) -> Bool {
        var p = from
        while p + 8 <= to {
            let sz = Int(be32(d, p)); let type = String(bytes: d[(d.startIndex + p + 4)..<(d.startIndex + p + 8)], encoding: .ascii) ?? ""
            guard sz >= 8 else { return false }
            if type == "hdlr", p + 20 <= to {
                return String(bytes: d[(d.startIndex + p + 16)..<(d.startIndex + p + 20)], encoding: .ascii) == "vide"
            }
            p += sz
        }
        return false
    }

    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        let s = d.startIndex + i
        return UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3])
    }
    private static func be64(_ d: Data, _ i: Int) -> UInt64 { UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4)) }
}

// MARK: - Vorschau & Drehen

@MainActor
final class ClipBrowser: ObservableObject {
    struct Item: Identifiable, Hashable { let id = UUID(); let url: URL }
    @Published var show = false
    @Published var items: [Item] = []
    @Published var thumbs: [URL: NSImage] = [:]
    @Published var selected: Item?
    @Published var player = AVPlayer()
    @Published var message = ""
    /// Protokoll der Drehungen dieser Sitzung (Rückgängig über Einstellungen › Letzte Läufe)
    private var journal: RunJournal?

    func open(folders: [URL]) {
        items = TagRunner.collectVideos(folders).map { Item(url: $0) }
        if items.isEmpty { items = Self.allVideos(folders).map { Item(url: $0) } }
        thumbs = [:]; selected = items.first; message = ""
        show = true
        if let s = selected { select(s) }
        Task { for i in items { await loadThumb(i.url) } }
    }

    static func allVideos(_ folders: [URL]) -> [URL] {
        var out: [URL] = []
        for b in folders {
            guard let en = FileManager.default.enumerator(at: b, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            while let u = en.nextObject() as? URL { if Sorter.videoExt.contains(u.pathExtension.lowercased()) { out.append(u) } }
        }
        return out.sorted { $0.path < $1.path }
    }

    func select(_ i: Item) {
        selected = i
        player.replaceCurrentItem(with: AVPlayerItem(url: i.url))
    }

    func loadThumb(_ u: URL) async {
        let img: NSImage? = await Task.detached {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 320, height: 320)
            guard let cg = try? await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { thumbs[u] = img }
    }

    func rotate(clockwise: Bool) async {
        guard let s = selected else { return }
        if await GyroRunner.videoOrientation(s.url) == FolderNames.square {
            message = "\(s.url.lastPathComponent) ist quadratisch – Drehen ändert am Format nichts. Hochkant oder Quer schneidest du später im Schnitt aus dem Quadrat."
            return
        }
        player.replaceCurrentItem(with: nil)
        do {
            if journal == nil { journal = RunJournal(title: "Drehen", bases: []) }
            let j = journal
            let url = s.url
            var planned = 0
            try LosslessRotate.rotate(url, clockwise: clockwise) { off, old in
                planned = j?.plan("drehen", url, nil, size: Int64(off), data: old.base64EncodedString()) ?? 0
            }
            if planned > 0 { j?.done(planned) }
            message = "\(s.url.lastPathComponent) gedreht – verlustfrei, alle Daten (auch Gyro) bleiben erhalten. „Aktualisieren“ sortiert ihn danach in den passenden Ordner."
        } catch {
            message = "Drehen nicht möglich: \(error.localizedDescription). Die Datei ist unverändert."
        }
        select(s)
        Task { await loadThumb(s.url) }
    }
}

struct ClipBrowserSheet: View {
    @EnvironmentObject var cb: ClipBrowser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Clips ansehen & drehen", systemImage: "rotate.right").font(.title2.bold())
                Spacer()
                HelpButton(title: "Verlustfrei drehen",
                           text: "Wähle einen Clip, prüfe ihn in der Vorschau und dreh ihn mit ↺ oder ↻ um 90°.\n\nCamSort ändert dabei nur die Dreh-Angabe im Dateikopf – genau wie die Kamera sie schreibt. Bild und Ton werden nicht neu berechnet, Gyro-Daten für Gyroflow, Zeitstempel und alle anderen Metadaten bleiben bitgenau erhalten. Viermal drehen ergibt wieder exakt die Originaldatei.\n\nDanach „Aktualisieren“, dann wandert der Clip in den passenden Hochkant-/Quer-Ordner.")
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    VideoPlayer(player: cb.player)
                        .frame(width: 400, height: 300)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(cb.selected?.url.lastPathComponent ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    HStack(spacing: 10) {
                        Button { Task { await cb.rotate(clockwise: false) } } label: { Label("Links drehen", systemImage: "rotate.left") }
                        Button { Task { await cb.rotate(clockwise: true) } } label: { Label("Rechts drehen", systemImage: "rotate.right") }
                        Button { if let u = cb.selected?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } } label: {
                            Image(systemName: "folder") }.help("Im Finder zeigen")
                    }
                    .controlSize(.large)
                    .disabled(cb.selected == nil)
                    if !cb.message.isEmpty {
                        Text(cb.message).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 400, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(cb.items) { i in
                            VStack(spacing: 3) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
                                    if let t = cb.thumbs[i.url] { Image(nsImage: t).resizable().scaledToFit() }
                                    else { ProgressView().controlSize(.small) }
                                }
                                .frame(width: 96, height: 72)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(cb.selected == i ? Color.accentColor : .clear, lineWidth: 3))
                                Text(i.url.lastPathComponent).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                            }
                            .onTapGesture { cb.select(i) }
                        }
                    }
                }
            }
            HStack { Text("\(cb.items.count) Clips").font(.system(size: 11)).foregroundStyle(.secondary); Spacer()
                Button("Schließen") { cb.player.pause(); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 820, height: 560)
    }
}
