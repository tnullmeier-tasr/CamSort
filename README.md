# CamSort

**CamSort sortiert Foto- und Videoordner auf dem Mac automatisch – nach Kamera, Ausrichtung und Dateityp. Auf Wunsch stabilisiert es Sony-Clips mit Gyroflow und trennt danach Stabilisiert und Original.** Dateien werden nur verschoben, nie verändert. Läuft komplett offline.

![CamSort nach dem Sortieren](docs/screenshot-fertig.png)

## Installation
1. Lokal bauen: `./build.sh` (Xcode bzw. Command Line Tools nötig) → `build/CamSort.app` (Universal) und `build/CamSort.zip`. **CamSort** in den Programme-Ordner ziehen. Ältere Versionen gibt es unter **Releases**.
2. Einmalig im Terminal (die App ist nicht bei Apple registriert):
   ```
   xattr -dr com.apple.quarantine /Applications/CamSort.app
   ```
3. Benötigt macOS 14 (Sonoma) oder neuer. Läuft auf Apple Silicon und Intel.

> Zum Weitergeben immer die **ZIP-Datei** schicken, nicht die App selbst – sonst geht sie beim Übertragen kaputt.

## Funktionen

| Funktion | Was passiert |
|---|---|
| **Sortieren** | Ordner ins Fenster ziehen → *Sortieren starten*. Videos landen in `Videos/<Kamera>/Hochkant` bzw. `Quer`. |
| **Aktualisieren** | Bei bereits sortierten Ordnern: nur neue Dateien werden einsortiert, Bestehendes bleibt unberührt. |
| **Dateitypen** | Eigene Ordner für `Fotos`, `Musik`, `ZIP`, `FCP` (Final-Cut-Mediatheken/FCPXML) sowie `XML`, `LRF`, `SRT`. Unbekannte Typen fragt CamSort einmal ab und merkt sie sich. |
| **Kameras** | Erkennt Sony (inkl. Modell, z. B. Alpha 1 / ZV-E1), DJI, iPhone, Samsung, Insta360, Canon, GoPro, Pixel u. a. Neue Kameras werden einmal abgefragt und gemerkt. *Gelernt* (oben rechts) zeigt alles Gelernte. |
| **Schnell durch** | Bei Rückfragen: *Nicht mehr fragen – Rest nach bestem Wissen sortieren*. |
| **Duplikate** | Überspringen, beide behalten (`(2)` im Namen) oder ersetzen (alte Datei → Papierkorb) – auch „für alle“. |
| **Unterordner** | Optional werden auch Unterordner durchsucht; jede Datei wird dort einsortiert, wo sie liegt. |
| **Nach Objektiv** | Optional: `Videos/<Kamera>/<Objektiv>/Hochkant|Quer` (zuverlässig bei Sony). |
| **Drohne nach Geschwindigkeit** | Optional: Ø-Geschwindigkeit aus der SRT → `Stand`, `Fahrt`, `Dazwischen` oder `Ohne GPS`. Bereiche per Regler. |
| **Gyroflow stabilisieren** | Nach dem Sortieren: *Sony-Clips mit Gyroflow stabilisieren*. Einzeln nacheinander, erst Hochkant, dann Quer, mit **Pause**. Nutzt dein Gyroflow-Preset – keine Codec-Rückfragen. Danach automatisch `Stabilisiert` / `Original` / `Gyroflow-Projekte`. Der Knopf lässt sich in den Einstellungen mit einem Schalter ausblenden. |
| **Nur Gyroflow trennen** | Wer selbst in Gyroflow rendert: *Nur Gyroflow-Clips trennen*. Erkennt stabilisierte Dateien an Endungen wie `_gyro`, `_stabilized`, `_gyroflow` (einstellbar). |
| **Hilfe** | Jede Einstellung hat ein **?**; das Buch-Symbol oben rechts öffnet die komplette Anleitung. |
| **Farben** | Palette oben rechts: Farbschema oder eigene Hintergrundfarben. |

Alle Einstellungen und alles Gelernte bleiben nach einem Neustart erhalten.

## Gyroflow-Preset einrichten (einmalig)
1. Gyroflow öffnen, einen Sony-Clip hineinziehen, Einstellungen wie gewohnt.
2. Kleiner Pfeil am Knopf **Export** → **Create settings preset**.
3. Alle Haken setzen – besonders bei Export/Codec.
4. Als z. B. `Sony.gyroflow` in *Dokumente* speichern.
5. In CamSort: *Einstellungen › Gyroflow › Preset-Datei wählen …*

Hinweis: Die App-Store-Version von Gyroflow lässt sich evtl. nicht fernsteuern. Dann meldet CamSort das – Abhilfe ist die kostenlose Version von [gyroflow.xyz](https://gyroflow.xyz).

## Ergebnis-Struktur
```
Dein Ordner/
├── Videos/
│   └── Sony Alpha 1/
│       ├── Hochkant/
│       └── Quer/
│           ├── Stabilisiert/
│           ├── Original/
│           └── Gyroflow-Projekte/
├── Fotos/   Musik/   ZIP/   FCP/
└── XML/     LRF/     SRT/
```
