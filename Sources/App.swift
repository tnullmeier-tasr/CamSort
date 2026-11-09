import SwiftUI
import AppKit

#if !SCREENSHOT
@main
#endif
struct CamSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: LearnedStore
    @StateObject private var sorter: Sorter
    @StateObject private var theme = ThemeSettings()
    @StateObject private var gyro: GyroRunner
    @StateObject private var tagger = TagRunner()
    @StateObject private var timeline = TimelineModel()
    @StateObject private var browser = ClipBrowser()
    @StateObject private var selects = SelectsRunner()
    @StateObject private var importer: ImportRunner

    init() {
        let s = LearnedStore()
        let so = Sorter(store: s)
        _store = StateObject(wrappedValue: s)
        _sorter = StateObject(wrappedValue: so)
        _gyro = StateObject(wrappedValue: GyroRunner(store: s, sorter: so))
        _importer = StateObject(wrappedValue: ImportRunner(sorter: so))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sorter)
                .environmentObject(store)
                .environmentObject(theme)
                .environmentObject(gyro)
                .environmentObject(tagger)
                .environmentObject(importer)
                .environmentObject(timeline)
                .environmentObject(browser)
                .environmentObject(selects)
                .frame(minWidth: 560, idealWidth: 580, minHeight: 720, idealHeight: 780)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Farben

enum Theme {
    static let bgTop = Color(red: 0.12, green: 0.15, blue: 0.35)
    static let bgBottom = Color(red: 0.27, green: 0.23, blue: 0.55)
    static let orange = Color(red: 1.00, green: 0.69, blue: 0.23)
    static let mint = Color(red: 0.33, green: 0.84, blue: 0.75)
    static let card = Color.white.opacity(0.08)
}

extension View {
    /// Karte im Glas-Look: leichte Füllung, feine helle Kontur, weicher Schatten.
    func glassBackground(_ radius: CGFloat) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 5)
        )
    }
}

// MARK: - Hauptansicht

struct ContentView: View {
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var store: LearnedStore
    @EnvironmentObject var theme: ThemeSettings
    @EnvironmentObject var gyro: GyroRunner
    @EnvironmentObject var tagger: TagRunner
    @EnvironmentObject var importer: ImportRunner
    @EnvironmentObject var timeline: TimelineModel
    @EnvironmentObject var browser: ClipBrowser
    @EnvironmentObject var selects: SelectsRunner

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            RadialGradient(colors: [Theme.mint.opacity(0.16), Color.clear], center: .topTrailing, startRadius: 0, endRadius: 520)
                .ignoresSafeArea().allowsHitTesting(false)
            RadialGradient(colors: [Theme.orange.opacity(0.14), Color.clear], center: .bottomLeading, startRadius: 0, endRadius: 480)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                Header()
                    .padding(.top, 34)
                Group {
                    if selects.active {
                        SelectsView()
                    } else if importer.active {
                        ImportView()
                    } else if gyro.active {
                        GyroView()
                    } else if tagger.active {
                        TagView()
                    } else {
                        switch sorter.phase {
                        case .idle: IdleView()
                        case .scanning, .sorting: SortingView()
                        case .done, .cancelled: DoneView()
                        }
                    }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                        removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
            }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: sorter.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: gyro.active)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: tagger.active)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: importer.active)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: selects.active)
        .background(Color.clear.sheet(isPresented: $browser.show) { ClipBrowserSheet().environmentObject(browser) })
        .sheet(isPresented: $timeline.show) {
            TimelineSheet().environmentObject(timeline).environmentObject(sorter)
        }
        .sheet(item: $sorter.pendingDuplicate) { req in
            DuplicateSheet(request: req).environmentObject(sorter)
        }
        .background(
            Color.clear.sheet(item: $sorter.pendingCamera) { req in
                CameraSheet(request: req).environmentObject(sorter).environmentObject(store)
            }
        )
        .overlay(
            Color.clear.allowsHitTesting(false).sheet(item: $sorter.pendingExtensions) { req in
                ExtensionSheet(request: req).environmentObject(sorter)
            }
        )
        .background(
            Color.clear.sheet(item: $sorter.pendingQuestion) { req in
                QuestionSheet(request: req).environmentObject(sorter)
            }
        )
        .background(
            Color.clear.sheet(item: $sorter.undoResult) { info in
                UndoResultSheet(info: info)
            }
        )
        .onChange(of: sorter.importRequest) { _, url in
            guard let url else { return }
            sorter.importRequest = nil
            importer.setSource(url)
            importer.open()
        }
    }
}

// MARK: - Rückgängig

struct UndoResultSheet: View {
    let info: UndoResultInfo
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: info.report.skipped.isEmpty ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26)).foregroundStyle(info.report.skipped.isEmpty ? .green : .orange)
                VStack(alignment: .leading) {
                    Text(info.title).font(.headline)
                    Text("\(plural(info.report.restored, "Datei ist", "Dateien sind")) zurück an ihrem ursprünglichen Platz, \(plural(info.report.removedDirs, "leerer Ordner", "leere Ordner")) entfernt.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if !info.report.skipped.isEmpty {
                Text("Übersprungen (nichts überschrieben):").font(.system(size: 12, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(info.report.skipped.enumerated()), id: \.offset) { _, l in
                            Text("• " + l).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 200)
            }
            if !info.report.fcpLibraries.isEmpty {
                Text("Final-Cut-Mediatheken: Clips liegen wieder am alten Ort – in Final Cut ggf. „Dateien neu verknüpfen“:").font(.system(size: 12, weight: .semibold))
                ForEach(info.report.fcpLibraries, id: \.self) { u in
                    Button(u.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.link)
                }
            }
            HStack { Spacer(); Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 480)
    }
}

/// Liste der Läufe, deren Protokoll im eingeworfenen Ordner liegt – Rückgängig nur für den jüngsten noch nicht rückgängig gemachten.
struct FolderRunsView: View {
    @EnvironmentObject var sorter: Sorter
    let runs: [RunInfo]
    @State private var confirm: RunInfo?

    static let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(runs) { r in
                HStack(spacing: 6) {
                    Image(systemName: r.undone ? "arrow.uturn.backward.circle" : "clock.arrow.circlepath").foregroundStyle(.white.opacity(0.6))
                    Text("\(r.title.isEmpty ? "Sortiert" : r.title) am \(Self.df.string(from: r.date)) · \(plural(r.files, "Datei", "Dateien"))")
                    if r.undone { Text("– rückgängig gemacht").foregroundStyle(.white.opacity(0.5)) }
                    Spacer()
                    if JournalStore.canUndo(r, among: runs) {
                        Button("Rückgängig machen") { confirm = r }.buttonStyle(.link)
                    }
                }
                .font(.system(size: 11))
            }
        }
        .alert("Rückgängig machen?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { r in
            Button("Rückgängig machen") { sorter.undoFolderRun(r); confirm = nil }
            Button("Abbrechen", role: .cancel) { confirm = nil }
        } message: { r in
            Text("\(plural(UndoEngine.preview(r.url), "Datei geht", "Dateien gehen")) zurück an ihren ursprünglichen Platz. Nichts wird überschrieben; was inzwischen woanders liegt oder dessen Platz belegt ist, wird übersprungen und aufgelistet.")
        }
    }
}

struct Header: View {
    @EnvironmentObject var store: LearnedStore
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var selects: SelectsRunner
    @EnvironmentObject var gyro: GyroRunner
    @State private var appear = false
    @State private var showLearned = false
    @State private var showTheme = false
    @State private var showGuide = false
    @EnvironmentObject var theme: ThemeSettings
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
                .rotationEffect(.degrees(appear ? 0 : -12))
                .scaleEffect(appear ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text("CamSort").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Videos & Fotos automatisch sortieren · Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { showGuide = true } label: {
                Image(systemName: "book.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .help("Anleitung: Was kann CamSort?")
            .sheet(isPresented: $showGuide) { GuideView() }
            Button { showTheme.toggle() } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .help("Hintergrundfarbe ändern")
            .popover(isPresented: $showTheme) { ThemePicker().environmentObject(theme) }
            // Einstellungen in jeder Phase erreichbar (Start, Sortieren, Fertig, nach Gyroflow, Abgebrochen) – ein gemeinsames Sheet
            Button { sorter.showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .help("Einstellungen")
            .keyboardShortcut(",", modifiers: .command)
            Button { showLearned = true } label: {
                Label("Gelernt", systemImage: "graduationcap.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .help("Kameras und Dateitypen, die CamSort von dir gelernt hat")
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
        .sheet(isPresented: $showLearned) { LearnedView().environmentObject(store) }
        .background(Color.clear.sheet(isPresented: $sorter.showSettings) {
            SettingsView(runActive: sorter.isRunning || gyro.state == .running || gyro.state == .paused)
                .environmentObject(store).environmentObject(selects)
        })
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { appear = true } }
    }
}

// MARK: - Start

struct IdleView: View {
    @EnvironmentObject var selects: SelectsRunner
    @EnvironmentObject var timeline: TimelineModel
    @EnvironmentObject var browser: ClipBrowser
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var store: LearnedStore
    @EnvironmentObject var importer: ImportRunner

    private var settingsSummary: String {
        var p: [String] = []
        p.append(store.includeSubfolders ? "mit Unterordnern" : "ohne Unterordner")
        if store.confirmCameras { p.append("Kameras nachfragen") }
        if store.ownCameraFolders {
            return "Modus: Meine Kameraordner (nur Hochkant / Quer) · " + (store.includeSubfolders ? "mit Unterordnern" : "ohne Unterordner")
        }
        if store.compactLayout {
            let names = store.levels.compactMap { id in LearnedStore.allLevels.first { $0.id == id }?.name.components(separatedBy: " (").first }
            p.append("Ordner: " + (names.isEmpty ? "alles in Videos" : names.joined(separator: store.nestLevels ? " › " : " + ")))
        }
        return "Einstellungen: " + p.joined(separator: " · ")
    }
    @State private var pulse = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Button { sorter.chooseFolders() } label: {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.mint.opacity(0.18))
                            .frame(width: 110, height: 110)
                            .scaleEffect(pulse ? 1.12 : 0.92)
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Theme.mint)
                            .offset(y: pulse ? -3 : 3)
                    }
                    Text(targeted ? "Loslassen zum Hinzufügen" : "Ordner hierher ziehen\noder klicken zum Auswählen")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 230)
                .background(RoundedRectangle(cornerRadius: 24).fill(targeted ? Theme.mint.opacity(0.15) : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                    .foregroundStyle(targeted ? Theme.mint : .white.opacity(0.3)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                withAnimation(.spring()) { sorter.addFolders(urls) }
                return true
            } isTargeted: { t in withAnimation(.easeOut(duration: 0.2)) { targeted = t } }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
            }
            .onChange(of: sorter.pickingFolder) { _, picking in
                if picking {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { pulse = false }
                } else {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
                }
            }

            if !sorter.folders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sorter.folders, id: \.self) { f in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.orange)
                            Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                withAnimation { sorter.folders.removeAll { $0 == f } }
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .glassBackground(10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        if let runs = sorter.folderRuns[f.path], !runs.isEmpty {
                            FolderRunsView(runs: runs).padding(.horizontal, 14)
                        }
                        if Sorter.looksSorted(f) || FCPLibraryBuilder.hasProjectFolders(f) || store.ownCameraFolders {
                            FCPLibraryQuickRow(folder: f, suffixes: store.gyroSuffixList).padding(.horizontal, 14)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack(spacing: 8) {
                Toggle(isOn: $store.ownCameraFolders) {
                    Label(store.ownCameraFolders ? "Meine Kameraordner: an – nur Hochkant / Quer" : "Meine Kameraordner: aus – Kamera wird erkannt",
                          systemImage: store.ownCameraFolders ? "folder.fill.badge.person.crop" : "camera.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                }
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                HelpButton(title: "Meine Kameraordner",
                           text: "An: Du hast selbst Ordner pro Kamera angelegt (A1, Mini-Drohne, Avata …). CamSort übernimmt sie als Kamera und sortiert darin nur nach Hochkant/Quer. Wähle den Dreh-Ordner oder direkt einen Kameraordner.\nAus: CamSort erkennt die Kamera selbst.")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassBackground(12)

            Button { sorter.showSettings = true } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                    Text(settingsSummary).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(12)
                .glassBackground(12)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button { importer.open() } label: {
                    Label("Von Speicherkarte importieren", systemImage: "sdcard.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .glassBackground(12)
                }
                .buttonStyle(.plain)
                HelpButton(title: "Von Speicherkarte importieren",
                           text: "Zeigt alle Aufnahmetage auf der Karte mit Anzahl und Größe. Du hakst an, welche Tage übernommen werden – alte Aufnahmen auf der Karte bleiben einfach liegen. CamSort kopiert, prüft jede Kopie und sortiert danach automatisch. Die Karte selbst wird nie verändert.")
            }

            Spacer(minLength: 0)

            Button { sorter.start() } label: {
                Label(sorter.folders.contains(where: Sorter.looksSorted)
                      ? "Aktualisieren" : "Sortieren starten", systemImage: "wand.and.stars")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Theme.orange, Color(red: 1, green: 0.5, blue: 0.3)],
                                             startPoint: .leading, endPoint: .trailing)))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.orange.opacity(sorter.folders.isEmpty ? 0 : 0.40), radius: 14, x: 0, y: 6)
                    .opacity(sorter.folders.isEmpty ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(sorter.folders.isEmpty)

            if sorter.folders.contains(where: Sorter.looksSorted)
                || (store.ownCameraFolders && !sorter.folders.isEmpty) {
                HStack(spacing: 10) {
                    Button { timeline.open(folders: sorter.folders) } label: {
                        Label("Zeitleiste", systemImage: "clock.arrow.2.circlepath")
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .glassBackground(12)
                    }.buttonStyle(.plain)
                    Button { browser.open(folders: sorter.folders) } label: {
                        Label("Ansehen & drehen", systemImage: "rotate.right")
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .glassBackground(12)
                    }.buttonStyle(.plain)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            if (store.autoGyro || store.showGyroButton),
               sorter.folders.contains(where: Sorter.looksSorted)
                || (store.ownCameraFolders && !sorter.folders.isEmpty) {
                HStack(spacing: 8) {
                    Button { sorter.startGyro() } label: {
                        Label("Nur Gyroflow-Clips trennen", systemImage: "gyroscope")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.mint.opacity(0.7), lineWidth: 1.5))
                            .foregroundStyle(Theme.mint)
                    }
                    .buttonStyle(.plain)
                    HelpButton(title: "Nur Gyroflow-Clips trennen",
                               text: "Für den Fall, dass du die Clips nach dem Sortieren selbst in Gyroflow gerendert hast: CamSort sortiert nichts Neues ein, sondern trennt nur in jedem Ordner, in dem Gyroflow etwas erzeugt hat, nach „Stabilisiert“ (Dateiname enthält z. B. _gyro oder _stabilized), „Original“ und „Gyroflow-Projekte“. Die Endungen stellst du unter Einstellungen › Gyroflow ein.\n\n„Aktualisieren“ macht dasselbe automatisch mit – sortiert aber zusätzlich neue Dateien ein.")
                }
                .transition(.opacity)
            }

            Text("Dateien werden nur verschoben – nie verändert.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Sortieren

struct SortingView: View {
    @EnvironmentObject var sorter: Sorter
    @State private var spin = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: sorter.phase == .scanning ? 0.25 : sorter.progress)
                    .stroke(AngularGradient(colors: [Theme.mint, Theme.orange, Theme.mint], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(sorter.phase == .scanning ? (spin ? 270 : -90) : -90))
                    .animation(.easeInOut(duration: 0.35), value: sorter.progress)
                VStack(spacing: 4) {
                    Text(sorter.phase == .scanning ? "…" : "\(Int(sorter.progress * 100)) %")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.default, value: sorter.processed)
                    Text(sorter.phase == .scanning ? "Suche Dateien" : "\(sorter.processed) von \(sorter.total)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 190, height: 190)
            .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }

            Text(sorter.currentFile.isEmpty ? " " : sorter.currentFile)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.middle)
                .id(sorter.currentFile)
                .transition(.push(from: .bottom))
                .animation(.easeOut(duration: 0.2), value: sorter.currentFile)

            if !sorter.stepLabel.isEmpty {
                Text(sorter.stepLabel)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                    .transition(.opacity)
            }

            CountGrid()

            Spacer(minLength: 0)

            Button { sorter.cancel() } label: {
                Label("Stopp", systemImage: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }
}

struct CountGrid: View {
    @EnvironmentObject var sorter: Sorter
    var hideZeros = false
    private var items: [(key: String, icon: String, color: Color, n: Int)] {
        var r: [(key: String, icon: String, color: Color, n: Int)] = [
            ("Hochkant", "rectangle.portrait.fill", Theme.mint, sorter.counts["Hochkant"] ?? 0),
            ("Quer", "rectangle.fill", Theme.orange, sorter.counts["Quer"] ?? 0),
            ("Fotos", "photo.fill", Color(red: 0.6, green: 0.7, blue: 1), sorter.counts["Fotos"] ?? 0),
        ]
        if let v = sorter.counts[FolderNames.square], v > 0 { r.append((FolderNames.square, "square.fill", Theme.mint, v)) }
        if let v = sorter.counts["Video"], v > 0 { r.append(("Video", "film", .white, v)) }
        let icons = ["Extras": "tray.full", "Begleitdateien": "doc.on.doc", "Stabilisiert": "gyroscope", "Original": "film", "Gyroflow-Projekte": "doc.badge.gearshape",
                     "XML": "doc.text.fill", "LRF": "film.fill", "SRT": "text.alignleft", "Musik": "music.note",
                     "ZIP": "doc.zipper", "FCP": "film.stack"]
        let keys = Set(["XML", "LRF", "SRT"]).union(sorter.sideCounts.keys).sorted()
        for k in keys { r.append((k, icons[k] ?? "doc.fill", .white, sorter.sideCounts[k] ?? 0)) }
        return r
    }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(items.filter { !hideZeros || $0.n > 0 }, id: \.key) { item in
                VStack(spacing: 5) {
                    Image(systemName: item.icon).font(.system(size: 16)).foregroundStyle(item.color)
                    Text("\(item.n)").font(.system(size: 19, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.spring(), value: item.n)
                    Text(item.key).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .glassBackground(14)
                .scaleEffect(item.n > 0 ? 1 : 0.97)
                .opacity(item.n > 0 ? 1 : 0.5)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: item.n > 0)
            }
        }
    }
}

// MARK: - Fertig

struct DoneView: View {
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var gyro: GyroRunner
    @EnvironmentObject var tagger: TagRunner
    @EnvironmentObject var timeline: TimelineModel
    @EnvironmentObject var browser: ClipBrowser
    @EnvironmentObject var selects: SelectsRunner
    @AppStorage("selEnabled") private var selEnabled = true
    @EnvironmentObject var store: LearnedStore
    @State private var pop = false
    @State private var showProblems = true
    @State private var confirmUndo = false

    var cancelled: Bool { sorter.phase == .cancelled }
    var hasProblems: Bool { !sorter.problems.isEmpty }
    var accent: Color { cancelled || hasProblems ? Theme.orange : Theme.mint }

    var body: some View {
        VStack(spacing: 14) {
            MaybeScroll {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(accent.opacity(0.2)).frame(width: 96, height: 96).scaleEffect(pop ? 1 : 0.2)
                        Image(systemName: cancelled ? "stop.circle.fill"
                                          : hasProblems ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 50, weight: .bold))
                            .foregroundStyle(accent)
                            .scaleEffect(pop ? 1 : 0.1)
                            .rotationEffect(.degrees(pop ? 0 : -90))
                    }
                    .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.5)) { pop = true } }

                    Text(cancelled ? "Abgebrochen" : hasProblems ? "Fertig – mit Hinweisen" : "Fertig sortiert!")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)

                    CountGrid(hideZeros: true)

                    if !sorter.projectSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sorter.projectSummaries) { p in
                                HStack(alignment: .top) {
                                    Image(systemName: p.isNew ? "folder.fill.badge.plus" : "folder.fill").foregroundStyle(p.isNew ? Theme.mint : .white.opacity(0.6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).lineLimit(1).truncationMode(.middle)
                                        Text([p.range, p.cams].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Spacer()
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                                .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                            }
                        }
                    }

                    if !sorter.folderStats.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sorter.folderStats) { st in
                                HStack {
                                    Image(systemName: st.moved > 0 ? "folder.fill.badge.plus" : "folder.fill").foregroundStyle(st.moved > 0 ? Theme.mint : .white.opacity(0.5))
                                    Text(st.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if st.moved == 0 { Text("unverändert").foregroundStyle(.white.opacity(0.5)) }
                                    else { Text("Hochkant \(st.hochkant) · Quer \(st.quer)" + (st.quadrat > 0 ? " · \(FolderNames.square) \(st.quadrat)" : "") + (st.other > 0 ? " · +\(st.other)" : "")) }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                            }
                        }
                    }
                    if !sorter.cameras.isEmpty && sorter.folderStats.isEmpty {
                        FlowChips(items: sorter.cameras.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
                    }
                    if !sorter.speeds.isEmpty {
                        FlowChips(items: sorter.speeds.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }, icon: "speedometer")
                    }
                    if !sorter.lenses.isEmpty {
                        FlowChips(items: sorter.lenses.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }, icon: "camera.aperture")
                    }

                    if hasProblems { MessageBox(title: plural(sorter.problems.count, "Datei", "Dateien") + " nicht verschoben",
                                                lines: sorter.problems,
                                                footer: "Diese Dateien liegen unverändert an ihrem alten Platz.",
                                                color: Theme.orange, open: $showProblems) }
                    if !sorter.hints.isEmpty { MessageBox(title: plural(sorter.hints.count, "Hinweis", "Hinweise"),
                                                          lines: sorter.hints, footer: nil,
                                                          color: Theme.mint, open: .constant(true)) }
                }
                .padding(.bottom, 6)
            }

            if !cancelled && !sorter.gyroOffer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(plural(sorter.gyroOffer.count, "Clip enthält", "Clips enthalten")) Gyrodaten (\(sorter.gyroOfferByCamera.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))) – jetzt in Gyroflow stabilisieren?")
                        .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { Task { await gyro.start(clips: sorter.gyroOffer, folders: sorter.folders) } } label: {
                            Label("Jetzt stabilisieren", systemImage: "gyroscope")
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mint.opacity(0.35)))
                        }.buttonStyle(.plain)
                        HelpButton(title: "Gyrodaten erkannt", text: "CamSort hat in diesen Clips Bewegungsdaten gefunden, die Gyroflow lesen kann (Sony, DJI mit eingebetteten Gyrodaten wie Avata/Action, GoPro, Insta360). Schon stabilisierte Clips und Clips, zu denen es schon eine stabilisierte Fassung gibt, sind nicht dabei. Gyroflow rendert erst alle Hochkant-, dann alle Quer-Clips; die Ergebnisse landen neben dem Original und werden danach in „Stabilisiert“ / „Original“ getrennt. 4:3-Clips behalten auf Wunsch ihr Format (Einstellungen › Gyroflow).")
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mint.opacity(0.12)))
            }
            if !cancelled && !sorter.fcpLibraries.isEmpty && sorter.movedVideos > 0 {
                FCPRelinkCard(libraries: sorter.fcpLibraries)
            }
            if !cancelled {
                FCPLibraryCard(folders: sorter.folders, suffixes: store.gyroSuffixList, gyroBusy: gyro.state == .running || gyro.state == .paused)
            }
            if !cancelled && selEnabled {
                HStack(spacing: 8) {
                    Button { selects.start(folders: sorter.folders, suffixes: store.gyroSuffixList) } label: {
                        Label("Beste Momente finden → Final Cut", systemImage: "sparkles")
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Theme.mint.opacity(0.35), Theme.orange.opacity(0.35)], startPoint: .leading, endPoint: .trailing)))
                    }.buttonStyle(.plain)
                    HelpButton(title: "Beste Momente finden",
                               text: "Analysiert alle sortierten Clips lokal und ohne KI nach Schärfe, Belichtung und Ruhe, behält die besten Abschnitte und legt sie als Projekt „Beste Momente“ in eine Final-Cut-Datei im Dreh-Ordner – ein Klick öffnet sie in Final Cut. Die Clips werden nur verknüpft, nichts wird kopiert oder verändert. Abschnittslänge, Anteil und Gewichtung stellst du in den Einstellungen ein.")
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            if !cancelled && store.enableTagging {
                HStack(spacing: 8) {
                    Button { tagger.start(folders: sorter.folders) } label: {
                        Label("Clips verschlagworten (Finder-Tags)", systemImage: "tag.fill")
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.orange, lineWidth: 1.5))
                            .foregroundStyle(Theme.orange)
                    }.buttonStyle(.plain)
                    HelpButton(title: "Clips verschlagworten",
                               text: "CamSort schaut sich jeden Clip in den Videos-Ordnern an (ein Standbild alle ~3 Sekunden) und erkennt lokal auf deinem Mac, was zu sehen ist – z. B. Person, Auto, Motorrad, Straße. Zusätzlich liest es Schriftzüge im Bild und erkennt so Automarken wie Porsche, BMW oder Maserati, wenn der Name lesbar ist.\n\nDie Begriffe werden als Finder-Tags ergänzt. Vorhandene Tags bleiben, die Videodatei selbst wird nicht verändert. Dauert je nach Menge einige Minuten; Pause ist jederzeit möglich.")
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            if !cancelled && store.showGyroButton {
                HStack(spacing: 8) {
                    Button { Task { await gyro.start(folders: sorter.folders) } } label: {
                        Label("Clips mit Gyroflow stabilisieren", systemImage: "gyroscope")
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.mint, lineWidth: 1.5))
                            .foregroundStyle(Theme.mint)
                    }.buttonStyle(.plain)
                    HelpButton(title: "Mit Gyroflow stabilisieren",
                               text: "Schickt alle noch nicht stabilisierten Sony-Clips aus den Ordnern Hochkant und Quer an Gyroflow – einzeln nacheinander, zuerst alle Hochkant-, dann alle Quer-Clips. Gyroflow arbeitet dabei im Hintergrund mit deinem hinterlegten Preset (Einstellungen › Gyroflow). Du kannst jederzeit pausieren oder abbrechen. Wenn Gyroflow fertig ist, trennt CamSort automatisch in „Stabilisiert“ und „Original“.")
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            HStack(spacing: 10) {
                Button { timeline.open(folders: sorter.folders) } label: {
                    Label("Zeitleiste", systemImage: "clock.arrow.2.circlepath")
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .glassBackground(12)
                }.buttonStyle(.plain)
                Button { browser.open(folders: sorter.folders) } label: {
                    Label("Ansehen & drehen", systemImage: "rotate.right")
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .glassBackground(12)
                }.buttonStyle(.plain)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))

            if sorter.lastJournal != nil && !sorter.lastJournalUndone {
                Button { confirmUndo = true } label: {
                    Label("Rückgängig machen", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .glassBackground(12)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .help("Alles aus diesem Lauf zurück an den ursprünglichen Platz – nichts wird überschrieben")
                .alert("Rückgängig machen?", isPresented: $confirmUndo) {
                    Button("Rückgängig machen") { sorter.undoLastRun() }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("\(plural(sorter.lastJournal.map { UndoEngine.preview($0) } ?? 0, "Datei geht", "Dateien gehen")) zurück an ihren ursprünglichen Platz, angelegte Ordner werden entfernt, sofern leer. Nichts wird überschrieben.")
                }
            }

            HStack(spacing: 12) {
                Button { sorter.revealInFinder() } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .glassBackground(12)
                }.buttonStyle(.plain)
                Button { withAnimation { sorter.reset() } } label: {
                    Label("Neue Ordner", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.orange))
                }.buttonStyle(.plain)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
    }

    private var summary: String {
        var parts = [plural(sorter.movedTotal, "Datei", "Dateien") + " verschoben"]
        if sorter.skipped > 0 { parts.append("\(sorter.skipped) übersprungen") }
        if sorter.ignored > 0 { parts.append("\(sorter.ignored) ignoriert") }
        return parts.joined(separator: " · ")
    }
}

func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

struct FlowChips: View {
    let items: [(String, Int)]
    var icon: String? = nil
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.0) { cam in
                HStack(spacing: 5) {
                    Image(systemName: icon ?? (cam.0 == "iPhone" ? "iphone" : cam.0 == "Unbekannt" ? "questionmark.circle" : "camera.fill"))
                    Text("\(cam.0)  \(cam.1)").lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Theme.card))
            }
        }
    }
}

struct MessageBox: View {
    let title: String
    let lines: [String]
    let footer: String?
    let color: Color
    @Binding var open: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { open.toggle() } } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                    Text(title)
                    Spacer()
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text("• " + line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let f = footer {
                    Text(f).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
    }
}

// MARK: - Duplikat-Dialog

struct DuplicateSheet: View {
    @EnvironmentObject var sorter: Sorter
    let request: DuplicateRequest
    @State private var forAll = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text("Datei schon vorhanden").font(.headline)
            Text("„\(request.name)“ gibt es im Zielordner schon:\n\(request.folder)")
                .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .lineLimit(4)
            Toggle("Für alle weiteren Duplikate übernehmen", isOn: $forAll).font(.system(size: 12))
            VStack(spacing: 8) {
                Button { sorter.answerDuplicate(.skip, forAll: forAll) } label: {
                    Text("Überspringen (Original bleibt liegen)").frame(maxWidth: .infinity)
                }.keyboardShortcut(.defaultAction)
                Button { sorter.answerDuplicate(.keepBoth, forAll: forAll) } label: {
                    Text("Beide behalten (neue bekommt „(2)“)").frame(maxWidth: .infinity)
                }
                Button { sorter.answerDuplicate(.replace, forAll: forAll) } label: {
                    Text("Ersetzen (alte in den Papierkorb)").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}

// MARK: - Unbekannte Kamera

struct CameraSheet: View {
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var store: LearnedStore
    let request: CameraRequest
    @State private var name = ""
    @State private var remember = true
    @State private var newFolder = ""

    private var suggestions: [String] {
        let base = ["DJI Osmo Action 6", "DJI Mini 5 Pro", "Sony", "iPhone", "Samsung", "Insta360", "Canon", "GoPro"]
        return Array(NSOrderedSet(array: store.cameraNames + base)) as? [String] ?? base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "camera.badge.ellipsis").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text(request.suggestion.isEmpty ? "Unbekannte Kamera" : "Neue Kamera gefunden").font(.headline)
                    Text(request.fileName).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if !request.hint.isEmpty {
                Text(request.hint).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Mit welcher Kamera wurde das aufgenommen?").font(.system(size: 13))
            TextField("Name der Kamera, z. B. Canon R6", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !name.isEmpty { sorter.answerCamera(name, remember: remember) } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { name = s }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Divider()
            Text("Kein Kamera-Clip? In eigenen Ordner legen:").font(.system(size: 12, weight: .semibold))
            FlowFolders(folders: store.specialFolders, newFolder: $newFolder,
                        pick: { f in sorter.answerCamera(LearnedStore.folderPrefix + f, remember: remember) },
                        add: { f in store.addFolder(f); sorter.answerCamera(LearnedStore.folderPrefix + f, remember: remember) })
            Divider()
            Toggle("Merken – künftig automatisch so einsortieren (\(request.signatureLabel))", isOn: $remember)
                .font(.system(size: 11))
            Button {
                sorter.skipLearning()
            } label: {
                Label("Nicht mehr fragen – Rest nach bestem Wissen sortieren", systemImage: "forward.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Für diesen Durchlauf keine Rückfragen mehr. Bekannte Kameras werden normal sortiert, unbekannte landen in „Unbekannt“.")
            HStack {
                Button(request.suggestion.isEmpty ? "Als „Unbekannt“ einsortieren" : "Diesmal nicht merken") { sorter.answerCamera(request.suggestion.isEmpty ? nil : request.suggestion, remember: false) }
                Spacer()
                Button("Übernehmen") { sorter.answerCamera(name, remember: remember) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .onAppear { name = request.suggestion.isEmpty ? (request.hint.contains("DJI") ? "DJI " : "") : request.suggestion }
    }
}

// MARK: - Rückfrage vor dem Lauf

struct QuestionSheet: View {
    @EnvironmentObject var sorter: Sorter
    let request: QuestionRequest
    @State private var choice: String = ""
    @State private var remember = false
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: request.icon).font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text(request.title).font(.headline)
                    Text(request.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let ex = request.example, !ex.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Beispiel aus diesem Ordner").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(ex).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            }
            if !request.tree.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("So sieht es danach aus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(request.tree.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 180)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.options) { o in
                    Button { choice = o.id } label: {
                        HStack(alignment: .top) {
                            Image(systemName: choice == o.id ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(o.label).font(.system(size: 13, weight: .semibold))
                                    if o.id == request.recommended {
                                        Text("Empfohlen").font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.green.opacity(0.25)))
                                    }
                                }
                                Text(o.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                if o.id == request.recommended, let r = request.reason, !r.isEmpty {
                                    Text(r).font(.system(size: 11)).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            let shownFields = request.fields.filter { choice.hasPrefix($0.showFor) }
            if !shownFields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shownFields) { f in
                        HStack {
                            Text(f.label).font(.system(size: 12)).frame(width: 120, alignment: .leading)
                            TextField(f.value, text: Binding(get: { values[f.id] ?? f.value }, set: { values[f.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            Toggle(request.rememberLabel ?? "Antwort merken (gilt ab Start, in den Einstellungen änderbar)", isOn: $remember).font(.system(size: 12))
            HStack {
                Button("Abbrechen") { sorter.answerQuestion(nil, remember: false); sorter.cancel() }
                if request.canGoBack {
                    Button { sorter.goBack() } label: { Label("Zurück", systemImage: "chevron.left") }
                        .help("Zur vorigen Frage – die bisherige Antwort ist vorbelegt. Es wurde noch nichts verschoben.")
                }
                Spacer()
                Button(request.options.contains(where: { $0.id == "start" }) && choice == "start" ? "Start" : "Weiter") {
                    var v: [String: String] = [:]
                    for f in request.fields {
                        let t = (values[f.id] ?? f.value).trimmingCharacters(in: .whitespacesAndNewlines)
                        v[f.id] = t.isEmpty ? f.value : t
                    }
                    sorter.answerQuestion(choice.isEmpty ? (request.options.first?.id ?? "off") : choice, remember: remember, fields: v)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: request.fields.isEmpty && request.tree.isEmpty ? 460 : 540)
        .interactiveDismissDisabled()
        .onAppear {
            if choice.isEmpty { choice = request.prefill ?? request.options.first?.id ?? "" }
            if request.prefill != nil { values = request.prefillFields; remember = request.prefillRemember }
        }
    }
}

// MARK: - Unbekannte Dateitypen

struct ExtensionSheet: View {
    @EnvironmentObject var sorter: Sorter
    let request: ExtensionRequest
    @State private var choice: [String: FileCategory] = [:]
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.folder.fill").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Unbekannte Dateitypen").font(.headline)
                    Text("Was soll mit diesen Dateien passieren?").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(request.extensions, id: \.ext) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(".\(e.ext.uppercased())").font(.system(size: 13, weight: .bold))
                                Text("\(e.count)× – z. B. \(e.example)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Text("Empfohlen: \(FileCategory.ignore.label) – unbekannte Dateien bleiben sicher, wo sie sind").font(.system(size: 10)).foregroundStyle(.green).lineLimit(2)
                            }
                            Spacer()
                            Picker("", selection: Binding(get: { choice[e.ext] ?? .ignore }, set: { choice[e.ext] = $0 })) {
                                ForEach(FileCategory.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 210)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            Toggle("Für diese Dateitypen merken", isOn: $remember).font(.system(size: 12))
            HStack {
                Button("Abbrechen") { sorter.answerExtensions(nil, remember: false); sorter.cancel() }
                Spacer()
                Button("Weiter") {
                    var m: [String: FileCategory] = [:]
                    for e in request.extensions { m[e.ext] = choice[e.ext] ?? .ignore }
                    sorter.answerExtensions(m, remember: remember)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}

// MARK: - Gelerntes verwalten

struct LearnedView: View {
    @EnvironmentObject var store: LearnedStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gelernt").font(.title2.bold())
            Text("Das hat CamSort sich gemerkt. Mit – kannst du Einträge wieder löschen.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            List {
                Section("Kameras") {
                    if store.rules.isEmpty { Text("Noch nichts gelernt").foregroundStyle(.secondary) }
                    ForEach(store.rules) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.camera).bold()
                                Text(r.label)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { store.remove(r) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Section("Dateitypen") {
                    if store.extensions.isEmpty { Text("Noch nichts gelernt").foregroundStyle(.secondary) }
                    ForEach(store.extensions.keys.sorted(), id: \.self) { e in
                        HStack {
                            Text(".\(e.uppercased())").bold()
                            Text(store.extensions[e]?.label ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Button { store.removeExtension(e) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 300)
            HStack { Spacer(); Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 480)
    }
}


// MARK: - Einstellungen

struct SettingsView: View {
    @EnvironmentObject var store: LearnedStore
    @Environment(\.dismiss) private var dismiss
    /// Läuft gerade ein Lauf? Dann gelten Änderungen erst ab dem nächsten Lauf (der laufende nutzt eine Momentaufnahme).
    var runActive = false
    @AppStorage("useVideosFolder") private var useVideosFolder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Einstellungen").font(.title2.bold()).padding(.bottom, 10)
            if runActive {
                Label("Ein Lauf ist aktiv – Änderungen gelten ab dem nächsten Lauf.", systemImage: "info.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.18)))
                    .padding(.bottom, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Sortieren")
                    WithHelp(title: "Meine Kameraordner", text: "Für deinen Ablauf: Du legst beim Heimkommen selbst einen Ordner pro Kamera an (z. B. „A1“, „Mini-Drohne“, „Avata“) und kopierst die Karten hinein.\n\nAn: CamSort übernimmt deine Ordner als Kamera – es erkennt, fragt und benennt keine Kamera. In jedem Kameraordner sortiert es nur nach Hochkant und Quer, auch aus Kartenstrukturen wie PRIVATE/M4ROOT/CLIP oder DCIM. Begleitdateien (XML, SRT, LRF …) kommen in „Begleitdateien“, Fotos in „Fotos“, Musik/ZIP/FCP in „Extras“ – alles innerhalb des Kameraordners.\n\nWähle den Dreh-Ordner mit den Kameraordnern oder direkt einen Kameraordner. Lose Dateien im Dreh-Ordner bleiben liegen. Mehrfaches Einlesen ist sicher: Fertig sortierte Kameraordner bleiben unverändert, nur Neues wird einsortiert.\n\nAus: CamSort erkennt die Kamera selbst (bisheriges Verhalten).") {
                        Toggle("Meine Kameraordner (nur Hochkant / Quer)", isOn: $store.ownCameraFolders)
                    }
                    WithHelp(title: "Projekte trennen", text: "Liegt zwischen den Clips eine auffällig lange Pause (z. B. Vormittag ein Auftrag, Nachmittag ein zweiter), schlägt CamSort vor, die Dateien in zwei Projekte zu trennen – das ist nur ein Vorschlag, CamSort fragt immer nach. Auffällig heißt: mindestens so lang wie die Mindestpause UND deutlich länger als die üblichen Pausen dieses Drehs (mind. 4× der typischen Pause). Regelmäßige Pausen eines Drehs lösen also keine Frage aus. Über Mitternacht ohne lange Pause bleibt es ein Projekt.\n\nGetrennt wird in Unterordner IM eingeworfenen Ordner: Pitbike/2026-11-08 Vormittag/…, Pitbike/2026-11-08 Nachmittag/… – darin die gewohnte Struktur (Videos/… bzw. A1/Hochkant). Die Namen kannst du in der Frage ändern. Steht im Projektnamen ein Datum, wird der Ordner nicht mehr umbenannt. Fotos kommen ins Projekt ihres Aufnahmedatums, Begleitdateien zu ihrem Clip.\n\nLiegt eine Kamera ganz allein in einem Zeitblock, ist vielleicht ihre Uhr falsch gestellt – CamSort weist darauf hin und bietet an, sie dem Hauptprojekt zuzuordnen.\n\nBeim erneuten Einlesen erkennt CamSort die Projektordner (unsichtbare Datei .camsort-projekt): Neue Clips, die zeitlich passen, landen ohne Frage im passenden Projekt.\n\nFragen: Vorschlag mit Rückfrage. Immer trennen: ohne Frage (außer bei Verdacht auf falsche Kamerauhr). Nie: nie trennen.") {
                        Text("Projekte trennen").font(.system(size: 12)).fixedSize()
                        Picker("Projekte trennen", selection: $store.projectMode) {
                            Text("Fragen").tag("ask"); Text("Immer trennen").tag("always"); Text("Nie").tag("never")
                        }.labelsHidden().frame(width: 300)
                    }
                    if store.projectMode != "never" {
                        Stepper("Pause für neues Projekt: mind. \(Sorter.durationText(store.projectGapMinutes * 60))", value: $store.projectGapMinutes, in: 30...720, step: 30)
                            .font(.system(size: 12))
                    }
                    WithHelp(title: "Tagesordner", text: "Stammen die Clips von mehreren Tagen, kann CamSort zusätzlich nach Aufnahmetag ordnen – oben (Dreh/2026-10-12/A1/Hochkant) oder unter der Kamera (Dreh/A1/2026-10-12/Hochkant). „Fragen“: CamSort fragt nur, wenn wirklich mehrere Tage drin sind. Gibt es schon Tagesordner, wird die vorhandene Struktur ohne Frage weitergeführt.\n\nDas Datum kommt aus den Video-Metadaten (Aufnahmezeit), nicht aus dem Dateidatum.") {
                        Text("Tagesordner").font(.system(size: 12)).fixedSize()
                        Picker("Tagesordner", selection: $store.dateMode) {
                            Text("Fragen").tag("ask"); Text("Oben").tag("top"); Text("Unter der Kamera").tag("under"); Text("Nie").tag("off")
                        }.labelsHidden().frame(width: 300)
                    }
                    HStack {
                        Text("Datumsformat").font(.system(size: 12))
                        TextField("yyyy-MM-dd", text: $store.dateFormat).textFieldStyle(.roundedBorder).frame(width: 120)
                        Text("→ \(store.dayString(Date()))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    WithHelp(title: "Nach Framerate fragen", text: "Haben die neuen Clips mindestens zwei verschiedene Frameraten (z. B. 25 fps und 100 fps Zeitlupe), fragt CamSort vor dem Verschieben, ob zusätzlich nach Framerate sortiert werden soll – z. B. Dreh/A1/50 fps/Hochkant. Bei nur einer Framerate wird nicht gefragt.\n\n„Ja“ gilt nur für diesen Lauf. Mit „Antwort merken“ wird „Ja“ zur festen Ebene im Ordner-Aufbau, „Nein“ stellt die Frage hier auf „Nie“.\n\nGibt es im Dreh schon FPS-Ordner, führt CamSort die Struktur ohne Frage weiter.") {
                        Text("Framerate").font(.system(size: 12)).fixedSize()
                        Picker("Framerate", selection: $store.fpsMode) {
                            Text("Fragen").tag("ask"); Text("Nie").tag("off")
                        }.labelsHidden().frame(width: 300)
                        .disabled(store.levels.contains("fps"))
                    }
                    if store.levels.contains("fps") {
                        Text("Framerate ist im Ordner-Aufbau fest aktiv – es wird nicht gefragt.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    WithHelp(title: "Nach Mitternacht", text: "An: Aufnahmen zwischen 0 und 4 Uhr zählen zum Vortag – praktisch bei Abend-Events, die über Mitternacht gehen.") {
                        Toggle("Aufnahmen bis 4 Uhr zählen zum Vortag", isOn: $store.nightToPrevDay)
                    }
                    WithHelp(title: "Datum im Ordnernamen", text: "Nach erfolgreichem Sortieren kann CamSort den eingeworfenen Ordner umbenennen, z. B. „Pitbike“ → „2026-10-12 Pitbike“ (frühestes Aufnahmedatum der Clips; bei mehreren Tagen auch als Zeitraum). Nur der Ordner wird umbenannt, keine Datei. Steht schon ein Datum im Namen, wird nicht gefragt. Gibt es den neuen Namen schon oder ist der Ordner gesperrt, bleibt alles wie es ist und CamSort meldet das.") {
                        Text("Datum im Namen").font(.system(size: 12)).fixedSize()
                        Picker("Datum im Namen", selection: $store.renameMode) {
                            Text("Fragen").tag("ask"); Text("Vorne").tag("front-start"); Text("Vorne, Zeitraum").tag("front-range")
                            Text("Hinten").tag("back-start"); Text("Hinten, Zeitraum").tag("back-range"); Text("Nie").tag("off")
                        }.labelsHidden().frame(width: 300)
                    }
                    WithHelp(title: "Kompakte Ordner", text: "An (empfohlen): Alle Merkmale stehen in EINEM Ordnernamen statt in verschachtelten Ordnern – z. B. Videos/Sony Alpha 1 · FE 24-70 · Quer. So siehst du sofort, was drin ist, und bist mit einem Klick beim Clip. Neue Ordner entstehen nur, wenn es im Dreh wirklich etwas anderes gibt (zweite Kamera, Hochkant-Clips …). XML, LRF und SRT landen gemeinsam in „Begleitdateien“.\n\nEin Dreh ist jeder Ordner mit Clips – bei Kundenordnern also jeder Unterordner. Kartenordner wie DCIM oder PRIVATE zählen zum Dreh darüber.\n\nAus: ausführliche Struktur mit eigenem Ordner pro Ebene (Videos/Kamera/Quer).") {
                        Toggle("Kompakte Ordner (nur was sich unterscheidet)", isOn: $store.compactLayout)
                    }
                    if store.compactLayout {
                        WithHelp(title: "Videos-Sammelordner", text: "An (bisheriges Verhalten): Alle Video-Ebenen liegen in einem Ordner „Videos“ im Dreh – z. B. Pitbike/Videos/Sony ZV-E1/Quer.\n\nAus: Die Ebenen (Kamera › Objektiv › Ausrichtung …) liegen direkt im Dreh-Ordner – z. B. Pitbike/Sony ZV-E1/Quer bzw. Pitbike/Sony ZV-E1/FE 24-70/Hochkant. Fotos, Begleitdateien und Extras bleiben wie bisher in ihren eigenen Ordnern.\n\nErneutes Einlesen bleibt sicher: CamSort erkennt die sortierten Ordner an Ausrichtung, Framerate bzw. Szene. Ist keine dieser Ebenen im Ordner-Aufbau aktiv, legt CamSort den Videos-Ordner trotzdem an.\n\nWer unter jedem Kameraordner nur Hochkant/Quer möchte (Pitbike/E1/Hochkant): Modus „Meine Kameraordner“.\n\nBereits sortierte Drehs: Beim erneuten Einwerfen fragt CamSort, ob sie nach den neuen Einstellungen neu geordnet werden sollen (nur verschieben).") {
                            Toggle("Videos-Sammelordner anlegen", isOn: $useVideosFolder)
                        }
                        LevelBuilder()
                    } else {
                        Text("Beispiel: Dreh 1/Videos/Sony Alpha 1/Quer").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    WithHelp(title: "Unterordner durchsuchen", text: "An: CamSort schaut auch in alle Unterordner des gewählten Ordners und sortiert jede Datei in dem Ordner ein, in dem sie liegt. Ordner, die CamSort selbst angelegt hat (Videos, Fotos, XML …), werden dabei übersprungen.\nAus: Nur Dateien, die direkt im gewählten Ordner liegen, werden sortiert.") {
                        Toggle("Auch Unterordner durchsuchen", isOn: $store.includeSubfolders)
                    }
                    WithHelp(title: "Kameras nachfragen", text: "An: Bei jeder neuen Kamera fragt CamSort einmal, unter welchem Namen sie einsortiert werden soll, und merkt sich die Antwort dauerhaft (siehe „Gelernt“ oben rechts).\nAus: Erkannte Kameras werden ohne Rückfrage einsortiert, unbekannte landen in „Unbekannt“.") {
                        Toggle("Bei neuen Kameras nachfragen und Namen merken", isOn: $store.confirmCameras)
                    }

                    section("Datensicherheit")
                    WithHelp(title: "Übersicht vor dem Verschieben", text: "Nachdem alle Fragen beantwortet sind, zeigt CamSort kurz, wie viele Dateien verschoben und wie viele Ordner angelegt werden, und eine Vorschau der Ordnerstruktur – erst mit „Start“ wird etwas bewegt. Abbrechen heißt: nichts passiert.\n\nJeder Schritt wird protokolliert (Application Support/CamSort/Protokolle und unsichtbar im Ordner selbst). Deshalb lässt sich jeder Lauf rückgängig machen – auch Wochen später und nach Umbenennen oder Verschieben des Ordners.") {
                        Toggle("Vor dem Verschieben Übersicht zeigen", isOn: $store.showOverview)
                    }
                    RecentRunsView()

                    section("Ordner & Namen")
                    FolderNamingEditor()

                    section("Eigene Ordner")
                    WithHelp(title: "Eigene Ordner", text: "Für Videos, die nicht von einer Kamera stammen – fertige Exporte, Soundeffekte, Bildschirmaufnahmen, Interviews … Kennt CamSort einen Clip nicht, kannst du ihn im Rückfrage-Fenster mit einem Klick in einen dieser Ordner legen. Mit „Merken“ landen gleichartige Dateien künftig automatisch dort. Die Ordner liegen im jeweiligen Dreh neben „Videos“.") {
                        Text("Ordner für Exporte, Soundeffekte & Co.").font(.system(size: 12))
                    }
                    SpecialFoldersEditor()

                    section("Final Cut")
                    FCPLibrarySettings()

                    section("Beste Momente")
                    SelectsSettingsBlock()

                    section("Verschlagworten")
                    WithHelp(title: "Verschlagworten aktivieren", text: "An: Nach dem Sortieren erscheint der Knopf „Clips verschlagworten“. CamSort erkennt dann lokal und offline, was in den Clips zu sehen ist (Person, Auto, Motorrad, Straße …), liest Schriftzüge und erkennt so Automarken, und ergänzt alles als Finder-Tags. Die Videodateien werden dabei nicht verändert.\n\nIn Final Cut beim Import „Finder-Tags als Schlagwörter“ anhaken, dann stehen die Begriffe dort direkt als Schlagwörter bereit.\n\nAus: Kein Knopf, keine Analyse.") {
                        Toggle("Clips verschlagworten (Finder-Tags)", isOn: $store.enableTagging)
                    }

                    section("Gyroflow")
                    WithHelp(title: "Gyroflow-Option anzeigen", text: "An: Nach dem Sortieren erscheint der Knopf „Sony-Clips mit Gyroflow stabilisieren“.\nAus: Der Knopf wird ausgeblendet – praktisch, wenn du Gyroflow lieber selbst bedienst oder gar nicht nutzt. Das Trennen in Stabilisiert/Original funktioniert trotzdem.") {
                        Toggle("Gyroflow-Knopf nach dem Sortieren anzeigen", isOn: $store.showGyroButton.animation())
                    }
                    GyroPresetBox()
                    GyroNotifyBlock()
                    WithHelp(title: "Ausgabe wie Eingabeclip", text: "Aus deinem Preset übernimmt CamSort nur Glättung und dynamisches Zoomen. Objektivprofil, Auflösung, Format, Framerate, Codec und Ton richten sich nach jedem Clip.\n\nSo passt ein Preset für alle Kameras: Gyroflow wählt das Objektivprofil selbst aus den Metadaten, 4:3-, 1:1- und Hochkant-Clips behalten ihr Format, H.264 bleibt H.264, H.265 bleibt H.265, ProRes bleibt ProRes – mit etwa der Bitrate des Originals und mit Ton. Dein Preset selbst bleibt unverändert.\n\nAus: Gyroflow nutzt das Preset komplett (auch Objektiv, Größe und Export-Format daraus).") {
                        Toggle("Ausgabe wie Eingabeclip (empfohlen)", isOn: $store.gyroMatchSource)
                    }
                    WithHelp(title: "Gyroflow-App", text: "CamSort sucht Gyroflow automatisch im Programme-Ordner. Nur falls Gyroflow woanders liegt, hier die Gyroflow-App auswählen.") {
                        HStack {
                            Text(store.gyroAppPath.isEmpty ? "Gyroflow-App: automatisch (Programme-Ordner)" : "Gyroflow-App: " + (store.gyroAppPath as NSString).lastPathComponent)
                                .font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Button("Wählen …") {
                                let p = NSOpenPanel()
                                p.allowedContentTypes = [.application]
                                p.directoryURL = URL(fileURLWithPath: "/Applications")
                                if p.runModal() == .OK, let u = p.url { store.gyroAppPath = u.path }
                            }.controlSize(.small)
                        }
                    }
                    WithHelp(title: "Automatisch trennen", text: "Bei jedem Sortier-Durchlauf schaut CamSort zusätzlich nach, ob Gyroflow irgendwo stabilisierte Clips erzeugt hat, und trennt dort in „Stabilisiert“, „Original“ und „Gyroflow-Projekte“. Ordner ohne stabilisierte Clips bleiben unverändert.") {
                        Toggle("Gyroflow-Clips automatisch trennen", isOn: $store.autoGyro)
                    }
                    WithHelp(title: "Endungen stabilisierter Dateien", text: "Daran erkennt CamSort, welche Clips von Gyroflow stammen: Enthält der Dateiname eine dieser Endungen, gilt er als stabilisiert. Mehrere Endungen mit Komma trennen. Die erste Endung verwendet CamSort auch selbst, wenn es Gyroflow rendern lässt.") {
                        TextField("Endungen stabilisierter Dateien", text: $store.gyroSuffixes).textFieldStyle(.roundedBorder)
                    }

                    if !store.compactLayout {
                        section("Drohne (ausführliche Struktur)")
                        Toggle("Drohnen-Clips nach Geschwindigkeit sortieren", isOn: $store.droneBySpeed.animation())
                        Toggle("Videos zusätzlich nach Objektiv sortieren", isOn: $store.sortByLens)
                        if store.droneBySpeed {
                            SpeedRange(title: "Stand", icon: "pause.circle.fill", min: $store.standMin, max: $store.standMax, limit: 30)
                            SpeedRange(title: "Fahrt", icon: "airplane", min: $store.moveMin, max: $store.moveMax, limit: 150)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            HStack { Spacer(); Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(.top, 10)
        }
        .toggleStyle(.switch)
        .padding(22)
        .frame(width: 480, height: 620)
    }

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

struct GyroPresetBox: View {
    @EnvironmentObject var store: LearnedStore
    @State private var migrated = false
    @State private var showGuide = false
    private var ok: Bool { !store.gyroPresetPath.isEmpty && FileManager.default.fileExists(atPath: store.gyroPresetPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(ok ? "Preset gespeichert: " + (store.gyroPresetPath as NSString).lastPathComponent : "Noch kein Gyroflow-Preset hinterlegt")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                HelpButton(title: "Gyroflow-Preset", text: "Das Preset ist eine kleine Datei (Endung .gyroflow), in der deine gewohnten Gyroflow-Einstellungen stehen. Bei „Ausgabe wie Eingabeclip“ (Standard) übernimmt CamSort daraus nur Glättung und dynamisches Zoomen – Objektivprofil, Auflösung, Framerate, Codec und Ton richten sich nach jedem Clip. An deinen Einstellungen in Gyroflow und an der Preset-Datei ändert sich nichts.")
            }
            HStack {
                Button(ok ? "Anderes Preset wählen …" : "Preset-Datei wählen …") { choose() }
                Button(showGuide ? "Anleitung ausblenden" : "Wie bekomme ich das Preset?") { withAnimation { showGuide.toggle() } }
                    .buttonStyle(.link)
            }
            .controlSize(.small)
            if showGuide || !ok {
                VStack(alignment: .leading, spacing: 5) {
                    Text("So legst du das Preset an (einmalig, ca. 1 Minute):").font(.system(size: 11, weight: .semibold))
                    step(1, "Gyroflow öffnen und einen Sony-Clip hineinziehen.")
                    step(2, "Kontrollieren, dass alles so eingestellt ist wie immer (Objektivprofil, Glättung, Export-Einstellungen).")
                    step(3, "Unten rechts auf den kleinen Pfeil am Knopf „Export“ klicken und „Create settings preset“ (Einstellungs-Preset erstellen) wählen.")
                    step(4, "Im folgenden Fenster alle Haken setzen – besonders bei den Export-/Ausgabe-Einstellungen (Codec, Bitrate). Dann fragt Gyroflow später nicht mehr pro Datei nach.")
                    step(5, "Datei z. B. als „Sony.gyroflow“ an einem festen Ort speichern, etwa im Ordner Dokumente.")
                    step(6, "Hier in CamSort auf „Preset-Datei wählen …“ klicken und genau diese Datei auswählen.")
                    Text("CamSort speichert sich eine eigene Kopie des Presets – du kannst die Datei danach verschieben oder löschen. Ändern sich deine Gyroflow-Einstellungen, das neue Preset einfach hier erneut wählen.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
        .onAppear { if !migrated { store.migratePresetIfNeeded(); migrated = true } }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(ok ? Color.green.opacity(0.4) : Color.orange.opacity(0.6)))
    }

    private func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n).").font(.system(size: 11, weight: .bold)).frame(width: 14, alignment: .trailing)
            Text(t).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.message = "Gyroflow-Preset (.gyroflow) auswählen"
        if p.runModal() == .OK, let u = p.url {
            if let err = store.importPreset(from: u) {
                let a = NSAlert(); a.messageText = "Preset konnte nicht übernommen werden"
                a.informativeText = err; a.runModal()
            }
        }
    }
}

struct SpeedRange: View {
    let title: String
    let icon: String
    @Binding var min: Double
    @Binding var max: Double
    let limit: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(title): \(Int(min)) – \(Int(max)) km/h", systemImage: icon).font(.system(size: 13, weight: .semibold))
            HStack {
                Text("von").font(.system(size: 11)).frame(width: 26, alignment: .leading)
                Slider(value: Binding(get: { min }, set: { min = Swift.min($0, max) }), in: 0...limit, step: 1)
            }
            HStack {
                Text("bis").font(.system(size: 11)).frame(width: 26, alignment: .leading)
                Slider(value: Binding(get: { max }, set: { max = Swift.max($0, min) }), in: 0...limit, step: 1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}


/// Im Screenshot-Modus ohne ScrollView (ImageRenderer zeichnet ScrollViews nicht).
struct MaybeScroll<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        #if SCREENSHOT
        content
        #else
        ScrollView(showsIndicators: false) { content }
        #endif
    }
}


/// Ordner-Knöpfe für „kein Kamera-Clip“ + eigenen Ordner anlegen
struct FlowFolders: View {
    let folders: [String]
    @Binding var newFolder: String
    let pick: (String) -> Void
    let add: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(folders, id: \.self) { f in
                    Button { pick(f) } label: {
                        Label(f, systemImage: f.lowercased().contains("sound") ? "speaker.wave.2.fill"
                              : f.lowercased().contains("bildschirm") ? "display" : "folder.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered).tint(.orange).controlSize(.small)
                }
            }
            HStack {
                TextField("Neuer Ordner, z. B. Interviews", text: $newFolder).textFieldStyle(.roundedBorder)
                    .onSubmit { if !newFolder.isEmpty { add(newFolder) } }
                Button("Anlegen & hineinlegen") { add(newFolder) }
                    .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }
}

/// Eigene Ordner in den Einstellungen verwalten
struct SpecialFoldersEditor: View {
    @EnvironmentObject var store: LearnedStore
    @State private var new = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.specialFolders, id: \.self) { f in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.orange)
                    Text(f).font(.system(size: 12))
                    Spacer()
                    Button { store.specialFolders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Neuer Ordner", text: $new).textFieldStyle(.roundedBorder)
                Button("Hinzufügen") { store.addFolder(new); new = "" }.disabled(new.trimmingCharacters(in: .whitespaces).isEmpty)
            }.controlSize(.small)
        }
    }
}


/// Nach dem Sortieren: Final Cut findet verschobene Clips mit „Dateien neu verknüpfen“ in einem Schritt wieder.
struct FCPRelinkCard: View {
    let libraries: [URL]
    @State private var open = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { open.toggle() } } label: {
                HStack {
                    Image(systemName: "link.badge.plus")
                    Text("Final Cut: Clips neu verknüpfen (1 Minute)").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                Text("In diesem Ordner liegt eine Final-Cut-Mediathek. Weil Clips verschoben wurden, zeigt Final Cut sie evtl. als „fehlend“. So verknüpfst du alle auf einmal:")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("1. Mediathek öffnen (Knopf unten) und links die Mediathek auswählen.")
                    Text("2. Menü Ablage › Dateien neu verknüpfen › Originalmedien …")
                    Text("3. „Alle“ wählen › „Ort auswählen …“ › den Dreh- bzw. Kundenordner wählen.")
                    Text("4. Final Cut findet alle Clips in den Unterordnern selbst › „Dateien neu verknüpfen“.")
                }
                .font(.system(size: 11))
                HStack {
                    ForEach(libraries.prefix(3), id: \.self) { lib in
                        Button { NSWorkspace.shared.open(lib) } label: {
                            Label(lib.deletingPathExtension().lastPathComponent, systemImage: "film.stack")
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.orange.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.orange.opacity(0.6)))
    }
}


/// Ordnernamen und Benennung anpassen – mit Live-Vorschau
struct FolderNamingEditor: View {
    @AppStorage("fnVideos") private var videos = "Videos"
    @AppStorage("fnPhotos") private var photos = "Fotos"
    @AppStorage("fnSide") private var side = "Begleitdateien"
    @AppStorage("fnExtras") private var extras = "Extras"
    @AppStorage("fnSquare") private var square = "Quadratisch"
    @AppStorage("fnFps") private var fpsTemplate = "{n} fps"
    @AppStorage("fnSeparator") private var separator = " · "
    @AppStorage("fnShowCamera") private var showCamera = true
    @AppStorage("fnShowOrientation") private var showOrientation = true
    @AppStorage("fnSceneWord") private var sceneWord = "Szene"
    @AppStorage("fnSceneTime") private var sceneTime = true
    @AppStorage("fnSceneCams") private var sceneCams = true
    @EnvironmentObject var store: LearnedStore

    private var sampleCamFolder: String {
        var p: [String] = []
        if showCamera { p.append("Sony Alpha 1") }
        if store.sortByLens { p.append("FE 24-70") }
        if showOrientation { p.append("Quer") }
        return p.isEmpty ? "Sony Alpha 1" : p.joined(separator: separator)
    }
    private var sampleScene: String {
        var p = ["\(sceneWord.isEmpty ? "Szene" : sceneWord) 01"]
        if sceneTime { p.append("10.14") }
        if sceneCams { p.append("Sony Alpha 1 + Sony ZV-E1") }
        return p.joined(separator: separator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WithHelp(title: "Ordnernamen", text: "So heißen die Ordner, die CamSort in jedem Dreh anlegt. Bereits sortierte Ordner mit den alten Standardnamen erkennt CamSort weiterhin.") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow { Text("Videos").font(.system(size: 11)); TextField("Videos", text: $videos) }
                    GridRow { Text("Fotos").font(.system(size: 11)); TextField("Fotos", text: $photos) }
                    GridRow { Text("Begleitdateien").font(.system(size: 11)); TextField("Begleitdateien", text: $side) }
                    GridRow { Text("Extras").font(.system(size: 11)); TextField("Extras", text: $extras) }
                    GridRow { Text("Quadratisch").font(.system(size: 11)); TextField("Quadratisch", text: $square) }
                    GridRow { Text("Framerate").font(.system(size: 11)); TextField("{n} fps", text: $fpsTemplate) }
                }
                .textFieldStyle(.roundedBorder).controlSize(.small)
            }
            WithHelp(title: "Quadratisch", text: "Quadratisch aufgenommen – daraus lassen sich Hochkant und Quer schneiden (z. B. DJI Osmo Action 6 mit 3840×3840). CamSort legt Clips mit einem Seitenverhältnis zwischen 0,9 und 1,1 in diesen Ordner. Ab 1,1 gilt: breiter = Quer (auch 4:3), höher = Hochkant (auch 3:4). Gyroflow lässt quadratische und 4:3-Clips im Originalformat, wenn das unter Gyroflow eingestellt ist.") {
                Text("Ordner für 1:1-Clips").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            WithHelp(title: "Ordnername Framerate", text: "Schablone für FPS-Ordner: {n} wird durch die Framerate ersetzt. „{n} fps“ → „50 fps“, „{n}p“ → „50p“. Ohne {n} gilt „{n} fps“. Ordner mit dem alten Standardnamen („50 fps“) erkennt CamSort weiterhin als sortiert.") {
                Text("→ \(fpsTemplate.contains("{n}") ? fpsTemplate.replacingOccurrences(of: "{n}", with: "50") : "50 fps")").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            WithHelp(title: "Ordnername bei „Szene“", text: "Wie Szenen-Ordner heißen. Statt „Szene“ geht z. B. auch „Take“ oder „Einstellung“.") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Wort").font(.system(size: 11)); TextField("Szene", text: $sceneWord).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 120) }
                    Toggle("Uhrzeit im Namen", isOn: $sceneTime)
                    Toggle("Kameras im Namen", isOn: $sceneCams)
                }.font(.system(size: 12))
            }
            WithHelp(title: "Trennzeichen", text: "Zeichen zwischen den Teilen eines Ordnernamens.") {
                Text("Trennzeichen").font(.system(size: 12)).fixedSize()
                Picker("Trennzeichen", selection: $separator) {
                    Text("·").tag(" · "); Text("-").tag(" - "); Text("_").tag("_"); Text("|").tag(" | ")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Vorschau").font(.system(size: 11, weight: .semibold))
                Text("Dreh/\(videos)/\(LevelBuilder.samplePath(store, separator: separator))C0001.MP4")
                Text("Dreh/\(photos)/ · Dreh/\(side)/ · Dreh/\(extras)/")
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}


/// Ordner-Baukasten: Kriterien an/aus, Reihenfolge, ein Ordner oder Unterordner – mit Vorschau
struct LevelBuilder: View {
    @AppStorage("useVideosFolder") private var useVideosFolderPreview = true
    @EnvironmentObject var store: LearnedStore
    @AppStorage("fnSeparator") private var separator = " · "

    static func sample(_ id: String, _ s: LearnedStore) -> String {
        switch id {
        case "scene": return "Szene 02 · 10.14 · Sony Alpha 1 + Sony ZV-E1"
        case "camera": return "Sony Alpha 1"
        case "lens": return "FE 24-70"
        case "length": return s.lengthShort
        case "orientation": return "Quer"
        case "speed": return "Fahrt"
        case "date": return s.dayString(Date())
        case "fps": return FolderNames.fpsName(50)
        default: return id
        }
    }
    static func samplePath(_ s: LearnedStore, separator: String) -> String {
        let parts = s.levels.map { sample($0, s) }
        if parts.isEmpty { return "" }
        return (s.nestLevels ? parts.joined(separator: "/") : parts.joined(separator: separator)) + "/"
    }

    private var ordered: [(id: String, name: String, icon: String)] {
        let on = store.levels.compactMap { id in LearnedStore.allLevels.first { $0.id == id } }
        let off = LearnedStore.allLevels.filter { !store.levels.contains($0.id) }
        return on + off
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WithHelp(title: "Ordner-Aufbau", text: "Hier legst du fest, wonach die Videos in jedem Dreh geordnet werden. Kriterien einschalten und mit den Pfeilen sortieren – oben = zuerst.\n\n„Ein Ordner“: alles steht in EINEM Ordnernamen (z. B. Szene 02 · Einblendungen). „Unterordner“: jedes Kriterium ist eine eigene Ebene (Szene 02 / Einblendungen).\n\nWas nicht im Ordner steht (z. B. Kamera, Hochkant/Quer), kommt als Finder-Tag an den Clip. Jeder Clip liegt nur einmal vor – nichts wird kopiert. Beim nächsten „Aktualisieren“ ordnet CamSort bestehende Drehs nach dem neuen Aufbau um.") {
                Text("Aufbau").font(.system(size: 12)).fixedSize()
                Picker("Aufbau", selection: $store.nestLevels) {
                    Text("Ein Ordner").tag(false); Text("Unterordner").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            ForEach(ordered, id: \.id) { lvl in
                let on = store.levels.contains(lvl.id)
                let idx = store.levels.firstIndex(of: lvl.id)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label(lvl.name, systemImage: lvl.icon).font(.system(size: 12))
                            .lineLimit(1).foregroundStyle(on ? .primary : .secondary)
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            if let i = idx {
                                Text("\(i + 1).").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                Button { store.levels.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(i == 0)
                                Button { store.levels.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(i == store.levels.count - 1)
                            }
                        }
                        .frame(width: 70, alignment: .trailing)
                        Toggle(lvl.name, isOn: Binding(get: { on }, set: { v in
                            if v { store.levels.append(lvl.id) } else { store.levels.removeAll { $0 == lvl.id } }
                        })).labelsHidden()
                    }
                    .buttonStyle(.borderless)
                    if on && lvl.id == "scene" {
                        Stepper("Neue Szene nach \(Int(store.sceneGapMinutes)) Min. Pause", value: $store.sceneGapMinutes, in: 1...60, step: 1)
                            .font(.system(size: 11)).padding(.leading, 26)
                    }
                    if on && lvl.id == "length" {
                        VStack(alignment: .leading, spacing: 4) {
                            Stepper("Kurz bis \(Int(store.lengthThreshold)) Sek.", value: $store.lengthThreshold, in: 5...600, step: 5)
                            HStack {
                                TextField("Kurz", text: $store.lengthShort).frame(width: 130)
                                Text("bis \(Int(store.lengthThreshold)) s · darüber").fixedSize()
                                TextField("Lang", text: $store.lengthLong).frame(width: 110)
                            }.textFieldStyle(.roundedBorder)
                        }
                        .font(.system(size: 11)).controlSize(.small).padding(.leading, 26)
                    }
                    if on && lvl.id == "fps" {
                        WithHelp(title: "Framerate (FPS)", text: "Ordnet Clips nach ihrer Framerate, z. B. „25 fps“, „50 fps“, „100 fps“. Gerundet wird auf feste Klassen: 23,976 und 24 → 24 fps, 29,97 → 30, 59,94 → 60, 119,88 → 120 (außerdem 25, 48, 50, 100, 200, 240). 24 und 25 oder 48 und 50 werden nie zusammengelegt.\n\nSony-Zeitlupe (S&Q): Die Datei hat z. B. 25p, aufgenommen wurde aber mit 100p – CamSort liest die Aufnahme-Framerate aus dem Sony-XML und legt den Clip in „100 fps“.\n\nClips ohne feste Framerate (manche Bildschirmaufnahmen) kommen in „\(FolderNames.fpsVariable)“. Den Ordnernamen stellst du unter „Ordnernamen“ ein.") {
                            Text("z. B. \(FolderNames.fpsName(25)), \(FolderNames.fpsName(50)), \(FolderNames.fpsName(100))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.leading, 26)
                    }
                    if on && lvl.id == "speed" {
                        VStack {
                            SpeedRange(title: "Stand", icon: "pause.circle.fill", min: $store.standMin, max: $store.standMax, limit: 30)
                            SpeedRange(title: "Fahrt", icon: "airplane", min: $store.moveMin, max: $store.moveMax, limit: 150)
                        }.padding(.leading, 26)
                    }
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            Text("Vorschau: Dreh/\(useVideosFolderPreview ? FolderNames.videos + "/" : "")\(LevelBuilder.samplePath(store, separator: separator))C0001.MP4")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}


struct SelectsSettingsBlock: View {
    @AppStorage("selEnabled") private var enabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Knopf „Beste Momente finden“ nach dem Sortieren", isOn: $enabled).toggleStyle(.switch).font(.system(size: 12))
            if enabled { SelectsSettings() }
        }
    }
}


// MARK: - Letzte Läufe (Einstellungen)

struct RecentRunsView: View {
    @State private var runs: [RunInfo] = []
    @State private var confirm: RunInfo?
    @State private var result: String = ""
    static let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Letzte Läufe").font(.system(size: 12, weight: .semibold))
            if runs.isEmpty { Text("Noch keine Läufe protokolliert").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(runs.prefix(15)) { r in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.df.string(from: r.date)) · \(r.title) · \(plural(r.files, "Datei", "Dateien"))").font(.system(size: 11, weight: .medium))
                        Text(r.folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if r.undone { Text("rückgängig gemacht").font(.system(size: 10)).foregroundStyle(.secondary) }
                    else if JournalStore.canUndo(r, among: runs) { Button("Rückgängig") { confirm = r }.controlSize(.small) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([r.url]) } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.plain).help("Protokoll im Finder zeigen")
                }
            }
            if !result.isEmpty { Text(result).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { runs = JournalStore.appRuns() }
        .alert("Rückgängig machen?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { r in
            Button("Rückgängig machen") {
                let rep = UndoService.undoApp(r.url)
                var t = "\(plural(rep.restored, "Datei", "Dateien")) zurückgelegt, \(plural(rep.removedDirs, "leerer Ordner", "leere Ordner")) entfernt."
                if !rep.skipped.isEmpty { t += " Übersprungen: " + rep.skipped.joined(separator: " · ") }
                if !rep.fcpLibraries.isEmpty { t += " Final Cut: Mediatheken ggf. neu verknüpfen (" + rep.fcpLibraries.map(\.lastPathComponent).joined(separator: ", ") + ")." }
                result = t
                runs = JournalStore.appRuns(); confirm = nil
            }
            Button("Abbrechen", role: .cancel) { confirm = nil }
        } message: { r in
            Text("\(plural(UndoEngine.preview(r.url), "Datei geht", "Dateien gehen")) zurück an ihren ursprünglichen Platz. Nichts wird überschrieben.")
        }
    }
}
