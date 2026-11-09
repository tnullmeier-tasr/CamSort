import Foundation

// MARK: - Bewegungsprotokoll
//
// Jede Dateioperation von CamSort (Verschieben, Ordner anlegen, Umbenennen, leeren Ordner löschen, Papierkorb,
// Markierungsdatei schreiben, Drehen) wird VOR der Ausführung als „geplant“ und DANACH als „erledigt“ bzw. „fehler“
// protokolliert. Eine Zeile = ein JSON-Objekt (JSON Lines). Jede Zeile wird sofort angehängt und mit fsync auf die
// Platte geschrieben – nach Absturz oder Stromausfall ist der Stand bis zur letzten Zeile nachvollziehbar.
//
// Zwei Kopien je Lauf:
//  1. ~/Library/Application Support/CamSort/Protokolle/<Datum Uhrzeit>.json – absolute Pfade, alle Ordner des Laufs
//  2. <eingeworfener Ordner>/.camsort-protokoll/<Datum Uhrzeit>.json – Pfade RELATIV zum Ordner, nur dessen Schritte.
//     Funktioniert dadurch auch nach Umbenennen, Verschieben auf eine andere Platte oder an einem anderen Mac.

struct JournalLine: Codable {
    var n: Int
    var art: String            // lauf, verschieben, umbenennen, umbenennen-basis, ordner-anlegen, ordner-loeschen, papierkorb, markierung, drehen, rueckgaengig
    var status: String         // geplant, erledigt, fehler, info, teilweise
    var quelle: String? = nil
    var ziel: String? = nil
    var groesse: Int64? = nil
    var zeit: Date = Date()
    var daten: String? = nil   // Base64: vorheriger Inhalt einer Markierungsdatei bzw. die alten 36 Byte der Dreh-Matrix
    var text: String? = nil
    var ordner: [String]? = nil
}

enum JournalIO {
    static let folderDirName = ".camsort-protokoll"

    static var appDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CamSort/Protokolle")
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }

    static func read(_ url: URL) -> [JournalLine] {
        guard let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        // eine beim Absturz halb geschriebene letzte Zeile wird einfach übersprungen
        return s.split(separator: "\n").compactMap { try? dec.decode(JournalLine.self, from: Data($0.utf8)) }
    }

    /// Eine Zeile anhängen und sofort auf die Platte schreiben
    static func append(_ line: JournalLine, to h: FileHandle) {
        guard var d = try? encoder().encode(line) else { return }
        d.append(0x0A)
        do { _ = try h.seekToEnd(); try h.write(contentsOf: d); try h.synchronize() } catch {}
    }

    static func append(_ line: JournalLine, toFile url: URL) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        append(line, to: h)
    }

    static func openNew(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { return nil }
        guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: d)
    }
}

/// Protokoll eines Laufs (Schreiber). Dateien werden erst beim ersten Schritt angelegt – Läufe ohne Änderung hinterlassen nichts.
/// Bewusst ohne Actor-Bindung: wird nur vom Hauptthread benutzt (Sorter, ClipBrowser), auch aus synchronen Rückrufen.
final class RunJournal {
    let name: String
    let title: String
    let appURL: URL
    private var appHandle: FileHandle?
    private var bases: [URL]
    private var baseHandles: [String: FileHandle] = [:]   // Schlüssel: Pfad zum Zeitpunkt des Öffnens
    private var baseKeyOf: [Int: String] = [:]
    private var baseURLOfKey: [String: URL] = [:]
    private var seq = 0
    /// Anzahl protokollierter (geplanter) Schritte
    private(set) var count = 0
    private(set) var failedToOpen = false

    init(title: String, bases: [URL]) {
        var s = JournalIO.stamp()
        var u = JournalIO.appDir.appendingPathComponent(s + ".json")
        var i = 2
        while FileManager.default.fileExists(atPath: u.path) { s = JournalIO.stamp() + " (\(i))"; u = JournalIO.appDir.appendingPathComponent(s + ".json"); i += 1 }
        name = s + ".json"; appURL = u; self.title = title
        self.bases = bases.map { $0.standardizedFileURL }
    }

    var isEmpty: Bool { count == 0 }

    private func header() -> JournalLine {
        JournalLine(n: 0, art: "lauf", status: "info", text: title, ordner: bases.map(\.path))
    }

    private func ensureApp() -> FileHandle? {
        if let h = appHandle { return h }
        guard let h = JournalIO.openNew(appURL) else { failedToOpen = true; return nil }
        appHandle = h
        JournalIO.append(header(), to: h)
        return h
    }

    /// Längster gewählter Ordner, der `u` enthält (oder `u` selbst ist)
    private func base(for u: URL) -> URL? {
        let p = u.standardizedFileURL.path
        return bases.filter { p == $0.path || p.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    private func baseHandle(_ b: URL) -> (String, FileHandle)? {
        let key = b.path
        if let h = baseHandles[key] { return (key, h) }
        // erst öffnen, wenn es den Ordner wirklich gibt (die Kopie im Ordner ist eine Zugabe – fehlt sie, bleibt das App-Protokoll)
        guard FileManager.default.fileExists(atPath: b.path),
              let h = JournalIO.openNew(b.appendingPathComponent(JournalIO.folderDirName).appendingPathComponent(name)) else { return nil }
        var hd = header(); hd.ordner = [b.lastPathComponent]
        JournalIO.append(hd, to: h)
        baseHandles[key] = h; baseURLOfKey[key] = b
        return (key, h)
    }

    private func rel(_ u: URL?, _ b: URL) -> String? {
        guard let u else { return nil }
        let p = u.standardizedFileURL.path
        if p == b.path { return "" }
        if p.hasPrefix(b.path + "/") { return String(p.dropFirst(b.path.count + 1)) }
        return p   // außerhalb (z. B. Papierkorb) → absolut
    }

    /// Schritt VOR der Ausführung protokollieren. Rückgabe: Nummer für done/fail.
    @discardableResult
    func plan(_ art: String, _ src: URL?, _ dst: URL?, size: Int64? = nil, data: String? = nil) -> Int {
        seq += 1; count += 1
        let line = JournalLine(n: seq, art: art, status: "geplant", quelle: src?.standardizedFileURL.path, ziel: dst?.standardizedFileURL.path, groesse: size, daten: data)
        if let h = ensureApp() { JournalIO.append(line, to: h) }
        if let b = base(for: src ?? dst ?? URL(fileURLWithPath: "/")), let kh = baseHandle(b) {
            let key = kh.0, h = kh.1
            baseKeyOf[seq] = key
            var l = line
            if art == "umbenennen", let s = src, s.standardizedFileURL.path == b.path {
                l.art = "umbenennen-basis"; l.quelle = s.lastPathComponent; l.ziel = dst?.lastPathComponent
            } else {
                l.quelle = rel(src, b); l.ziel = rel(dst, b)
            }
            JournalIO.append(l, to: h)
        }
        return seq
    }

    func done(_ n: Int, dst: URL? = nil) { finish(n, status: "erledigt", dst: dst, text: nil) }
    func fail(_ n: Int, _ text: String) { finish(n, status: "fehler", dst: nil, text: text) }

    private func finish(_ n: Int, status: String, dst: URL?, text: String?) {
        let line = JournalLine(n: n, art: "", status: status, ziel: dst?.standardizedFileURL.path, text: text)
        if let h = appHandle { JournalIO.append(line, to: h) }
        if let key = baseKeyOf[n], let h = baseHandles[key], let b = baseURLOfKey[key] {
            var l = line; l.ziel = rel(dst, b)
            JournalIO.append(l, to: h)
        }
    }

    /// Ein gewählter Ordner wurde umbenannt – folgende Schritte relativ zum neuen Pfad
    func rebase(from old: URL, to new: URL) {
        let o = old.standardizedFileURL.path, nw = new.standardizedFileURL
        bases = bases.map { b in
            if b.path == o { return nw }
            if b.path.hasPrefix(o + "/") { return URL(fileURLWithPath: nw.path + String(b.path.dropFirst(o.count))) }
            return b
        }
        for (k, b) in baseURLOfKey {
            if b.path == o { baseURLOfKey[k] = nw }
            else if b.path.hasPrefix(o + "/") { baseURLOfKey[k] = URL(fileURLWithPath: nw.path + String(b.path.dropFirst(o.count))) }
        }
        // offene Handles bleiben gültig (Datei-Deskriptor überlebt das Umbenennen); neue Zuordnung über den neuen Pfad
        var nh: [String: FileHandle] = [:], nu: [String: URL] = [:], nk: [Int: String] = [:]
        for (k, h) in baseHandles { let u = baseURLOfKey[k] ?? URL(fileURLWithPath: k); nh[u.path] = h; nu[u.path] = u }
        for (n, k) in baseKeyOf { nk[n] = baseURLOfKey[k]?.path ?? k }
        baseHandles = nh; baseURLOfKey = nu; baseKeyOf = nk
    }

    func close() {
        try? appHandle?.close(); appHandle = nil
        for h in baseHandles.values { try? h.close() }
        baseHandles = [:]
    }
}

// MARK: - Läufe auflisten

struct RunInfo: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    /// Wurzel für relative Pfade (Ordner-Kopie) bzw. "/" (App-Protokoll)
    let root: URL
    let date: Date
    let title: String
    let folders: [String]
    let files: Int
    let undone: Bool
    let partial: Bool
}

enum JournalStore {
    static func info(_ url: URL, root: URL) -> RunInfo? {
        let lines = JournalIO.read(url)
        guard let head = lines.first(where: { $0.art == "lauf" }) else { return nil }
        let items = UndoEngine.items(lines)
        let files = items.filter { ["verschieben", "drehen"].contains($0.art) && $0.state != .failed }.count
        let undone = lines.contains { $0.art == "rueckgaengig" && $0.status == "erledigt" }
        let partial = !undone && lines.contains { $0.art == "rueckgaengig" }
        return RunInfo(url: url, root: root, date: head.zeit, title: head.text ?? "", folders: head.ordner ?? [], files: files, undone: undone, partial: partial)
    }

    /// Alle Läufe aus Application Support, neuester zuerst
    static func appRuns() -> [RunInfo] {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: JournalIO.appDir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        return urls.compactMap { info($0, root: URL(fileURLWithPath: "/")) }.sorted { $0.date > $1.date }
    }

    /// Läufe, deren Protokoll im Ordner selbst liegt (unsichtbar), neuester zuerst
    static func folderRuns(_ folder: URL) -> [RunInfo] {
        let dir = folder.appendingPathComponent(JournalIO.folderDirName)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        return urls.compactMap { info($0, root: folder) }.filter { $0.files > 0 || $0.undone }.sorted { $0.date > $1.date }
    }

    /// Rückgängig nur in umgekehrter Reihenfolge: erlaubt, wenn kein jüngerer, nicht rückgängig gemachter Lauf denselben Ordner betrifft
    static func canUndo(_ r: RunInfo, among all: [RunInfo]) -> Bool {
        guard !r.undone else { return false }
        let mine = Set(r.folders)
        return !all.contains { o in o.date > r.date && !o.undone && o.files > 0 && (mine.isEmpty || !mine.isDisjoint(with: o.folders)
                                || o.folders.contains { f in mine.contains { f.hasPrefix($0 + "/") || $0.hasPrefix(f + "/") } }) }
    }
}

// MARK: - Rückgängig

struct UndoReport {
    var restored = 0
    var removedDirs = 0
    var skipped: [String] = []
    var fcpLibraries: [URL] = []
    var newRoot: URL? = nil
}

enum UndoEngine {
    enum State { case done, failed, unknown }
    struct Item {
        let n: Int
        let art: String
        let src: String?
        let dst: String?
        let size: Int64?
        let data: String?
        let state: State
    }

    static func items(_ lines: [JournalLine]) -> [Item] {
        var planned: [Int: JournalLine] = [:]
        var fin: [Int: JournalLine] = [:]
        for l in lines where l.n > 0 {
            if l.status == "geplant" { planned[l.n] = l } else if l.status == "erledigt" || l.status == "fehler" { fin[l.n] = l }
        }
        return planned.keys.sorted().compactMap { n in
            guard let p = planned[n] else { return nil }
            let f = fin[n]
            let st: State = f == nil ? .unknown : (f!.status == "erledigt" ? .done : .failed)
            return Item(n: n, art: p.art, src: p.quelle, dst: f?.ziel ?? p.ziel,
                        size: p.groesse, data: p.daten, state: st)
        }
    }

    static func resolve(_ s: String?, _ root: URL) -> URL? {
        guard let s else { return nil }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        if s.isEmpty { return root }
        return root.appendingPathComponent(s)
    }

    /// Wie viele Dateien gingen zurück? (für die Bestätigung)
    static func preview(_ url: URL) -> Int {
        items(JournalIO.read(url)).filter { ($0.art == "verschieben" || $0.art == "drehen") && $0.state != .failed }.count
    }

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    /// Macht einen Lauf rückgängig. Nie überschreiben: liegt eine Datei nicht mehr am Ziel oder ist der Ursprung belegt → überspringen und melden.
    static func run(_ file: URL, root startRoot: URL) -> UndoReport {
        let fm = FileManager.default
        var r = UndoReport()
        var root = startRoot
        let all = items(JournalIO.read(file))
        for it in all.reversed() where it.state != .failed {
            switch it.art {
            case "verschieben", "umbenennen":
                guard let s = resolve(it.src, root), let d = resolve(it.dst, root) else { continue }
                if !exists(d) {
                    if it.state == .done { r.skipped.append("\(d.lastPathComponent): liegt nicht mehr an \(d.deletingLastPathComponent().path) – übersprungen") }
                    continue
                }
                if exists(s) {
                    if it.state == .done { r.skipped.append("\(s.lastPathComponent): am Ursprungsort liegt schon etwas – nichts überschrieben") }
                    continue
                }
                if let sz = it.size, sz >= 0, it.art == "verschieben", Safety.itemSize(d) != sz {
                    r.skipped.append("\(d.lastPathComponent): Größe hat sich seitdem geändert – bleibt, wo sie ist"); continue
                }
                do {
                    try fm.createDirectory(at: s.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: d, to: s)
                } catch { r.skipped.append("\(d.lastPathComponent): konnte nicht zurück (\(error.localizedDescription))"); continue }
                guard exists(s) && !exists(d) else { r.skipped.append("\(s.lastPathComponent): Prüfung nach dem Zurücklegen fehlgeschlagen"); continue }
                if it.art == "verschieben" { r.restored += 1 }
                if s.pathExtension.lowercased() == "fcpbundle" { r.fcpLibraries.append(s) }
                if it.art == "umbenennen" && startRoot.path == "/" { r.newRoot = s }
            case "umbenennen-basis":
                guard let old = it.src, let new = it.dst, !old.isEmpty else { continue }
                if root.lastPathComponent == new {
                    let target = root.deletingLastPathComponent().appendingPathComponent(old)
                    if exists(target) { r.skipped.append("Ordner „\(new)“: „\(old)“ gibt es dort schon – Name bleibt"); continue }
                    do { try fm.moveItem(at: root, to: target); root = target; r.newRoot = target }
                    catch { r.skipped.append("Ordner „\(new)“ konnte nicht zurückbenannt werden (\(error.localizedDescription))") }
                } else if it.state == .done {
                    r.skipped.append("Ordner heißt inzwischen „\(root.lastPathComponent)“ – Name bleibt")
                }
            case "ordner-anlegen":
                guard let d = resolve(it.dst, root) else { continue }
                if Safety.removeIfEmptyDir(d) { r.removedDirs += 1 }
            case "ordner-loeschen":
                guard let s = resolve(it.src, root), !exists(s) else { continue }
                try? fm.createDirectory(at: s, withIntermediateDirectories: true)
            case "papierkorb":
                guard it.state == .done, let s = resolve(it.src, root), let d = resolve(it.dst, root) else {
                    if it.state == .unknown, let s = it.src { r.skipped.append("\((s as NSString).lastPathComponent): evtl. im Papierkorb – bitte dort prüfen") }
                    continue
                }
                if exists(d) && !exists(s) {
                    do { try fm.moveItem(at: d, to: s) } catch { r.skipped.append("\(s.lastPathComponent): aus dem Papierkorb nicht zurückholbar") }
                } else { r.skipped.append("\(s.lastPathComponent): nicht aus dem Papierkorb zurückgeholt (fehlt dort oder Platz belegt)") }
            case "markierung":
                guard let s = resolve(it.src, root) else { continue }
                if let b = it.data, let old = Data(base64Encoded: b) { try? old.write(to: s, options: .atomic) }
                else if s.lastPathComponent.hasPrefix(".camsort-") && exists(s) { try? fm.removeItem(at: s) }   // nur CamSorts eigene, unsichtbare Markierung
            case "drehen":
                guard let s = resolve(it.src, root), let off = it.size, let b = it.data, let old = Data(base64Encoded: b) else { continue }
                if !exists(s) { r.skipped.append("\(s.lastPathComponent): Drehen nicht zurückgesetzt – Datei liegt nicht mehr dort"); continue }
                do { try LosslessRotate.restore(s, offset: UInt64(off), bytes: old); r.restored += 1 }
                catch { r.skipped.append("\(s.lastPathComponent): Drehung nicht zurückgesetzt (\(error.localizedDescription))") }
            default: break
            }
        }
        return r
    }

    /// Protokoll als rückgängig gemacht markieren (nie löschen)
    static func mark(_ file: URL, _ r: UndoReport) {
        let line = JournalLine(n: 0, art: "rueckgaengig", status: r.skipped.isEmpty ? "erledigt" : "teilweise",
                               text: "\(r.restored) zurückgelegt, \(r.skipped.count) übersprungen")
        JournalIO.append(line, toFile: file)
    }
}

// MARK: - Sicherheits-Hilfen

enum Safety {
    /// Volume-Kennung; bei nicht existierendem Pfad die des nächsten existierenden Elternordners
    static func volumeID(_ u: URL) -> NSObjectProtocol? {
        var cur = u.standardizedFileURL
        while !FileManager.default.fileExists(atPath: cur.path) {
            let p = cur.deletingLastPathComponent()
            if p.path == cur.path { return nil }
            cur = p
        }
        return (try? cur.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObjectProtocol
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = volumeID(a), let y = volumeID(b) else { return false }
        return x.isEqual(y)
    }

    /// Größe in Byte; Ordner/Pakete (z. B. .fcpbundle) = Summe aller enthaltenen Dateien
    static func itemSize(_ u: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return -1 }
        if !isDir.boolValue { return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var sum: Int64 = 0
        if let en = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
            while let f = en.nextObject() as? URL {
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { sum += Int64(v.fileSize ?? 0) }
            }
        }
        return sum
    }

    /// Zeigen zwei Pfade auf dieselbe Datei? (z. B. nur Groß/Klein anders auf APFS ohne Groß/Klein-Unterscheidung)
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let x = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObjectProtocol,
              let y = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObjectProtocol else { return false }
        return x.isEqual(y)
    }

    /// Leerer Ordner (höchstens .DS_Store)? Nie eine Datei.
    static func isEmptyDir(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: u.path) else { return false }
        return items.allSatisfy { $0 == ".DS_Store" }
    }

    /// Entfernt `u` nur, wenn es ein leerer Ordner ist (für Rückgängig; im Lauf geht das über Sorter.removeEmptyDir mit Protokoll)
    @discardableResult
    static func removeIfEmptyDir(_ u: URL) -> Bool {
        guard isEmptyDir(u) else { return false }
        return (try? FileManager.default.removeItem(at: u)) != nil
    }

    /// Liegt der Ordner auf einer Speicherkarte / einem Wechseldatenträger?
    static func isMemoryCard(_ u: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeURLKey, .volumeIsRootFileSystemKey]
        guard let v = try? u.resourceValues(forKeys: keys) else { return false }
        if v.volumeIsRootFileSystem == true { return false }
        if v.volumeIsRemovable == true { return true }
        guard let root = v.volume else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("DCIM").path) || fm.fileExists(atPath: root.appendingPathComponent("PRIVATE").path)
    }
}

// MARK: - Rückgängig ausführen und markieren

enum UndoService {
    /// Lauf aus dem App-Protokoll (absolute Pfade) rückgängig machen; Kopien in den Ordnern ebenfalls markieren.
    static func undoApp(_ file: URL) -> UndoReport {
        let lines = JournalIO.read(file)
        let r = UndoEngine.run(file, root: URL(fileURLWithPath: "/"))
        UndoEngine.mark(file, r)
        // Ordner-Kopien: ursprünglicher Pfad (nach dem Zurückbenennen wieder gültig) oder neuer Name
        var cands = lines.first(where: { $0.art == "lauf" })?.ordner ?? []
        cands += lines.filter { $0.art == "umbenennen" }.compactMap(\.ziel)
        for c in Set(cands) {
            let u = URL(fileURLWithPath: c).appendingPathComponent(JournalIO.folderDirName).appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: u.path) { UndoEngine.mark(u, r) }
        }
        return r
    }

    /// Lauf aus dem Protokoll im Ordner (relative Pfade) rückgängig machen – auch nach Umbenennen/Verschieben des Ordners.
    static func undoFolder(_ info: RunInfo) -> UndoReport {
        let r = UndoEngine.run(info.url, root: info.root)
        let root = r.newRoot ?? info.root
        let file = root.appendingPathComponent(JournalIO.folderDirName).appendingPathComponent(info.url.lastPathComponent)
        UndoEngine.mark(FileManager.default.fileExists(atPath: file.path) ? file : info.url, r)
        // App-Protokoll mitmarkieren, wenn der Lauf nur diesen Ordner betraf
        let twin = JournalIO.appDir.appendingPathComponent(info.url.lastPathComponent)
        if let head = JournalIO.read(twin).first(where: { $0.art == "lauf" }), (head.ordner ?? []).count == 1 { UndoEngine.mark(twin, r) }
        return r
    }
}
