import SwiftUI
import AppKit

@main
struct CamSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: LearnedStore
    @StateObject private var sorter: Sorter
    @StateObject private var theme = ThemeSettings()

    init() {
        let s = LearnedStore()
        _store = StateObject(wrappedValue: s)
        _sorter = StateObject(wrappedValue: Sorter(store: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sorter)
                .environmentObject(store)
                .environmentObject(theme)
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

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Header()
                    .padding(.top, 34)
                Group {
                    switch sorter.phase {
                    case .idle: IdleView()
                    case .scanning, .sorting: SortingView()
                    case .done, .cancelled: DoneView()
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
    @EnvironmentObject var sorter: Sorter
    @EnvironmentObject var store: LearnedStore
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

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auch Unterordner durchsuchen", isOn: $store.includeSubfolders)
                Toggle("Bei neuen Kameras nachfragen und Namen merken", isOn: $store.confirmCameras)
                Toggle("Videos zusätzlich nach Objektiv sortieren", isOn: $store.sortByLens)
                    .help("Videos/<Kamera>/<Objektiv>/Hochkant|Quer – klappt, wenn die Kamera das Objektiv speichert (z. B. Sony)")
            }
            .toggleStyle(.switch).controlSize(.small)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button { sorter.start() } label: {
                Label("Sortieren starten", systemImage: "wand.and.stars")
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
    private var items: [(key: String, icon: String, color: Color, n: Int)] {
        var r: [(key: String, icon: String, color: Color, n: Int)] = [
            ("Hochkant", "rectangle.portrait.fill", Theme.mint, sorter.counts["Hochkant"] ?? 0),
            ("Quer", "rectangle.fill", Theme.orange, sorter.counts["Quer"] ?? 0),
            ("Fotos", "photo.fill", Color(red: 0.6, green: 0.7, blue: 1), sorter.counts["Fotos"] ?? 0),
        ]
        if let v = sorter.counts["Video"], v > 0 { r.append(("Video", "film", .white, v)) }
        let icons = ["XML": "doc.text.fill", "LRF": "film.fill", "SRT": "text.alignleft", "Musik": "music.note",
                     "ZIP": "doc.zipper", "FCP": "film.stack"]
        let keys = Set(["XML", "LRF", "SRT"]).union(sorter.sideCounts.keys).sorted()
        for k in keys { r.append((k, icons[k] ?? "doc.fill", .white, sorter.sideCounts[k] ?? 0)) }
        return r
    }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(items, id: \.key) { item in
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
    @State private var pop = false
    @State private var showProblems = true

    var cancelled: Bool { sorter.phase == .cancelled }
    var hasProblems: Bool { !sorter.problems.isEmpty }
    var accent: Color { cancelled || hasProblems ? Theme.orange : Theme.mint }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(showsIndicators: false) {
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

                    CountGrid()

                    if !sorter.cameras.isEmpty {
                        FlowChips(items: sorter.cameras.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
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
            Toggle("Merken – künftig automatisch so einsortieren (\(request.signatureLabel))", isOn: $remember)
                .font(.system(size: 11))
            HStack {
                Button(request.suggestion.isEmpty ? "Als „Unbekannt“ einsortieren" : "Diesmal nicht merken") { sorter.answerCamera(request.suggestion.isEmpty ? nil : request.suggestion, remember: false) }
                Spacer()
                Button("Übernehmen") { sorter.answerCamera(name, remember: remember) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
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
