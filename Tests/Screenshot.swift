#if SCREENSHOT && !E2E
import SwiftUI
import AppKit

@main
struct ScreenshotTool {
    @MainActor static func main() {
        _ = NSApplication.shared
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.png") { NSApplication.shared.applicationIconImage = icon }
        let store = LearnedStore()
        store.showGyroButton = true
        store.enableTagging = true
        let sorter = Sorter(store: store)
        let gyro = GyroRunner(store: store, sorter: sorter)
        let theme = ThemeSettings()
        sorter.folders = [URL(fileURLWithPath: "/tmp/Shooting")]
        sorter.counts = ["Hochkant": 38, "Quer": 112, "Fotos": 24]
        sorter.sideCounts = ["XML": 96, "LRF": 21, "SRT": 21]
        sorter.cameras = ["Sony Alpha 1": 74, "Sony ZV-E1": 22, "Mavic 3 Pro": 21, "iPhone": 33]
        sorter.hints = ["Gyroflow-Knopf: schickt die Sony-Clips nacheinander an Gyroflow"]
        sorter.phase = .done
        let view = ContentView()
            .environmentObject(sorter).environmentObject(store).environmentObject(theme).environmentObject(gyro).environmentObject(TagRunner())
            .frame(width: 580, height: 780)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("Rendern fehlgeschlagen"); exit(1)
        }
        try! png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "done.png"))
        print("ok")
    }
}
#endif
