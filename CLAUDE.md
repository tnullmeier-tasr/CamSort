# camsort

## GitHub-Actions-Budget (wichtig)
- macOS-Minuten kosten das 10-Fache. Mehrere Änderungen sammeln und **einmal** pushen; Zwischenstände mit `[skip ci]` im Commit.
- Doku-Änderungen (`*.md`, `docs/`) lösen keinen Build aus; laufende Builds werden bei neuem Push abgebrochen.
- Aufwändige Tests nur bei Bedarf (manuell über „Run workflow“, bei Versions-Tags bzw. CamSort: `[test]` im Commit).
