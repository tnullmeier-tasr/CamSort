import SwiftUI
import AppKit

@main
struct CamSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var sorter = Sorter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sorter)
                .frame(width: 560, height: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
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
    }
}

struct Header: View {
    @State private var appear = false
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
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { appear = true } }
    }
}

// MARK: - Start

struct IdleView: View {
    @EnvironmentObject var sorter: Sorter
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
    let items: [(String, String, Color)] = [
        ("Hochkant", "rectangle.portrait.fill", Theme.mint),
        ("Quer", "rectangle.fill", Theme.orange),
        ("Fotos", "photo.fill", Color(red: 0.6, green: 0.7, blue: 1)),
        ("XML", "doc.text.fill", .white),
        ("LRF", "film.fill", .white),
        ("SRT", "text.alignleft", .white),
    ]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(items, id: \.0) { item in
                let n = sorter.counts[item.0] ?? 0
                VStack(spacing: 6) {
                    Image(systemName: item.1).font(.system(size: 18)).foregroundStyle(item.2)
                    Text("\(n)").font(.system(size: 20, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.spring(), value: n)
                    Text(item.0).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .scaleEffect(n > 0 ? 1 : 0.97)
                .opacity(n > 0 ? 1 : 0.55)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: n > 0)
            }
        }
    }
}

// MARK: - Fertig

struct DoneView: View {
    @EnvironmentObject var sorter: Sorter
    @State private var pop = false
    @State private var showProblems = false

    var cancelled: Bool { sorter.phase == .cancelled }
    var hasProblems: Bool { !sorter.problems.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill((cancelled || hasProblems ? Theme.orange : Theme.mint).opacity(0.2))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pop ? 1 : 0.2)
                Image(systemName: cancelled ? "stop.circle.fill"
                                  : hasProblems ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(cancelled || hasProblems ? Theme.orange : Theme.mint)
                    .scaleEffect(pop ? 1 : 0.1)
                    .rotationEffect(.degrees(pop ? 0 : -90))
            }
            .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.5)) { pop = true } }

            Text(cancelled ? "Abgebrochen" : hasProblems ? "Fertig – mit Hinweisen" : "Fertig sortiert!")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("\(sorter.movedTotal) Dateien verschoben"
                 + (sorter.skipped > 0 ? " · \(sorter.skipped) übersprungen" : ""))
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))

            CountGrid()

            if !sorter.cameras.isEmpty {
                HStack(spacing: 8) {
                    ForEach(sorter.cameras.sorted { $0.value > $1.value }, id: \.key) { cam in
                        HStack(spacing: 5) {
                            Image(systemName: cam.key == "iPhone" ? "iphone" : "camera.fill")
                            Text("\(cam.key) \(cam.value)")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.card))
                    }
                }
            }

            if hasProblems {
                Button { withAnimation { showProblems.toggle() } } label: {
                    Label("\(sorter.problems.count) Dateien nicht verschoben", systemImage: showProblems ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.orange)
                }.buttonStyle(.plain)
                if showProblems {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sorter.problems, id: \.self) { Text($0).font(.system(size: 11)) }
                            Text("Diese Dateien liegen unverändert an ihrem alten Platz.")
                                .font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                }
            }

            Spacer(minLength: 0)

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
