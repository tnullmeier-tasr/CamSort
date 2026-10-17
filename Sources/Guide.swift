import SwiftUI

/// Anleitung – erklärt alle Funktionen in einfachen Worten.
struct GuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String, String)] = [
        ("folder.badge.plus", "Ordner wählen",
         "Ordner ins Fenster ziehen oder klicken und auswählen – auch mehrere auf einmal. CamSort verschiebt Dateien nur, es verändert, löscht oder benennt nichts um."),
        ("wand.and.stars", "Sortieren / Aktualisieren",
         "Videos landen in Videos/<Kamera>/Hochkant bzw. Quer. Fotos, Musik, ZIP-Archive, Final-Cut-Projekte sowie XML-, LRF- und SRT-Begleitdateien bekommen eigene Ordner. Ist ein Ordner schon sortiert, heißt der Knopf „Aktualisieren“ und sortiert nur Neues ein."),
        ("camera.fill", "Kameras erkennen und lernen",
         "Sony (inkl. genauem Modell wie Alpha 1 oder ZV-E1), DJI, iPhone, Samsung, Insta360, Canon, GoPro u. v. m. werden automatisch erkannt. Bei neuen Kameras fragt CamSort einmal nach dem Namen und merkt sich die Antwort. Alles Gelernte siehst und löschst du unter „Gelernt“ oben rechts."),
        ("forward.fill", "Schnell durch",
         "Bei Rückfragen gibt es „Nicht mehr fragen – Rest nach bestem Wissen sortieren“. Dann läuft der Durchlauf ohne weitere Fragen durch."),
        ("doc.on.doc.fill", "Doppelte Dateien",
         "Gibt es eine Datei im Ziel schon, fragt CamSort: überspringen, beide behalten oder ersetzen (alte Datei kommt in den Papierkorb) – auf Wunsch für alle weiteren."),
        ("gyroscope", "Gyroflow",
         "Nach dem Sortieren kann CamSort alle Sony-Clips einzeln nacheinander mit deinem Gyroflow-Preset stabilisieren – erst Hochkant, dann Quer, mit Pause-Knopf. Danach trennt es automatisch in „Stabilisiert“ und „Original“. Wer lieber selbst in Gyroflow rendert, nutzt „Nur Gyroflow-Clips trennen“. Der Gyroflow-Knopf lässt sich in den Einstellungen ausblenden."),
        ("airplane", "Drohnen nach Geschwindigkeit",
         "Optional: Aus der SRT-Datei wird die Durchschnittsgeschwindigkeit berechnet und der Clip in „Stand“, „Fahrt“ oder „Dazwischen“ einsortiert. Clips ohne GPS kommen nach „Ohne GPS“."),
        ("camera.aperture", "Nach Objektiv",
         "Optional: Zusätzlicher Ordner pro Objektiv, z. B. Videos/Sony Alpha 1/FE 24-70mm F2.8 GM II/Quer."),
        ("gearshape.fill", "Einstellungen",
         "Alle Optionen findest du im Startbildschirm unter „Einstellungen“. Jede hat ein ? mit Erklärung. Einstellungen und Gelerntes bleiben auch nach einem Neustart erhalten."),
        ("paintpalette.fill", "Farben",
         "Über die Palette oben rechts wählst du ein Farbschema oder eigene Hintergrundfarben."),
        ("wifi.slash", "Offline",
         "CamSort arbeitet komplett offline. Es wird nichts hochgeladen oder gesendet."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("So funktioniert CamSort").font(.title2.bold())
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items, id: \.1) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.0).font(.system(size: 18)).foregroundStyle(.tint).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.1).font(.system(size: 13, weight: .semibold))
                                Text(item.2).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            HStack { Spacer(); Button("Verstanden") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(.top, 12)
        }
        .padding(22)
        .frame(width: 500, height: 600)
    }
}
