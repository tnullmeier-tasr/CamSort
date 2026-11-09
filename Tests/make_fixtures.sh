#!/bin/bash
# Erzeugt einen realistischen Testordner. Aufruf: make_fixtures.sh <Zielordner>
set -u
D="$1"; rm -rf "$D"; mkdir -p "$D/Unterordner"
FF="ffmpeg -loglevel error -y"
TXT() { echo "drawtext=text='$1':fontcolor=white:fontsize=$2:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=black@0.6"; }

# Sony A1 quer, Modell nur IN der MP4 eingebettet (wie bei echten Sony-Dateien)
$FF -f lavfi -i testsrc=size=1920x1080:rate=25 -t 3 -pix_fmt yuv420p "$D/C0001.MP4"
python3 - "$D/C0001.MP4" <<'PY'
import sys,struct
xml=b'<?xml version="1.0"?><NonRealTimeMeta><Device manufacturer="Sony" modelName="ILCE-1" serialNo="1"/><Lens modelName="FE 24-70mm F2.8 GM II"/></NonRealTimeMeta>'
with open(sys.argv[1],'ab') as f: f.write(struct.pack('>I',8+len(xml))+b'free'+xml)
PY
# Sony ZV-E1 hochkant (echte Hochkant-Auflösung), Modell über Begleit-XML
$FF -f lavfi -i testsrc=size=1080x1920:rate=25 -t 3 -pix_fmt yuv420p "$D/C0002.MP4"
cat > "$D/C0002M01.XML" <<'X'
<?xml version="1.0" encoding="UTF-8"?><NonRealTimeMeta><Device manufacturer="Sony" modelName="ZV-E1" serialNo="2"/><Lens modelName="FE 20mm F1.8 G"/></NonRealTimeMeta>
X
# Hochkant per Rotations-Flag (quer gespeichert + 90°-Flag, wie iPhone/Sony)
$FF -f lavfi -i testsrc=size=1920x1080:rate=25 -t 3 -pix_fmt yuv420p /tmp/rot_src.mp4
$FF -display_rotation 90 -i /tmp/rot_src.mp4 -c copy "$D/C0003.MP4" 2>/dev/null || cp /tmp/rot_src.mp4 "$D/C0003.MP4"
python3 - "$D/C0003.MP4" <<'PY'
import sys,struct
xml=b'<NonRealTimeMeta><Device manufacturer="Sony" modelName="ILCE-1" serialNo="1"/><Lens modelName="FE 70-200mm F2.8 GM OSS II"/></NonRealTimeMeta>'
with open(sys.argv[1],'ab') as f: f.write(struct.pack('>I',8+len(xml))+b'free'+xml)
PY
# DJI Mavic 3 Pro mit SRT (fährt ~36 km/h) und LRF
$FF -f lavfi -i testsrc2=size=1920x1080:rate=25 -t 3 -pix_fmt yuv420p "$D/DJI_20250426155228_0038_D_M3P.MP4"
python3 - "$D/DJI_20250426155228_0038_D_M3P.SRT" <<'PY'
import sys
out=[]
for i in range(11):
    lat=47.0+i*10/111195.0
    out.append(f"{i+1}\n00:00:{i:02d},000 --> 00:00:{i:02d},033\n<font size=\"28\">SrtCnt : {i+1}, DiffTime : 33ms\n[iso : 100] [latitude: {lat:.6f}] [longitude: 8.000000] [rel_alt: 30.0 abs_alt: 450.0] </font>\n")
open(sys.argv[1],'w').write("\n".join(out))
PY
cp "$D/DJI_20250426155228_0038_D_M3P.MP4" "$D/DJI_20250426155228_0038_D_M3P.LRF"
# DJI Mini ohne GPS (Format wie Tims echte Datei)
$FF -f lavfi -i testsrc2=size=1920x1080:rate=25 -t 2 -pix_fmt yuv420p "$D/DJI_0162.MP4"
cp "$(dirname "$0")/DJI_0162.SRT" "$D/DJI_0162.SRT"
# "iPhone"-Clip mit Schriftzug PORSCHE (Test Markenerkennung)
cat > /tmp/txt.swift <<'SW'
import AppKit
let img = NSImage(size: NSSize(width: 1920, height: 1080))
img.lockFocus()
NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.2, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1920, height: 1080).fill()
let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 220), .foregroundColor: NSColor.white]
let s = NSAttributedString(string: "PORSCHE", attributes: a)
s.draw(at: NSPoint(x: (1920 - s.size().width) / 2, y: 420))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/porsche.png"))
SW
swift /tmp/txt.swift && $FF -loop 1 -i /tmp/porsche.png -t 7 -vf "scale=1920:1080" -pix_fmt yuv420p -c:v libx264 "$D/IMG_0001.MOV" && echo "PORSCHE-Clip erzeugt"
# Clip im Unterordner
$FF -f lavfi -i testsrc=size=1280x720:rate=25 -t 2 -pix_fmt yuv420p "$D/Unterordner/MVI_1234.MP4"
# Quadratischer Clip (wie DJI Osmo Action 6, 1:1) für den Modus „Meine Kameraordner“ – außerhalb des Testordners
X="$(dirname "$D")/CamSort-Extra"; mkdir -p "$X"
$FF -f lavfi -i testsrc=size=960x960:rate=25 -t 2 -pix_fmt yuv420p "$X/Q0001.MP4"
# Bildraten-Test (FPS-Ebene): 25, 50 und 23,976 fps – 24 darf nie mit 25 zusammenfallen
$FF -f lavfi -i testsrc=size=1280x720:rate=25 -t 2 -r 25 -pix_fmt yuv420p "$X/F25.MP4"
$FF -f lavfi -i testsrc=size=1280x720:rate=50 -t 2 -r 50 -pix_fmt yuv420p "$X/F50.MP4"
$FF -f lavfi -i testsrc=size=1280x720:rate=24000/1001 -t 2 -r 24000/1001 -pix_fmt yuv420p "$X/F24.MP4"
# Projekte-Test: Aufnahmezeiten 10:00 und 15:00 (lange Pause), Nachzügler 15:30
for t in "P1000 2026-11-08T10:00:00Z" "P1001 2026-11-08T10:20:00Z" "P1500 2026-11-08T15:00:00Z" "P1530 2026-11-08T15:30:00Z"; do
  set -- $t
  $FF -f lavfi -i testsrc=size=1280x720:rate=25 -t 2 -pix_fmt yuv420p -metadata creation_time=$2 "$X/$1.MP4"
done
# Fotos, Musik, ZIP, unbekannter Typ
$FF -f lavfi -i testsrc=size=800x600 -frames:v 1 "$D/IMG_0002.JPG"
$FF -f lavfi -i sine=frequency=440:duration=2 "$D/Musik_Intro.mp3"
(cd "$D" && echo test > a.txt && zip -q Projekt.zip a.txt && rm a.txt)
echo "unbekannt" > "$D/Notiz.abc"
# Echtes Foto eines Autos (Wikimedia) für die Bilderkennung – optional
URL=$(curl -sf -A "CamSortTest/1.0 (test)" "https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search&gsrnamespace=6&gsrsearch=Porsche%20911%20filetype:bitmap&gsrlimit=5&prop=imageinfo&iiprop=url&iiurlwidth=1280" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); p=list(d["query"]["pages"].values()); print(p[0]["imageinfo"][0]["thumburl"])' 2>/dev/null)
echo "Autofoto-URL: $URL"
[ -n "$URL" ] && curl -sfL -A "CamSortTest/1.0 (test)" -o /tmp/car.jpg "$URL"
if [ -s /tmp/car.jpg ]; then
  $FF -loop 1 -i /tmp/car.jpg -t 7 -vf "scale=1280:-2" -pix_fmt yuv420p "$D/Auto_Foto_Clip.mp4" && echo "Auto-Foto geladen"
fi
ls -la "$D"
