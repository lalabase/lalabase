# Backup und Log-Retention (Produktion)

Eingerichtet am 04.08.2026. Vorher gab es **keine** Backup-Automatik und **keine** Rotation der
Anwendungs-Logs; die einzige Sicherung war ein von Hand gezogener Dump vom 02.08.

Die Dateien hier sind Kopien dessen, was auf den Servern läuft. Sie werden **nicht** automatisch
ausgerollt — bei Änderungen beides nachziehen (siehe „Ausrollen").

## Koordinaten setzen, bevor du hier etwas ausführst

Die Befehle unten sprechen vier Werte über Variablen an, weil sie von Installation
zu Installation verschieden sind und in diesem Repo nichts zu suchen haben:

```bash
export DB_HOST=<ssh-ziel des datenbank-servers>
export APP_HOST=<ssh-ziel des app-servers>
export BOX=<kennung der storage box>       # ergibt <BOX>.your-storagebox.de
export DEPLOY_ROOT=<deploy-verzeichnis der app>  # z. B. /home/deploy/lalabase_production
```

Dieselben Werte brauchen die Skripte selbst zur Laufzeit. Sie lesen sie aus
`/etc/lalabase-backup/backup.conf` auf **beiden** Hosts; die Vorlage dafür ist
[`backup.conf.example`](backup.conf.example). Fehlt die Datei, brechen die Skripte
laut ab und nennen sie beim Namen. Das ist Absicht: Eine Voreinstellung im Repo
hieße, dass jede veröffentlichte Kopie das Konto ihres Autors mitschleppt.

## Was gesichert wird

| Daten | Betrieb | Sicherung |
|---|---|---|
| PostgreSQL (`DB_NAME` aus `backup.conf`) | `$DB_HOST` | täglich 03:00 UTC → Storage Box `db/` |
| Dateianhänge (Active Storage) | `$APP_HOST`, `shared/storage` | täglich 03:20 UTC → Storage Box `attachments/` |
| Logs | App-Server | gar nicht — die werden gelöscht, nicht gesichert |

**Die Anhänge sind nicht im `pg_dump`.** Der Dump enthält nur die Blob-Datensätze; ein Restore
allein aus der Datenbank ließe jeden Kundenanhang ins Leere zeigen. Deshalb zwei Quellen.

## Storage Box

`$BOX.your-storagebox.de`, bei uns BX21 (5 TB), Standort **Falkenstein**. Der Standort ist nicht
beliebig: die Datenschutzerklärung (`app/views/static/legal/_privacy_body.html.erb`, englisch
`_privacy_body.en.html.erb`) und AVV § 3 Abs. 3 sagen Verarbeitung in Deutschland zu, eine Box in
Helsinki oder Ashburn würde beide Dokumente unwahr machen.

* **SSH/SFTP/rsync auf Port 23**, nicht 22.
* SMB, WebDAV und „Äußere Erreichbarkeit" sind **aus**. Aus Hetzner-Netzen ist die Box trotzdem
  erreichbar; vom Arbeitsplatz aus nicht — der Restore läuft deshalb über den DB-Host.
* Zwei Sub-Accounts, je auf ihr Verzeichnis eingesperrt und mit eigenem Schlüssel:

| Sub-Account | Verzeichnis | Quelle | Schlüssel auf dem Server |
|---|---|---|---|
| `$BOX-sub1` | `db` | `$DB_HOST` | `/root/.ssh/id_ed25519_storagebox` |
| `$BOX-sub2` | `attachments` | `$APP_HOST` | `/root/.ssh/id_ed25519_storagebox` |

Ein übernommener App-Server erreicht die Datenbank-Dumps damit nicht und umgekehrt (verifiziert:
aus `sub1` heraus existieren `../attachments` und `/home/attachments` nicht).

**Sub-Accounts kennen nur „nur lesen" oder „lesen und schreiben"** — kein „schreiben, aber nicht
löschen". Das Aufräumen alter Stände braucht Löschrechte, also ist der Schutz gegen mutwilliges
Löschen **allein** die Snapshot-Funktion der Box (täglich 05:00, 14 Stände). Die wird außerhalb
der Sub-Account-Zugänge verwaltet und ist von den Servern aus nicht angreifbar.

## Verschlüsselung

`age` mit **nur dem öffentlichen Schlüssel auf den Servern**
(`/etc/lalabase-backup/recipients.txt`). Ein kompromittierter Server kann Sicherungen erzeugen,
aber keine bestehenden lesen.

Der private Schlüssel liegt ausschließlich auf dem Arbeitsplatz-Mac unter
`~/.config/lalabase/backup-age-key.txt` und gehört zusätzlich in den Passwortmanager.

> **Geht der private Schlüssel verloren, ist jede Sicherung Altpapier.** Das ist der Preis dafür,
> dass ein übernommener Server die Altbestände nicht lesen kann. `restic` und `borg` wurden
> deshalb verworfen: Beide brauchen das Repo-Passwort zum Schreiben, es läge also auf dem Server.

## Aufbewahrung

| | Lokal | Storage Box |
|---|---|---|
| Datenbank | 7 Stände | 35 Stände |
| Anhänge | Spiegel, bis 35 Tage nach Verwaisung | dito, danach + 14 Tage Snapshots |

Beide Stränge halten **35 Tage**. Darüber liegen die täglichen Snapshots der Box (14 Stände), die
von den Servern aus niemand löschen kann. Das ehrliche Löschfenster ist deshalb **~50 Tage**, und
genau diese Zahl gehört in **AVV § 12 Abs. 4** — nicht die 35. Beim Ändern einer der drei Zahlen
das Vertragsdokument mitziehen (Herleitung: `doc/avv_vergleich_awork_2026_08_05.md` §1).

## Fristlöschung der Anhänge

Bis zum 05.08.2026 war die Anhang-Sicherung **append-only**: Ein in der App gelöschter Anhang blieb
unbegrenzt liegen. Damit wäre jede Löschfrist im Vertrag unwahr gewesen. Seither löscht
`lalabase-attachments-backup.sh` verwaiste Dateien automatisch — in **beiden** Ablagen.

Was nie aus `shared/storage` verschwindet, verwaist allerdings auch nie — und läuft damit in
**keine** Frist, egal wie gut dieses Skript arbeitet. Genau das war bei Dateien ohne Verknüpfung in
der Datenbank der Fall. Dafür sorgt der App-Job `UnattachedBlobPurgeJob` (täglich 05:15, sieben Tage
Wartefrist): Er ist das **Vorschaltglied** dieser Kette, nicht Teil von ihr. Beschrieben auf
<https://lalabase.com/docs/de/self-hosting/operation/background-jobs> (die Seite liegt seit D5
in `gboyke/lalabase-documentation`, nicht mehr in diesem Repo).

**Verwaist** heißt: Die Datei liegt im Spiegel, fehlt aber in `shared/storage`. Wann eine Datei
verwaist ist, lässt sich **nachträglich nicht mehr feststellen** — die Spiegeldatei trägt nur ihr
Verschlüsselungsdatum, und die Quelldatei ist ja gerade das, was fehlt. Diese Information entsteht
ausschließlich im Moment eines Laufs. Deshalb der Index `/var/lib/lalabase-backup/orphans.tsv`
(Modus 600, drei Spalten: relativer Pfad ohne `.age`, Zeitstempel der ersten Sichtung, Zähler
fehlgeschlagener Löschungen — Box **und** Spiegel, beide eskalieren gleich). Ein Folgelauf
**überschreibt das Datum nicht**; taucht die Quelle wieder auf, verschwindet der Eintrag
rückstandslos und es wird nichts gelöscht. Das Verzeichnis `/var/lib/lalabase-backup` selbst ist
`700`.

**Vier Riegel** stehen zwischen einem Fehllauf und dem Totalverlust der Anhang-Sicherung:

| Riegel | Fängt | Verhalten |
|---|---|---|
| Massen-Verwaisungs-Sperre | ausgehängtes Quellverzeichnis, halb fertiger Deploy | Abbruch, **bevor** der Index geschrieben wird — sonst gälten schlagartig alle 907 Dateien als verwaist und wären 35 Tage später weg. **Einmalig freigebbar**, siehe unten |
| Plausibilität der Zeitstempel | beschädigten oder zurückdatierten Index, gesprungene Uhr | Abbruch, **nichts** gelöscht |
| Lösch-Obergrenze je Lauf (25) | zu viel auf einmal | **drosselt**, hält nicht an: die ältesten 25 gehen, der Rest folgt in den Folgeläufen. Notbremse erst bei 500 |
| Gegenprobe der Quelle | Wiederauftauchen im letzten Moment | keine Löschung, Eintrag abgeräumt |

Die Schwelle der Massen-Sperre ist `max(5 % des Spiegels, 50 Dateien)` — bei 907 Dateien also 50.

### Warum keiner dieser Riegel dauerhaft klemmen darf

Eine Sperre, die auf einen Zustand reagiert, **der sich nicht von selbst ändert**, verklemmt für
immer: Der Abbruch schreibt den Index nicht, also trifft der nächste Lauf denselben Zustand und
bricht wieder ab. Nacht für Nacht, mit Alarm-Mail und ohne dass je etwas gelöscht wird. Das ist
**nicht** die sichere Seite — es heißt, die zugesagte Löschfrist wird nie wieder eingehalten, für
keine Datei.

Zwei Fassungen dieses Fehlers waren in der ersten Auslieferung drin und sind hier behoben:

* **Die Obergrenze lag unter der Massen-Schwelle** (25 gegen 50). Verwaisungen fallen in
  Tagesbündeln an und werden 35 Tage später als dasselbe Bündel fällig — ein einziger Tag mit 26
  bis 50 gelöschten Anhängen hätte die Löschung dauerhaft gestoppt. Deshalb ist die Obergrenze
  jetzt eine **Drossel**: die ältesten `MAX_PRUNE_PER_RUN` gehen, der Rest fließt in den nächsten
  Nächten ab. Ob dem Index zu *trauen* ist, beantwortet jetzt die Plausibilitätsprüfung direkt,
  statt es aus der Anzahl fälliger Einträge zu erraten. Die Notbremse (`MAX_PRUNE_HALT=500`) bleibt
  für den Fall, an den niemand gedacht hat.
* **Die Massen-Sperre war unauflösbar.** Sie ist jetzt **einmalig und bündelgebunden** freigebbar.
  Die Mail nennt die Kennung des konkreten Satzes:

  ```
  echo <kennung> | sudo tee /var/lib/lalabase-backup/mass-orphan-ack
  ```

  Die Freigabe gilt nur für exakt diese Dateiliste und wird beim nächsten Lauf verbraucht. War das
  Quellverzeichnis dagegen nur nicht lesbar, ist **nichts zu tun** — dann wird nie freigegeben, und
  der Satz verschwindet von selbst, sobald die Quelle wieder da ist.

Aus demselben Grund ist die Plausibilitätsprüfung **nicht** gegen die mtime der Spiegeldatei
gefloort, obwohl das die schärfere Schranke wäre: Ein Spiegel-Restore ohne mtime-Erhalt würde
schlagartig jeden laufenden Eintrag unplausibel machen und exakt wieder dauerhaft klemmen. Die
Untergrenze ist stattdessen fest der Einführungstag des Index — jeder mitten im Schreiben
abgerissene Unix-Zeitstempel landet Jahrzehnte davor und wird so gefangen.

**Die Reihenfolge ist nicht beliebig: erst Box, dann Spiegel.** Der Verwaisungs-Satz wird aus dem
Spiegel abgeleitet. Andersherum verschwände der Index-Eintrag beim nächsten Lauf mangels
Spiegeldatei — der Retry hätte keinen Anker mehr, und die Kopie auf der Box bliebe für immer liegen.
Der Index-Eintrag fällt erst, wenn die Box-Löschung **bestätigt** ist; der Exit-Code des
`sftp`-Batches allein zählt nicht. Scheitert eine Box-Löschung bei erreichbarer Box, bleibt der
Eintrag stehen und der Folgetag versucht es erneut; ab dem dritten Fehlversuch derselben Datei wird
daraus ein harter Fehler, weil sonst die zugesagte Frist still verrutscht.

### Beide Aussagen müssen positiv sein

Die Verifikation fordert je Kandidat **genau ein positives Urteil**:

| Urteil | Beleg | Strom |
|---|---|---|
| vorhanden | Listing-Zeile nach der Echo-Zeile | stdout |
| gelöscht | `Can't ls: "…" not found` der Box | **stderr** |

Alles andere — kein Urteil, oder beide — bricht den Lauf ab. Das ist keine Förmlichkeit: Würde
„keine Listing-Zeile" als gelöscht gelten, fiele die Prüfung **offen** aus. Eine Datei mit
abweichendem Modus (`-r--------` statt `-rw-r--r--`) reicht dann schon: Spiegel gelöscht,
Index-Eintrag weg, Box-Kopie für immer verwaist — unauffindbar, weil der Verwaisungs-Satz aus dem
Spiegel stammt — und kein Alarm. Auf der Box nachgestellt und behoben.

Deshalb wird stderr **nicht** nach `/dev/null` geworfen: Dort steht der einzige positive Beleg für
eine Abwesenheit. Anwesenheit liest sich allein aus stdout, wo Echo- und Listing-Zeile denselben
Strom teilen und ihre Reihenfolge garantiert ist; der Abwesenheitsbeleg wird über den Pfad **im
Text** zugeordnet. So kann keine Verschränkung der beiden Ströme die Zuordnung verwirren.

**Nachweis.** Je gelöschter Datei eine Log-Zeile `GELÖSCHT <pfad> verwaist_seit=<datum>
orte=spiegel,box`, dazu ein Eintrag in `/var/lib/lalabase-backup/deletions.log` und eine Mail über
`lalabase-alert.sh` bei **jedem** Lauf mit Löschungen. Läufe ohne Löschungen senden nichts.

Drei Ablagen, weil jede für sich zu wenig ist: `/var/log/lalabase-backup.log` rotiert monatlich mit
12 Ständen und trägt den Nachweis nur ~ein Jahr. Die Mail bleibt dauerhaft, **kann aber ausfallen** —
auf diesem Host hat AppArmor `msmtp` schon einmal blockiert. `deletions.log` liegt unter `/var/lib`,
wo nichts rotiert, und ist damit die Zweitschrift, die einen kaputten Mailweg überlebt. Ein
fehlgeschlagener Versand lässt den Lauf mit Fehler enden.

**Die Nachweiszeile entsteht in dem Moment, in dem die Box-Kopie nachweislich weg ist** — also
*vor* der Spiegel-Löschung, nicht am Ende des Laufs. Vorher lag zwischen der Zerstörung und ihrem
Beleg das ganze restliche Skript: Ein Reboot in diesem Fenster hätte Kundendaten in beiden Ablagen
vernichtet und nichts hinterlassen als eine Log-Zeile, die nach zwölf Monaten wegrotiert. Scheitert
danach die Spiegel-Löschung, steht die Zeile trotzdem — die materielle, unumkehrbare Löschung hat
stattgefunden, und ein Wiederholungslauf schreibt dann eine zweite Zeile. Doppelte Zeilen sind der
seltene Ausnahmefall und behaupten nichts Falsches.

Riegel-Verletzungen sind **harte Fehler** mit Alarm-Mail. Der Erfolgs-Marker wird jedoch
geschrieben, denn zu diesem Zeitpunkt waren Verschlüsselung, Vollständigkeitsprüfung und Upload
erfolgreich: **Die Sicherung ist aktuell, hängen geblieben ist nur die Fristlöschung.**
`OnFailure=` meldet das treffend; würde der Marker fehlen, meldete der Peer-Check des Partners
stattdessen jeden Morgen „Sicherung nicht aktuell" über ein intaktes Backup. Ein Melder, der das
Falsche sagt, wird ignoriert — dieselbe Überlegung wie bei der 26-Stunden-Schwelle. Dieselbe Regel
gilt für alle Riegel und für die klemmende Löschung; sie war anfangs nur auf letztere angewandt.

**Eine Ausnahme, bewusst:** Ein gescheiterter Nachweis-Versand hält den Marker **doch** zurück. Ist
der lokale Mailweg kaputt, kommt auch `OnFailure=` nicht durch — dann ist der Peer-Check des
Partners der einzige Kanal, der überhaupt noch eine Meldung hinausbringt.

Leere Verzeichnisse, die auf der Box zurückbleiben, sind hinnehmbar. Der `rsync`-Upload läuft
weiterhin **ohne** `--delete` — auf der Box löscht ausschließlich der `sftp`-Batch des Skripts.

### Der Index ist die Frist, also wird er mitgesichert

`orphans.tsv` und `deletions.log` lagen bis 05.08.2026 **nur** auf der Platte des App-Servers. Ein
neu aufgesetzter Server hätte damit jede laufende Frist stillschweigend mit dem Tagesdatum neu
begonnen und den Nachweis gleich mit verloren — die Zusage wäre unbemerkt gebrochen gewesen. Beide
Dateien werden deshalb am Ende jedes Laufs verschlüsselt unter `_state/` in den Spiegel geschrieben
und auf die Box geladen. Dieses Präfix ist vom Verwaisungs-Satz **ausgenommen**: Es hat keine
Entsprechung in `shared/storage` und würde sonst als verwaist gelten und genau den Index löschen,
aus dem es besteht. Scheitert die Zustandskopie, ist das eine Warnung und kein Abbruch — ein
gelungenes Backup darf daran nicht scheitern.

### Testen

Die Löschlogik lässt sich in einem Sandkasten fahren, ohne Produktion und ohne echte Box:

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:stable-slim bash ops/backup/test/run-tests.sh
```

16 Fälle, darunter vier Regressionen für Defekte, die bereits ausgeliefert waren. Details und die
Begründung des Aufbaus: `ops/backup/test/README.md`. **Vor jeder Änderung am Prune laufen lassen** —
`bash -n` sieht keinen dieser Fehler.

> ⚠️ **Der Prune sieht nur, was aus `shared/storage` verschwindet.** Am 05.08.2026 lagen dort 31
> unverknüpfte Active-Storage-Blobs (bis 11 Monate alt): Rails räumt unverknüpfte Blobs nicht von
> allein auf, und `AttachmentPurgerService` wird nirgends aufgerufen. Diese Dateien verwaisen nie,
> laufen in keine Frist und bleiben unbegrenzt in der Sicherung. Die Löschzusage im AVV ist erst
> dann vollständig wahr, wenn dieser Aufräum-Job Rails-seitig gebaut ist. Er gehört **nicht**
> hierher, ist aber Teil derselben Zusage.

## Log-Retention

Die Datenschutzerklärung (`app/views/static/legal/_privacy_body*.html.erb`) sagt zu, dass Logfiles
spätestens nach 7 Tagen gelöscht werden. Bis zum
04.08.2026 stimmte das nicht: `production.log` war 389 MB groß und reichte 11 Monate zurück.

* `logrotate/lalabase-app-server.conf` — täglich, 7 Stände, **`copytruncate`**.
* `journald/90-lalabase-retention.conf` — `MaxRetentionSec=7d`, `SystemMaxUse=500M`. Rails loggt
  in die Datei **und** nach stdout; ohne diese Grenze bliebe im Journal eine zweite Kopie liegen,
  die keine Datei-Rotation je anfasst (war 3,9 GB).
* nginx wurde von 14 auf 7 Tage gezogen (`/etc/logrotate.d/nginx`, nicht hier gespiegelt).

**`copytruncate` ist Pflicht, keine Geschmacksfrage.** `config/environments/production.rb` hält
ein offenes Handle auf `production.log`, und Solid Queue hängt per systemd `StandardOutput=append:`
daran. Ein normales Umbenennen ließe beide in den alten Inode weiterschreiben — die neue Datei
bliebe leer. Dass Solid Queue mit `O_APPEND` schreibt (und nach dem Abschneiden bei null beginnt
statt eine Datei mit Loch zu erzeugen), ist über `/proc/<pid>/fdinfo` geprüft.

Zusätzlich verlangt `logrotate` für `/var/log` eine `su root syslog`-Direktive, weil das
Verzeichnis `root:syslog` gehört — ohne sie überspringt es die Datei mit einer Fehlermeldung,
die man leicht übersieht.

## Ausrollen

**Zuerst die Koordinaten**, sonst starten die Skripte nicht:

```bash
# Auf BEIDEN Hosts, je mit dem Unterkonto DIESES Hosts
scp ops/backup/backup.conf.example "$DB_HOST":/etc/lalabase-backup/backup.conf
scp ops/backup/backup.conf.example "$APP_HOST":/etc/lalabase-backup/backup.conf
# ... dann dort REMOTE eintragen (sub1 auf dem DB-Host, sub2 auf dem App-Server)
```

```bash
# DB-Host
scp ops/backup/lalabase-db-backup.sh "$DB_HOST":/usr/local/sbin/
scp ops/backup/systemd/lalabase-db-backup.* "$DB_HOST":/etc/systemd/system/
ssh "$DB_HOST" 'chmod 750 /usr/local/sbin/lalabase-db-backup.sh && systemctl daemon-reload \
  && systemctl enable --now lalabase-db-backup.timer'

# App-Server
scp ops/backup/lalabase-attachments-backup.sh "$APP_HOST":/usr/local/sbin/
scp ops/backup/systemd/lalabase-attachments-backup.* "$APP_HOST":/etc/systemd/system/
sed "s#__DEPLOY_ROOT__#${DEPLOY_ROOT}#" ops/backup/logrotate/lalabase-app-server.conf \
  | ssh "$APP_HOST" 'cat > /etc/logrotate.d/lalabase'
ssh "$APP_HOST" 'chmod 750 /usr/local/sbin/lalabase-attachments-backup.sh && systemctl daemon-reload \
  && systemctl enable --now lalabase-attachments-backup.timer'
```

**Danach beide Stände vergleichen.** Seit das Anhang-Skript löscht, heißt eine veraltete
Server-Kopie nicht mehr „etwas ältere Sicherung", sondern: Die Löschzusage im AVV beschreibt Code,
der dort gar nicht läuft — und nichts meldet das.

### Lesefreigabe für das Löschverzeichnis (einmalig, App-Server)

Die Anwendung führt das Löschverzeichnis nach **AVV § 12 Abs. 7** und trägt dort nach, wann eine
Datei aus den Sicherungen verschwunden ist. Die Quelle dafür ist `deletions.log` dieses Skripts.

Ohne den folgenden Schritt passiert der Nachtrag **nie**: Das Skript läuft als `root` und legt
Verzeichnis (700) wie Datei (600) root-only an, der Solid-Queue-Worker läuft aber als `deploy` und
kommt nicht einmal in das Verzeichnis. Der Job meldet das einmal täglich als Warnung
(`[deletion_register] … is not readable`) — sichtbar nur, wenn jemand das Anwendungsprotokoll liest.

```bash
ssh "$APP_HOST" '
  groupadd -f lalabase-deletion-log
  usermod -aG lalabase-deletion-log deploy
  mkdir -p /etc/systemd/system/lalabase-attachments-backup.service.d
  printf "[Service]\nEnvironment=DELETION_RECORD_GROUP=lalabase-deletion-log\n" \
    > /etc/systemd/system/lalabase-attachments-backup.service.d/deletion-log-group.conf
  systemctl daemon-reload
  systemctl restart solid_queue
'
```

Die Rechte selbst setzt der nächste Skript-Lauf (`chgrp` + 750/640). Nur der **Nachweis** wird
freigegeben, nicht der Verwaisungs-Index: Der bleibt 600, weil er die laufende Frist trägt und außer
dem Skript niemand etwas darin zu suchen hat. Ist die Variable nicht gesetzt oder die Gruppe nicht
vorhanden, bleibt alles wie bisher root-only — das Skript weitet Rechte nie ungefragt aus.

Prüfen, ob es wirkt:

```bash
ssh "$APP_HOST" 'sudo -u deploy test -r /var/lib/lalabase-backup/deletions.log && echo lesbar || echo "NICHT lesbar"'
```

```bash
sha256sum ops/backup/lalabase-attachments-backup.sh
ssh "$APP_HOST" 'sudo sha256sum /usr/local/sbin/lalabase-attachments-backup.sh'
# Weichen die beiden ab, ist das tatsächliche Löschverhalten unbekannt.
```

Das Zustandsverzeichnis setzt das Skript bei **jedem** Lauf auf `700` — bis 05.08.2026 fehlte das
und `/var/lib/lalabase-backup` stand auf `755`. Wer nicht bis zum nächsten Lauf warten will:

```bash
ssh "$APP_HOST" 'sudo chmod 700 /var/lib/lalabase-backup'
```

Alarmierung (auf **beide** Hosts):

```bash
scp ops/backup/lalabase-alert.sh ops/backup/lalabase-alert-unit.sh \
    ops/backup/lalabase-peer-check.sh <host>:/usr/local/sbin/
scp ops/backup/systemd/lalabase-alert@.service \
    ops/backup/systemd/lalabase-peer-check.* <host>:/etc/systemd/system/
ssh <host> 'chmod 750 /usr/local/sbin/lalabase-*.sh && systemctl daemon-reload \
  && systemctl enable --now lalabase-peer-check.timer'
```

Voraussetzungen auf einem frischen Server:

* `apt install age msmtp`
* age-Schlüsselpaar erzeugen, Public Key beim passenden Sub-Account hinterlegen,
  `/etc/lalabase-backup/recipients.txt` mit dem age-Recipient anlegen
* Host-Key der Box per `ssh-keyscan -p 23` in `known_hosts` legen
* `alert.conf` und `msmtprc` aus den `.example`-Vorlagen anlegen (`msmtprc` auf Modus 600)
* Peer-Schlüsselpaar erzeugen und beim Partner mit erzwungenem Befehl hinterlegen
  (siehe „Alarmierung"), Host-Keys beidseitig in `known_hosts`

## Kontrolle

```bash
ssh "$DB_HOST"   'tail -20 /var/log/lalabase-backup.log; systemctl list-timers --no-pager | grep lalabase'
ssh "$APP_HOST" 'tail -20 /var/log/lalabase-backup.log; systemctl list-timers --no-pager | grep lalabase'

# Fristlöschung: was wurde wann gelöscht (rotationsfeste Zweitschrift),
# und was steht gerade zur Löschung an?
ssh "$APP_HOST" 'cat /var/lib/lalabase-backup/deletions.log; cat /var/lib/lalabase-backup/orphans.tsv'
```

## Alarmierung

Es gibt **zwei** Fehlerarten, und die meisten Lösungen decken nur die harmlosere ab:

| Fehlerart | Was passiert | Erkannt durch |
|---|---|---|
| Lauf bricht ab | Exit ≠ 0, z. B. Box nicht erreichbar | `OnFailure=` → Alarm-Mail mit Journal-Auszug |
| **Lauf findet nicht statt** | Timer deaktiviert, Host aus, systemd nach Upgrade kaputt | `lalabase-peer-check.timer` |

Die zweite ist die gefährliche: `OnFailure=` bleibt dabei still, weil nichts fehlgeschlagen ist.
Sie ist monatelang geräuschlos und fällt genau dann auf, wenn die Sicherung gebraucht wird.

**Gegenseitige Überwachung.** Beide Backup-Skripte schreiben bei Erfolg einen Unix-Zeitstempel
nach `/var/lib/lalabase-backup/last-success`. Täglich um 09:00 UTC prüft jeder Host den eigenen
**und** den Zeitstempel des Partners; ist einer älter als 26 Stunden oder der Partner nicht
erreichbar, geht eine Mail raus.

Die 26 Stunden sind Absicht: Bei 24 schlägt jede kleine Laufzeitverschiebung falschen Alarm, und
ein Melder, der grundlos piept, wird nach zwei Wochen ignoriert.

Fällt ein Host ganz aus, meldet ihn der andere. Fallen beide gleichzeitig aus, meldet es niemand
— dann ist aber das Produkt offline und es fällt ohnehin auf.

**Der Zugriff auf den Partner ist auf genau einen Befehl festgenagelt.** In dessen
`authorized_keys` steht:

```
command="/bin/cat /var/lib/lalabase-backup/last-success",restrict ssh-ed25519 AAAA…
```

Verifiziert: Ein `ssh … "cat /etc/shadow"` mit diesem Schlüssel liefert trotzdem nur den
Zeitstempel. Das ist die einzige Stelle, an der die sonst konsequente Trennung der beiden
Maschinen aufgeweicht wird — deshalb der erzwungene Befehl statt eines normalen Schlüssels.

**Eigener SMTP-Benutzer.** `/etc/lalabase-backup/msmtprc` (Modus 600) nutzt bewusst **nicht** die
Zugangsdaten der Anwendung: Ein kompromittierter Server soll Alarm schlagen können, aber niemals
im Namen des Produkts an Kunden schreiben. Vorlagen: `msmtprc.example`, `alert.conf.example`.

Fehlt die Konfiguration, versendet nichts still ins Leere — `lalabase-alert.sh` schreibt dann
eine ausdrückliche Fehlerzeile ins Log.

> **Verbleibende Lücke:** Bricht der Mailweg selbst (SMTP-Passwort abgelaufen, Hetzner-Postfach
> voll), steht das nur im Log. Eine periodische Test-Mail wäre die Antwort darauf, ist aber
> bisher nicht eingerichtet.

### Falle: AppArmor blockiert `msmtp` auf Ubuntu 22.04

Auf dem App-Server scheiterte der Versand mit `msmtp: /etc/lalabase-backup/msmtprc: Permission
denied` — obwohl die Datei `root:root 600` ist und `cat` sie als root problemlos liest. Ursache
ist das AppArmor-Profil `usr.bin.msmtp`, das nur `/etc/msmtprc` und `~/*msmtprc` erlaubt.

Drei Dinge, die die Diagnose verschleppt haben:

1. Das Ubuntu-Paket legt bei der Installation einen disable-Symlink unter
   `/etc/apparmor.d/disable/` an — das Profil ist also **für künftige Boots deaktiviert**, war
   aber aus der laufenden Installation noch im Kernel geladen. `aa-status` zeigte es, während
   der Symlink das Gegenteil suggerierte.
2. Wegen dieses Symlinks lädt `apparmor_parser -r` das Profil **nicht** neu. Ergänzte Regeln
   wirken also nicht, ohne dass ein Fehler erschiene.
3. Der DB-Server (Ubuntu 24.04, msmtp 1.8.24) hat gar kein geladenes Profil — dort funktionierte
   dieselbe Konfiguration sofort. Der Unterschied lag nicht an der Konfiguration.

**Lösung:** `apparmor_parser -R /etc/apparmor.d/usr.bin.msmtp` — das entlädt das Profil und
stellt genau den Zustand her, den der Host nach dem nächsten Neustart ohnehin hätte.

Eigene Regeln in `/etc/apparmor.d/local/usr.bin.msmtp` sind **nicht** der Weg: `rix`-Einträge
kollidieren mit den `x`-Modifikatoren des Profils („profile has merged rule with conflicting x
modifiers"), wodurch sich das Profil anschließend nicht einmal mehr entladen lässt.

## Restore

Der private Schlüssel darf nicht auf den Server, und der Mac erreicht die Box nicht direkt. Also:
Datei über den DB-Host holen, Klartext durch den Tunnel schicken.

```bash
ssh "$DB_HOST" "rsync -e 'ssh -p 23 -i /root/.ssh/id_ed25519_storagebox' \
  $BOX-sub1@$BOX.your-storagebox.de:./<datei>.age /var/tmp/restore.age"
ssh "$DB_HOST" 'sudo -u postgres createdb lalabase_restore_test'
ssh "$DB_HOST" 'cat /var/tmp/restore.age' \
  | age -d -i ~/.config/lalabase/backup-age-key.txt \
  | ssh "$DB_HOST" 'sudo -u postgres pg_restore -d lalabase_restore_test'
```

Danach Zeilenzahlen gegen die Produktion vergleichen, dann `dropdb` und `/var/tmp/restore.age`
löschen. Durchgeführtes Protokoll: `doc/restore_test_2026_08_04.md`.

### Anhänge

Gleiches Prinzip, aber **je Datei einzeln** — der Pfad auf der Box ergibt sich aus dem
Active-Storage-Key: `<key[0..1]>/<key[2..3]>/<key>.age`.

```bash
ssh "$APP_HOST" "rsync -e 'ssh -p 23 -i /root/.ssh/id_ed25519_storagebox' \
  $BOX-sub2@$BOX.your-storagebox.de:./ab/cd/abcd….age /var/tmp/restore/"
ssh "$APP_HOST" 'cat /var/tmp/restore/abcd….age' \
  | age -d -i ~/.config/lalabase/backup-age-key.txt \
  | ssh "$APP_HOST" 'cat > /var/tmp/restore/abcd…'
```

Wiederhergestellte Dateien in ein Wegwerf-Verzeichnis legen, **nie** direkt zurück nach
`shared/storage` — das würde beim nächsten Lauf mitverschlüsselt und den Befund verwischen.
Durchgeführtes Protokoll: `doc/restore_test_anhaenge_2026_08_04.md`.

**Zwei Dinge, die beim Prüfen Zeit kosten:**

* Die Box hat eine **eingeschränkte Shell** — `find`, `wc` und dergleichen gibt es dort nicht.
  Bestand aufnehmen geht über `rsync --list-only -r`, Löschen über `sftp`.
* `systemctl list-timers` meldet für die Backup-Timer `LAST: n/a`, auch wenn sie gelaufen sind.
  Verlässlich sind `zcat -f /var/log/lalabase-backup.log*` und
  `/var/lib/lalabase-backup/last-success`.

**Beim Vergleich beachten:** `solid_queue_*` weicht immer ab, weil die Warteschlangen
weiterlaufen. Dass es sich um Bewegung und nicht um Datenverlust handelt, zeigt erst ein
Blick auf `max(created_at)` — im Restore muss der jüngste Job **vor** dem Dump-Zeitpunkt liegen.

> **Ein Dump allein reicht nicht:** Die verschlüsselten Spalten (`ai_credentials.access_token`,
> `project_repositories.access_token`/`webhook_secret`, …) sind nur mit den drei
> `ACTIVE_RECORD_ENCRYPTION_*`-Schlüsseln aus der `shared/.env` des App-Servers lesbar. Die drei
> Werte gehören deshalb wie der age-Key in den Passwortmanager — gehen sie verloren, bleiben
> diese Spalten im Restore Ciphertext.

## Zwei Fallen beim Ändern der Skripte

* **`ssh` nimmt den Port als `-p`, `sftp` als `-P`.** Ein gemeinsamer Options-String macht aus
  `-p` still sftps „preserve permissions" und schluckt die 23. Ergebnis: leere Ausgabe, kein
  Fehler. Deshalb gibt es `SSH_OPTS` und `SFTP_OPTS` getrennt.
* **`sftp` spiegelt das eingegebene Kommando zurück**, und diese Echo-Zeile enthält den Dateinamen
  ebenfalls. Ein Grep auf den Namen fängt sie mit und meldet fälschlich „noch da". Beide Skripte
  nutzen die Echo-Zeile deshalb als *Anker* für den Pfad und werten erst eine **darauf folgende
  Listing-Zeile** als Anwesenheit. Belegte Ausgabe:
  `sftp> -ls -l zn/8c/x.age` → vorhanden `-rw-r--r-- … zn/8c/x.age`, gelöscht
  `Can't ls: "/home/zn/8c/x.age" not found`.

  ⚠️ **Im Prune darf die Listing-Zeile NICHT auf `^-rw` gematcht werden**, sondern auf die
  Modus-Zeichen `^[-dlbcps]`. Eine Datei mit abweichendem Modus (`-r--------`) fiele sonst durch und
  würde als gelöscht gelten — Spiegel gelöscht, Index-Eintrag weg, Box-Kopie für immer unauffindbar,
  kein Alarm. Das war ein echter Defekt, auf der Box nachgestellt und in `ca43aab1` behoben; die
  Begründung steht oben unter „Beide Aussagen müssen positiv sein". `lalabase-db-backup.sh` matcht
  weiterhin `/^-rw/` — dort wird nur eine Größe gelesen, eine Fehlklassifikation löscht nichts.
* **Ein vorangestelltes `-` lässt `sftp` einen Fehler überspringen** statt den Rest des Batches
  abzubrechen (`-rm`, `-ls`). Ohne das bricht eine Löschliste beim ersten fehlenden Pfad ab.
