import SwiftUI

/// iMessage-Benachrichtigung, sobald Gyroflow mit allen Renderings fertig ist.
/// Läuft als macOS-Hintergrunddienst (LaunchAgent) – auch wenn CamSort geschlossen ist.
/// Erkennt sowohl Renderings, die CamSort startet (Gyroflow-Befehlszeile), als auch
/// Renderings direkt in der Gyroflow-App (hohe Rechenlast).
@MainActor
final class GyroNotifier: ObservableObject {
    static let shared = GyroNotifier()
    static let label = "de.camsort.gyromelder"

    @Published var number: String { didSet { UserDefaults.standard.set(number, forKey: "notifyNumber") } }
    @Published private(set) var active = false
    @Published var message: String?

    private let fm = FileManager.default
    private var dir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamSort/Benachrichtigung")
    }
    private var script: URL { dir.appendingPathComponent("melder.sh") }
    private var plist: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    init() {
        number = UserDefaults.standard.string(forKey: "notifyNumber") ?? ""
        active = fm.fileExists(atPath: plist.path)
    }

    var cleanNumber: String {
        number.filter { $0.isNumber || $0 == "+" || $0 == "@" || $0 == "." || $0.isLetter }
    }

    func enable() {
        guard cleanNumber.count >= 5 else { message = "Bitte eine Handynummer (z. B. +4917…) oder Apple-ID-E-Mail eintragen."; return }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try cleanNumber.write(to: dir.appendingPathComponent("nummer"), atomically: true, encoding: .utf8)
            try Self.scriptText.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let p: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": ["/bin/bash", script.path],
                "StartInterval": 30,
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
            // Testnachricht beim ersten Lauf – so fragt macOS einmalig nach der Erlaubnis für „Nachrichten“
            fm.createFile(atPath: dir.appendingPathComponent("test").path, contents: Data())
            launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
            launchctl(["bootstrap", "gui/\(getuid())", plist.path])
            active = true
            message = "Aktiv. Du bekommst gleich eine Testnachricht. Falls macOS fragt, ob „Nachrichten“ gesteuert werden darf: Erlauben."
        } catch {
            message = "Einrichten fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func disable() {
        launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        try? fm.removeItem(at: plist)
        try? fm.removeItem(at: dir.appendingPathComponent("zustand"))
        active = false
        message = "Ausgeschaltet. Es laufen keine Hintergrundprüfungen mehr."
    }

    func sendTest() {
        fm.createFile(atPath: dir.appendingPathComponent("test").path, contents: Data())
        launchctl(["kickstart", "-k", "gui/\(getuid())/\(Self.label)"])
        message = "Testnachricht wird gesendet …"
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    /// Bash 3.2 (macOS-Standard). Alle 30 s: läuft Gyroflow? Wenn es lief und seit 90 s ruht → eine Nachricht.
    static let scriptText = #"""
#!/bin/bash
DIR="$HOME/Library/Application Support/CamSort/Benachrichtigung"
NUM=$(cat "$DIR/nummer" 2>/dev/null)
[ -z "$NUM" ] && exit 0
STATE="$DIR/zustand"

send() {
/usr/bin/osascript - "$NUM" "$1" <<'EOF'
on run argv
  tell application "Messages"
    set s to 1st account whose service type = iMessage
    send (item 2 of argv) to participant (item 1 of argv) of s
  end tell
end run
EOF
}

if [ -f "$DIR/test" ]; then
  rm -f "$DIR/test"
  send "CamSort: Benachrichtigung ist aktiv ✅ Du bekommst eine Nachricht, sobald Gyroflow fertig ist."
fi

busy=0
# Renderings über die Gyroflow-Befehlszeile (von CamSort gestartet)
pgrep -fi "gyroflow.*(--stdout-progress|--preset)" >/dev/null && busy=1
# Renderings direkt in der Gyroflow-App: hohe Rechenlast
cpu=$(ps -Ao pcpu=,comm= | awk 'tolower($0) ~ /gyroflow/ {s+=$1} END {print int(s+0)}')
[ "${cpu:-0}" -ge 80 ] && busy=1

start=""; idle=0
[ -f "$STATE" ] && read start idle < "$STATE"
now=$(date +%s)

if [ $busy -eq 1 ]; then
  [ -z "$start" ] && start=$now
  echo "$start 0" > "$STATE"
  exit 0
fi

[ -z "$start" ] && exit 0
idle=$((idle + 1))
if [ $idle -ge 3 ]; then
  mins=$(( (now - start) / 60 ))
  send "🎬 Gyroflow ist fertig – alle Clips sind gerendert ($(date +%H:%M) Uhr, Dauer ca. ${mins} Min.)."
  rm -f "$STATE"
else
  echo "$start $idle" > "$STATE"
fi
"""#
}

struct GyroNotifyBlock: View {
    @StateObject private var n = GyroNotifier.shared
    var body: some View {
        WithHelp(title: "iMessage, wenn Gyroflow fertig ist", text: "Einmal einschalten, dann schickt dir dein Mac eine iMessage an die eingetragene Nummer, sobald Gyroflow alle Clips fertig gerendert hat – egal ob CamSort das Rendern gestartet hat oder du direkt in Gyroflow renderst.\n\nDas läuft als kleiner Hintergrunddienst weiter, auch wenn CamSort geschlossen ist und nach einem Neustart. Mit „Ausschalten“ wird er vollständig entfernt.\n\nVoraussetzung: Die Nachrichten-App ist auf diesem Mac mit deiner Apple-ID angemeldet. Beim ersten Mal fragt macOS, ob „Nachrichten“ gesteuert werden darf – bitte erlauben.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: n.active ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(n.active ? .green : .secondary)
                    Text(n.active ? "Benachrichtigung aktiv" : "Benachrichtigung aus").font(.system(size: 12, weight: .semibold))
                }
                HStack {
                    TextField("Handynummer, z. B. +49 171 1234567", text: $n.number)
                        .textFieldStyle(.roundedBorder).disabled(n.active)
                    if n.active {
                        Button("Test") { n.sendTest() }
                        Button("Ausschalten", role: .destructive) { n.disable() }
                    } else {
                        Button("Einschalten") { n.enable() }.buttonStyle(.borderedProminent)
                    }
                }
                if let m = n.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }
}
