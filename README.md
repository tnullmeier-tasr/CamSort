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

## Modus „Meine Kameraordner“
Für alle, die beim Heimkommen selbst einen Ordner pro Kamera anlegen (z. B. `A1`, `Mini-Drohne`, `Avata`, `ETC`) und die Karten hineinkopieren. Einschalten: *Einstellungen › Sortieren › Meine Kameraordner* oder direkt per Schalter im Startbildschirm. Standard: aus.

- **Dreh-Ordner wählen** (enthält die Kameraordner) → jeder direkte Unterordner ist eine Kamera. **Kameraordner direkt wählen** (enthält selbst Videos oder `PRIVATE`/`DCIM`) → er selbst ist die Kamera. Mehrere Ordner gleichzeitig gehen auch.
- CamSort erkennt, fragt und benennt **keine** Kamera. In jedem Kameraordner landen Videos – auch aus `PRIVATE/M4ROOT/CLIP`, `DCIM/100MEDIA`, `DCIM/DJI_001` oder verschachtelten Kartenkopien – in `Hochkant`, `Quer` oder `Quadratisch`.
- Begleitdateien (XML, SRT, LRF, THM …) → `<Kamera>/Begleitdateien`, Fotos → `<Kamera>/Fotos`, Musik/ZIP/FCP → `<Kamera>/Extras/…`. Leer gewordene Kartenordner werden entfernt – aber nur, wenn wirklich nichts mehr drin ist. Sony-Proxys (`M4ROOT/SUB`) und `THMBNL` bleiben unangetastet.
- **Lose Dateien** direkt im Dreh-Ordner bleiben liegen und werden gemeldet. 0-Byte- oder kaputte Clips bleiben liegen und werden gemeldet. Aliasse/Symlinks werden übersprungen.
- **Mehrfach einlesen ist sicher:** `Hochkant`/`Quer`/`Quadratisch`, `Begleitdateien`, `Fotos`, `Extras` und *Eigene Ordner* werden nicht neu sortiert. Neue Kameraordner oder nachgelegte Clips werden einsortiert; das Ergebnis zeigt z. B. *„Neu sortiert: E1 (12 Clips) – unverändert: A1, Mini-Drohne“*. Vorhandene Ordner wie `hochkant` werden wiederverwendet.
- Zusätzliche Baukasten-Ebenen (Objektiv, Länge, Drohne Stand/Fahrt, Aufnahmetag) gelten **unter** dem Kameraordner: `A1/Hauptspur/Quer`. Szene und Kamera entfallen in diesem Modus (der Ordner ist die Kamera).
- Ordner wie `Export` werden als Kamera behandelt, CamSort weist darauf hin – unter *Eigene Ordner* eintragen, dann bleiben sie unberührt.

## Ausrichtung
Seitenverhältnis nach Drehung: **0,9–1,1 → `Quadratisch`** (z. B. DJI Osmo Action 6 mit 3840×3840 – daraus lassen sich Hochkant und Quer schneiden), sonst breiter = `Quer` (auch 4:3), höher = `Hochkant` (auch 3:4). Der Name `Quadratisch` ist unter *Ordner & Namen* änderbar.

## Rückfragen vor dem Sortieren
CamSort fragt nur, wenn es für den Ordner wirklich relevant ist – jede Frage mit *Antwort merken* (änderbar in den Einstellungen):
- **Mehrere Aufnahmetage?** → *Tagesordner oben* (`Dreh/2026-10-12/A1/Hochkant`), *unter der Kamera* (`Dreh/A1/2026-10-12/Hochkant`) oder *Nein*. Datum aus den Video-Metadaten, Format einstellbar (Standard `JJJJ-MM-TT`), optional zählen Aufnahmen bis 4 Uhr zum Vortag. Gibt es schon Tagesordner, wird die Struktur ohne Frage weitergeführt. Auch als Baukasten-Ebene *Aufnahmetag*.
- **Datum in den Ordnernamen?** (nach erfolgreichem Sortieren, nur wenn noch kein Datum im Namen steht): `Pitbike` → `2026-10-12 Pitbike` bzw. `2026-10-12–15 Pitbike`, vorne oder hinten. Nur der Ordner wird umbenannt. Gibt es den Namen schon, ist es eine Karte/Volume-Wurzel oder ein direkt gewählter Kameraordner, bleibt der Name.

## Gyrodaten erkennen
Nach dem Sortieren prüft CamSort jeden Clip auf Bewegungsdaten, die Gyroflow lesen kann (Erkennung wie Gyroflows *telemetry-parser*): Sony (XML), DJI mit eingebetteten Gyrodaten (`djmd` + `DJI meta`, z. B. Avata/Osmo Action), GoPro (GPMF), Insta360. Schon stabilisierte Clips sind nicht dabei. Der Fertig-Bildschirm bietet dann an: *„X Clips enthalten Gyrodaten (A1: 10, Avata: 4) – jetzt stabilisieren?“*. Clips, die nicht 16:9/9:16 sind (4:3, 1:1), behalten beim Stabilisieren ihr Format (`-p "{ 'output_width': …, 'output_height': … }"` an die Gyroflow-CLI; das Preset bleibt unverändert). Einstellbar unter *Gyroflow*.

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
