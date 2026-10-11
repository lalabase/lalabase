# Test der Fristlöschung

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:stable-slim \
  bash ops/backup/test/run-tests.sh
```

Braucht GNU-Userland (`find -printf`, `date -d`, `sha256sum`) — auf macOS läuft es **nicht**
direkt, deshalb der Container. Rückgabewert 0 heißt: alle Prüfungen bestanden.

Zusätzlich (findet Parse-Fehler, die `bash -n` durchgehen lässt):

```bash
docker run --rm -v "$PWD:/repo" -w /repo koalaman/shellcheck:stable \
  ops/backup/lalabase-attachments-backup.sh
```

## Warum es das gibt

Bis 05.08.2026 war die einzige Erprobung dieser Löschlogik ein Lauf **gegen Produktion**. Das
Skript löscht Kundendaten in zwei Ablagen ohne menschliche Freigabe; jeder Riegel darin ist ein
Zustand, den man durch Lesen nicht prüfen kann. Vier Fälle sind Regressionen für Defekte, die
bereits ausgeliefert waren.

Der Aufbau ersetzt **genau vier** Dinge: `age` (kopieren statt verschlüsseln), `rsync` und `sftp`
(ein Verzeichnis steht für die Storage Box) und `lalabase-alert.sh` (eine Datei statt einer Mail).
Alles andere — Index, alle vier Riegel, der Parser der Box-Verifikation — ist der echte Code,
erreicht über dieselben Umgebungsvariablen, die das Skript dokumentiert.

**Zeit wird über die verkürzte Frist gerafft, nie über zurückdatierte Zeitstempel.** Ein
zurückdatierter Index ist selbst eine Korruption, die das Skript abweisen soll — ihn zu fälschen
würde das Gegenteil dessen prüfen, wonach es aussieht. Genau daran ist die erste Fassung dieses
Testaufbaus gescheitert, und das war der Hinweis auf einen echten Fehler (siehe unten).

## Was die Fälle abdecken

| # | Fall |
|---|---|
| 1–3 | Normallauf, Erfassung einer Verwaisung, Datum wird im Folgelauf **nicht** überschrieben |
| 4–5 | fällige Datei wird in Spiegel **und** Box gelöscht; wieder aufgetauchte Quelle wird verschont |
| 6–7 | Massen-Verwaisungs-Sperre: Abbruch ohne Freigabe, **Freigabe löst sie wieder** |
| 8 | Drosselung statt Halt bei mehr fälligen Einträgen als der Obergrenze |
| 9–11b | vier Arten kaputter Index-Zeilen führen **nie** zu einer Löschung |
| 12–13 | Fehlversuchs-Zähler, Eskalation, Nachweis vor der Spiegel-Löschung |
| 14–16 | `.age.tmp`-Reste, Zustandskopie, fehlende Spiegelkopie zu lebender Quelle |

## Drei Fehler, die dieser Aufbau im eigenen Fix gefunden hat

Alle drei sahen beim Lesen richtig aus:

1. **mtime als Untergrenze der Plausibilitätsprüfung.** Der Gedanke war: eine Datei kann nicht vor
   ihrer eigenen Chiffre verwaist sein. Stimmt — aber ein Spiegel-Restore ohne mtime-Erhalt macht
   damit schlagartig **jeden** laufenden Eintrag unplausibel, und die Prüfung bricht ab. Das wäre
   genau die Dauerklemme gewesen, die dieser PR beseitigen soll. Ersetzt durch eine feste
   Untergrenze: kein Eintrag kann vor Einführung des Index liegen.
2. **Zerrissene Pfadspalte wurde still verworfen.** Die Unlesbarkeits-Prüfung läuft nach dem
   Umschreiben, das unbekannte Pfade fallen lässt — eine im Schreiben zerrissene Pfadspalte
   verschwand damit spurlos, und die betroffene Datei bekam beim nächsten Lauf ein frisches Datum.
   Eine still verlängerte Frist. Jetzt eigener Riegel (Fall 11b).
3. **`# shellcheck disable=SC2086 -- Begründung`** ist keine gültige Direktive und markierte die
   Datei als Parse-Fehler. `bash -n` sah das nicht.
