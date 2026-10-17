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

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Header()
                    .padding(.top, 34)
                Group {
                    if importer.active {
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
    }
}

struct Header: View {
    @EnvironmentObject var store: LearnedStore
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
                Text("Videos & Fotos automatisch sortieren")
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
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { appear = true } }
    }
}

// MARK: - Start

struct IdleView: View {
    @EnvironmentObject var timeline: TimelineModel
    @EnvironmentObject var browser: ClipBrowser
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var store: LearnedStore
    @EnvironmentObject var importer: ImportRunner
    @State private var showSettings = false

    private var settingsSummary: String {
        var p: [String] = []
        p.append(store.includeSubfolders ? "mit Unterordnern" : "ohne Unterordner")
        if store.confirmCameras { p.append("Kameras nachfragen") }
        if store.sortByLens { p.append("nach Objektiv") }
        if store.droneBySpeed { p.append("Drohne: Stand/Fahrt") }
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
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: 140)
            }

            Button { showSettings = true } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                    Text(settingsSummary).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }

            HStack(spacing: 8) {
                Button { importer.open() } label: {
                    Label("Von Speicherkarte importieren", systemImage: "sdcard.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }
                .buttonStyle(.plain)
                HelpButton(title: "Von Speicherkarte importieren",
                           text: "Zeigt alle Aufnahmetage auf der Karte mit Anzahl und Größe. Du hakst an, welche Tage übernommen werden – alte Aufnahmen auf der Karte bleiben einfach liegen. CamSort kopiert, prüft jede Kopie und sortiert danach automatisch. Die Karte selbst wird nie verändert.")
            }

            Spacer(minLength: 0)

            Button { sorter.start() } label: {
                Label(sorter.folders.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Videos").path) }
                      ? "Aktualisieren" : "Sortieren starten", systemImage: "wand.and.stars")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Theme.orange, Color(red: 1, green: 0.5, blue: 0.3)],
                                             startPoint: .leading, endPoint: .trailing)))
                    .foregroundStyle(.white)
                    .opacity(sorter.folders.isEmpty ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(sorter.folders.isEmpty)

            if sorter.folders.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Videos").path) }) {
                HStack(spacing: 10) {
                    Button { timeline.open(folders: sorter.folders) } label: {
                        Label("Zeitleiste", systemImage: "clock.arrow.2.circlepath")
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    }.buttonStyle(.plain)
                    Button { browser.open(folders: sorter.folders) } label: {
                        Label("Ansehen & drehen", systemImage: "rotate.right")
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    }.buttonStyle(.plain)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            if (store.autoGyro || store.showGyroButton),
               sorter.folders.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Videos").path) }) {
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
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
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
    @EnvironmentObject var store: LearnedStore
    @State private var pop = false
    @State private var showProblems = true

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

                    if !sorter.cameras.isEmpty {
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

            if !cancelled && !sorter.fcpLibraries.isEmpty && sorter.movedVideos > 0 {
                FCPRelinkCard(libraries: sorter.fcpLibraries)
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
                    Button { gyro.start(folders: sorter.folders) } label: {
                        Label("Sony-Clips mit Gyroflow stabilisieren", systemImage: "gyroscope")
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
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
                Button { browser.open(folders: sorter.folders) } label: {
                    Label("Ansehen & drehen", systemImage: "rotate.right")
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }.buttonStyle(.plain)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))

            HStack(spacing: 12) {
                Button { sorter.revealInFinder() } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Einstellungen").font(.title2.bold()).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Sortieren")
                    WithHelp(title: "Kompakte Ordner", text: "An (empfohlen): Alle Merkmale stehen in EINEM Ordnernamen statt in verschachtelten Ordnern – z. B. Videos/Sony Alpha 1 · FE 24-70 · Quer. So siehst du sofort, was drin ist, und bist mit einem Klick beim Clip. Neue Ordner entstehen nur, wenn es im Dreh wirklich etwas anderes gibt (zweite Kamera, Hochkant-Clips …). XML, LRF und SRT landen gemeinsam in „Begleitdateien“.\n\nEin Dreh ist jeder Ordner mit Clips – bei Kundenordnern also jeder Unterordner. Kartenordner wie DCIM oder PRIVATE zählen zum Dreh darüber.\n\nAus: ausführliche Struktur mit eigenem Ordner pro Ebene (Videos/Kamera/Quer).") {
                        Toggle("Kompakte Ordner (nur was sich unterscheidet)", isOn: $store.compactLayout)
                    }
                    if store.compactLayout {
                        WithHelp(title: "Videos ordnen nach", text: "Szene: Alles, was zusammenhängend gedreht wurde, landet in einem Ordner – über alle Kameras hinweg, in Aufnahme-Reihenfolge. Ideal, wenn du z. B. Einblendungen mit Kamera A drehst und dann auf Kamera B wechselst. Eine neue Szene beginnt nach einer Drehpause (einstellbar). Kamera und Hochkant/Quer stehen als Finder-Tag an jedem Clip (Spalte „Tags“ im Finder).\n\nKamera: ein Ordner pro Kamera, z. B. Sony Alpha 1 · Quer.\n\nIn beiden Fällen liegt jeder Clip nur einmal vor – nichts wird kopiert.") {
                            Picker("Videos ordnen nach", selection: $store.groupByScene) {
                                Text("Szene").tag(true); Text("Kamera").tag(false)
                            }.pickerStyle(.segmented).frame(width: 220)
                        }
                        if store.groupByScene {
                            Stepper("Neue Szene nach \(Int(store.sceneGapMinutes)) Min. Pause", value: $store.sceneGapMinutes, in: 1...60, step: 1)
                                .font(.system(size: 12))
                        }
                    }
                    Text(!store.compactLayout ? "Beispiel: Dreh 1/Videos/Sony Alpha 1/Quer"
                         : store.groupByScene ? "Beispiel: Dreh 1/Videos/Szene 02 · 10.14 · Sony Alpha 1 + Sony ZV-E1"
                         : "Beispiel: Dreh 1/Videos/Sony Alpha 1 · FE 24-70 · Quer")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    WithHelp(title: "Unterordner durchsuchen", text: "An: CamSort schaut auch in alle Unterordner des gewählten Ordners und sortiert jede Datei in dem Ordner ein, in dem sie liegt. Ordner, die CamSort selbst angelegt hat (Videos, Fotos, XML …), werden dabei übersprungen.\nAus: Nur Dateien, die direkt im gewählten Ordner liegen, werden sortiert.") {
                        Toggle("Auch Unterordner durchsuchen", isOn: $store.includeSubfolders)
                    }
                    WithHelp(title: "Kameras nachfragen", text: "An: Bei jeder neuen Kamera fragt CamSort einmal, unter welchem Namen sie einsortiert werden soll, und merkt sich die Antwort dauerhaft (siehe „Gelernt“ oben rechts).\nAus: Erkannte Kameras werden ohne Rückfrage einsortiert, unbekannte landen in „Unbekannt“.") {
                        Toggle("Bei neuen Kameras nachfragen und Namen merken", isOn: $store.confirmCameras)
                    }
                    WithHelp(title: "Nach Objektiv sortieren", text: "Legt unter jeder Kamera einen zusätzlichen Ordner pro Objektiv an, z. B. Videos/Sony Alpha 1/FE 24-70mm F2.8 GM II/Quer. Klappt nur, wenn die Kamera das Objektiv mitspeichert – bei Sony zuverlässig. Clips ohne Objektiv-Angabe landen in „Objektiv unbekannt“.") {
                        Toggle("Videos zusätzlich nach Objektiv sortieren", isOn: $store.sortByLens)
                    }

                    section("Eigene Ordner")
                    WithHelp(title: "Eigene Ordner", text: "Für Videos, die nicht von einer Kamera stammen – fertige Exporte, Soundeffekte, Bildschirmaufnahmen, Interviews … Kennt CamSort einen Clip nicht, kannst du ihn im Rückfrage-Fenster mit einem Klick in einen dieser Ordner legen. Mit „Merken“ landen gleichartige Dateien künftig automatisch dort. Die Ordner liegen im jeweiligen Dreh neben „Videos“.") {
                        Text("Ordner für Exporte, Soundeffekte & Co.").font(.system(size: 12))
                    }
                    SpecialFoldersEditor()

                    section("Verschlagworten")
                    WithHelp(title: "Verschlagworten aktivieren", text: "An: Nach dem Sortieren erscheint der Knopf „Clips verschlagworten“. CamSort erkennt dann lokal und offline, was in den Clips zu sehen ist (Person, Auto, Motorrad, Straße …), liest Schriftzüge und erkennt so Automarken, und ergänzt alles als Finder-Tags. Die Videodateien werden dabei nicht verändert.\n\nIn Final Cut beim Import „Finder-Tags als Schlagwörter“ anhaken, dann stehen die Begriffe dort direkt als Schlagwörter bereit.\n\nAus: Kein Knopf, keine Analyse.") {
                        Toggle("Clips verschlagworten (Finder-Tags)", isOn: $store.enableTagging)
                    }

                    section("Gyroflow")
                    WithHelp(title: "Gyroflow-Option anzeigen", text: "An: Nach dem Sortieren erscheint der Knopf „Sony-Clips mit Gyroflow stabilisieren“.\nAus: Der Knopf wird ausgeblendet – praktisch, wenn du Gyroflow lieber selbst bedienst oder gar nicht nutzt. Das Trennen in Stabilisiert/Original funktioniert trotzdem.") {
                        Toggle("Gyroflow-Knopf nach dem Sortieren anzeigen", isOn: $store.showGyroButton.animation())
                    }
                    GyroPresetBox()
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

                    section("Drohne")
                    WithHelp(title: "Nach Geschwindigkeit sortieren", text: "CamSort liest die SRT-Datei jedes Drohnen-Clips, berechnet aus den GPS-Positionen die Durchschnittsgeschwindigkeit und legt Ordner „Stand“, „Fahrt“ oder „Dazwischen“ an. Clips ohne GPS-Signal landen in „Ohne GPS“. Die Bereiche stellst du mit den Reglern ein.") {
                        Toggle("Drohnen-Clips nach Geschwindigkeit sortieren", isOn: $store.droneBySpeed.animation())
                    }
                    if store.droneBySpeed {
                        SpeedRange(title: "Stand", icon: "pause.circle.fill", min: $store.standMin, max: $store.standMax, limit: 30)
                        SpeedRange(title: "Fahrt", icon: "airplane", min: $store.moveMin, max: $store.moveMax, limit: 150)
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
    @State private var showGuide = false
    private var ok: Bool { !store.gyroPresetPath.isEmpty && FileManager.default.fileExists(atPath: store.gyroPresetPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(ok ? "Preset: " + (store.gyroPresetPath as NSString).lastPathComponent : "Noch kein Gyroflow-Preset hinterlegt")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                HelpButton(title: "Gyroflow-Preset", text: "Das Preset ist eine kleine Datei (Endung .gyroflow), in der deine gewohnten Gyroflow-Einstellungen stehen – Objektivprofil, Glättung, Export-Format. CamSort gibt sie beim Stabilisieren an Gyroflow weiter, damit alles genauso gerendert wird wie bei dir von Hand. An deinen Einstellungen in Gyroflow ändert sich nichts.")
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
                    Text("Wichtig: Datei danach nicht verschieben oder löschen – CamSort greift bei jedem Stabilisieren darauf zu. Ändern sich deine Einstellungen, einfach neu speichern (gleicher Name überschreibt).")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
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
            if u.pathExtension.lowercased() == "gyroflow" { store.gyroPresetPath = u.path }
            else {
                let a = NSAlert(); a.messageText = "Das ist keine Gyroflow-Preset-Datei"
                a.informativeText = "Bitte eine Datei mit der Endung .gyroflow wählen."; a.runModal()
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
