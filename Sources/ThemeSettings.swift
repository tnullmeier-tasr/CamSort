import SwiftUI
import AppKit

/// Hintergrundfarben – vom Nutzer wählbar, dauerhaft gespeichert.
final class ThemeSettings: ObservableObject {
    static let presets: [(name: String, top: String, bottom: String)] = [
        ("Nacht", "1F2659", "453B8C"),
        ("Ozean", "0B3D5C", "1B7A8C"),
        ("Wald", "13322A", "2F6B4F"),
        ("Sonnenuntergang", "5A1E3C", "C2553A"),
        ("Graphit", "1C1C1E", "3A3A40"),
        ("Beere", "3B0F3F", "7A2A6E"),
    ]
    @Published var top: Color { didSet { save() } }
    @Published var bottom: Color { didSet { save() } }
    private let d = UserDefaults.standard

    init() {
        top = Color(hex: d.string(forKey: "bgTop") ?? Self.presets[0].top)
        bottom = Color(hex: d.string(forKey: "bgBottom") ?? Self.presets[0].bottom)
    }
    func apply(_ i: Int) { top = Color(hex: Self.presets[i].top); bottom = Color(hex: Self.presets[i].bottom) }
    private func save() { d.set(top.hex, forKey: "bgTop"); d.set(bottom.hex, forKey: "bgBottom") }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "1F2659" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

struct ThemePicker: View {
    @EnvironmentObject var theme: ThemeSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hintergrund").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 10), count: 3), spacing: 10) {
                ForEach(ThemeSettings.presets.indices, id: \.self) { i in
                    let p = ThemeSettings.presets[i]
                    Button { withAnimation(.easeInOut(duration: 0.4)) { theme.apply(i) } } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [Color(hex: p.top), Color(hex: p.bottom)], startPoint: .top, endPoint: .bottom))
                                .frame(width: 64, height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3)))
                            Text(p.name).font(.system(size: 10))
                        }
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            ColorPicker("Oben", selection: $theme.top, supportsOpacity: false)
            ColorPicker("Unten", selection: $theme.bottom, supportsOpacity: false)
        }
        .padding(16)
        .frame(width: 250)
    }
}
