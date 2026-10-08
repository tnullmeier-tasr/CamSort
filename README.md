# CamSort

Mac-App, die Foto- und Videoordner automatisch sortiert: Videos nach Kamera (Sony, DJI, iPhone u. a.) und Ausrichtung (hochkant/quer), Fotos sowie XML-, LRF- und SRT-Begleitdateien in eigene Ordner. Verschiebt nur, verändert keine Dateien, fragt bei Duplikaten nach.

## Download
Unter **Releases** die neueste `CamSort.zip` laden, entpacken, `CamSort` in den Programme-Ordner ziehen.

Beim ersten Start (App ist nicht bei Apple registriert):
```
xattr -dr com.apple.quarantine /Applications/CamSort.app
```

## Ergebnis im Ordner
```
Fotos/
Videos/<Kamera>/Hochkant/
Videos/<Kamera>/Quer/
XML/  LRF/  SRT/
```
