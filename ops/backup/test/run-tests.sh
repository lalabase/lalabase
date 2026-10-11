#!/bin/bash
# Exercises the deadline deletion of lalabase-attachments-backup.sh in a sandbox.
#
# Why this exists: the deletion logic destroys customer attachments in two places
# without human approval, and until this harness there was no way to run it at all
# except against production. Every case below is an interlock that cannot be checked
# by reading the script, and four of them are regressions for defects that shipped.
#
# GNU userland required (find -printf, date -d, sha256sum), i.e. Linux — see
# ops/backup/test/README.md for the container one-liner.
#
# The sandbox replaces exactly four things: age (copy instead of encrypt), rsync and
# sftp (a directory standing in for the Storage Box) and the alert script (a file
# instead of a mail). Everything else — the index, all four interlocks, the box
# verification parser — is the real code, reached through the same env overrides the
# script documents.
#
# Time is compressed by shortening ORPHAN_RETENTION_DAYS, never by back-dating the
# index: a back-dated index is itself a corruption the script is supposed to reject,
# so faking time that way would test the opposite of what it looks like.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/lalabase-attachments-backup.sh"
[ -x "$SCRIPT" ] || { echo "FEHLT: $SCRIPT"; exit 1; }

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
bad()   { FAIL=$((FAIL + 1)); printf '  FEHL  %s\n' "$*"; }
case_() { printf '\n== %s\n' "$1"; }
is()    { if [ "$1" = "$2" ]; then ok "$3 = $2"; else bad "$3: erwartet '$2', war '$1'"; fi; }
has()   { if grep -q "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3"; fi; }

# --- sandbox ----------------------------------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SRC="${SANDBOX}/src"
export MIRROR="${SANDBOX}/mirror"
export STATE_DIR="${SANDBOX}/state"
export LOG="${SANDBOX}/backup.log"
export LOCK="${SANDBOX}/lock"
export RECIPIENTS="${SANDBOX}/recipients.txt"
export SSH_KEY="${SANDBOX}/fake.key"
export REMOTE="fake@box"
export ALERT="${SANDBOX}/bin/alert.sh"
export BOX="${SANDBOX}/box"
export MAILS="${SANDBOX}/mails"
export AGE_FAIL="" SFTP_RM_BROKEN=""

mkdir -p "${SANDBOX}/bin"
: > "$RECIPIENTS"
: > "$SSH_KEY"

# age: copy, so mirror content stays inspectable.
cat > "${SANDBOX}/bin/age" <<'STUB'
#!/bin/bash
OUT=""; IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    *)  IN="$1"; shift ;;
  esac
done
[ -n "${AGE_FAIL:-}" ] && [ "$(basename "$IN")" = "$AGE_FAIL" ] && exit 1
cp "$IN" "$OUT"
STUB

# rsync: mirror -> box directory, honouring --exclude for the .age.tmp case.
cat > "${SANDBOX}/bin/rsync" <<'STUB'
#!/bin/bash
EXCL=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --exclude=*) EXCL="${1#--exclude=}" ;;
    -e) shift ;;
    --archive|--partial|--prune-empty-dirs) ;;
    *) POS+=("$1") ;;
  esac
  shift
done
FROM="${POS[0]}"; DEST="${BOX}/${POS[1]#*:./}"
mkdir -p "$DEST"
(cd "$FROM" && find . -type f ${EXCL:+! -name "$EXCL"} -print0 | while IFS= read -r -d '' f; do
   mkdir -p "${DEST}/$(dirname "$f")"; cp "$f" "${DEST}/$f"
 done)
STUB

# sftp: reads the command batch from stdin and reproduces the real stream split
# exactly — command echo and listing on stdout, "not found" on stderr — because that
# split is precisely what the verification parser depends on.
cat > "${SANDBOX}/bin/sftp" <<'STUB'
#!/bin/bash
while IFS= read -r line; do
  path="${line##* }"
  printf 'sftp> %s\n' "$line"
  case "$line" in
    -rm\ *) [ -n "${SFTP_RM_BROKEN:-}" ] || rm -f "${BOX}/${path}" ;;
    -ls\ *)
      if [ -e "${BOX}/${path}" ]; then
        printf -- '-rw-r--r--    1 u1 u1 42 Aug  5 03:20 %s\n' "$path"
      else
        printf 'Can'\''t ls: "/home/%s" not found\n' "$path" >&2
      fi ;;
  esac
done
STUB

# alert: one file per mail, so subject and body can be asserted.
cat > "${SANDBOX}/bin/alert.sh" <<'STUB'
#!/bin/bash
N="$(find "$MAILS" -type f | wc -l)"
{ printf 'SUBJECT: %s\n' "$1"; cat; } > "${MAILS}/$(printf '%03d' "$((N + 1))").mail"
exit 0
STUB

chmod +x "${SANDBOX}"/bin/*
export PATH="${SANDBOX}/bin:$PATH"

# --- helpers ----------------------------------------------------------------
run()  { "$SCRIPT" >/dev/null 2>&1; echo $?; }
fresh() { rm -rf "$SRC" "$MIRROR" "$STATE_DIR" "$BOX" "$MAILS"; mkdir -p "$SRC" "$MIRROR" "$STATE_DIR" "$BOX" "$MAILS"; }
mails_reset() { rm -rf "$MAILS"; mkdir -p "$MAILS"; }

blob() { # blob <key> -> prints the Active-Storage-shaped relative path
  local k="$1" d="${SRC}/${1:0:2}/${1:2:2}"
  mkdir -p "$d"; printf 'inhalt-%s\n' "$k" > "${d}/${k}"
  printf '%s/%s/%s' "${1:0:2}" "${1:2:2}" "$k"
}
index_rows()   { wc -l < "${STATE_DIR}/orphans.tsv" 2>/dev/null | tr -d ' '; }
record_rows()  { wc -l < "${STATE_DIR}/deletions.log" 2>/dev/null | tr -d ' '; }
mirror_blobs() { find "$MIRROR" -type f -name '*.age' -not -path "${MIRROR}/_state/*" | wc -l | tr -d ' '; }
box_blobs()    { find "$BOX" -type f -name '*.age' -not -path "${BOX}/_state/*" | wc -l | tr -d ' '; }
fails_for()    { grep -F "$1" "${STATE_DIR}/orphans.tsv" | cut -f3 | head -1; }
last_mail()    { find "$MAILS" -type f | sort | tail -1; }
set_ts()       { # set_ts <value> — overwrite every timestamp, for the corruption cases
  awk -F'\t' -v OFS='\t' -v t="$1" '{ print $1, t, $3 }' "${STATE_DIR}/orphans.tsv" > "${STATE_DIR}/o.tmp"
  mv -f "${STATE_DIR}/o.tmp" "${STATE_DIR}/orphans.tsv"
}

# Deadline 1 day: entries recorded today never become due in the test.
NEVER_DUE=1
# Deadline -1: everything already recorded is due at once. Shortens the DEADLINE but
# does not touch the index. In the test, runs happen in the same second, so a deadline
# of 0 would never take effect.
DUE_NOW=-1

# ============================================================================
fresh; export ORPHAN_RETENTION_DAYS="$NEVER_DUE"

case_ "1 — Normallauf: alles verschlüsselt und hochgeladen, nichts verwaist"
A="$(blob aaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
B="$(blob bbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
blob cccccccccccccccccccccccccccc >/dev/null
is "$(run)" "0" "Exit"
is "$(mirror_blobs)" "3" "Spiegel"
is "$(box_blobs)" "3" "Box"
is "$(index_rows)" "0" "Index"

case_ "2 — Verwaisung wird erfasst, aber nichts gelöscht"
rm -f "${SRC}/${A}"
is "$(run)" "0" "Exit"
is "$(index_rows)" "1" "Index"
is "$(mirror_blobs)" "3" "Spiegel unverändert"
is "$(box_blobs)" "3" "Box unverändert"

case_ "3 — Folgelauf überschreibt das Verwaisungsdatum nicht"
TS_BEFORE="$(cut -f2 "${STATE_DIR}/orphans.tsv")"
is "$(run)" "0" "Exit"
is "$(cut -f2 "${STATE_DIR}/orphans.tsv")" "$TS_BEFORE" "Zeitstempel"

case_ "4 — fällig: gelöscht in Spiegel UND Box, Nachweis auf Platte"
mails_reset; export ORPHAN_RETENTION_DAYS="$DUE_NOW"
is "$(run)" "0" "Exit"
is "$(mirror_blobs)" "2" "Spiegel"
is "$(box_blobs)" "2" "Box"
is "$(index_rows)" "0" "Index geleert"
is "$(record_rows)" "1" "deletions.log"
has "fristgemäß gelöscht" "$(last_mail)" "Nachweis-Mail versendet"

case_ "5 — Quelle taucht wieder auf: Eintrag fällt, nichts gelöscht"
export ORPHAN_RETENTION_DAYS="$NEVER_DUE"
rm -f "${SRC}/${B}"; run >/dev/null                       # record
printf 'wieder-da\n' > "${SRC}/${B}"
export ORPHAN_RETENTION_DAYS="$DUE_NOW"
is "$(run)" "0" "Exit"
is "$(index_rows)" "0" "Eintrag abgeräumt"
is "$(mirror_blobs)" "2" "Spiegel unverändert"
is "$(box_blobs)" "2" "Box unverändert"

# ----------------------------------------------------------------------------
fresh; mails_reset; export ORPHAN_RETENTION_DAYS="$NEVER_DUE"
for i in $(seq 1 60); do blob "$(printf 'm%027d' "$i")" >/dev/null; done
run >/dev/null

case_ "6 — Massen-Verwaisung ohne Freigabe: Abbruch, Index bleibt unberührt"
find "$SRC" -type f -delete
is "$(run)" "1" "Exit"
is "$(index_rows)" "0" "Index NICHT geschrieben"
is "$(mirror_blobs)" "60" "Spiegel unverändert"
has "Freigabe nötig" "$(last_mail)" "Freigabe-Mail versendet"
BATCH="$(grep -oE 'echo [0-9a-f]{16}' "$(last_mail)" | head -1 | cut -d' ' -f2)"
[ -n "$BATCH" ] && ok "Batch-Kennung genannt ($BATCH)" || bad "keine Batch-Kennung"

case_ "7 — REGRESSION: die Sperre ist freigebbar und verklemmt nicht dauerhaft"
printf '%s\n' "$BATCH" > "${STATE_DIR}/mass-orphan-ack"
is "$(run)" "0" "Exit nach Freigabe"
is "$(index_rows)" "60" "alle 60 erfasst"
[ -f "${STATE_DIR}/mass-orphan-ack" ] && bad "Freigabe nicht verbraucht" || ok "Freigabe verbraucht"
is "$(run)" "0" "Folgelauf läuft normal weiter"

# ----------------------------------------------------------------------------
fresh; mails_reset; export ORPHAN_RETENTION_DAYS="$NEVER_DUE"
for i in $(seq 1 40); do blob "$(printf 'r%027d' "$i")" >/dev/null; done
run >/dev/null
find "$SRC" -type f -delete           # 40 < mass limit 50, passes interlock 1
run >/dev/null                        # recorded, not yet due

case_ "8 — REGRESSION: mehr fällig als die Obergrenze wird gedrosselt, nicht angehalten"
export ORPHAN_RETENTION_DAYS="$DUE_NOW"
is "$(index_rows)" "40" "40 Einträge stehen an"
is "$(run)" "0" "Exit (vor dem Fix: 1, und das jede Nacht auf Dauer)"
is "$(index_rows)" "15" "25 gelöscht, 15 bleiben"
is "$(record_rows)" "25" "Nachweis fortgeschrieben"
has "Gedrosselt: 15" "$(last_mail)" "Drosselung in der Mail benannt"
is "$(run)" "0" "zweiter Lauf"
is "$(index_rows)" "0" "Rest abgeflossen"
is "$(record_rows)" "40" "Nachweis vollständig"
is "$(box_blobs)" "0" "Box: alle 40 weg"
is "$(mirror_blobs)" "0" "Spiegel: alle 40 weg"

# ----------------------------------------------------------------------------
fresh; export ORPHAN_RETENTION_DAYS="$NEVER_DUE"
D="$(blob dddddddddddddddddddddddddddd)"
run >/dev/null; rm -f "${SRC}/${D}"; run >/dev/null

case_ "9 — REGRESSION: abgeschnittener, aber numerischer Zeitstempel löscht NICHT"
export ORPHAN_RETENTION_DAYS="$DUE_NOW"
set_ts 17859                          # cut off from 1785920924 in the middle of the write
is "$(run)" "1" "Exit"
is "$(mirror_blobs)" "1" "nichts gelöscht"
is "$(box_blobs)" "1" "Box unberührt"
has "unplausibel" "$LOG" "als unplausibel abgewiesen"

case_ "10 — Zeitstempel in der Zukunft löscht NICHT"
set_ts "$(date -u -d '+2 days' +%s)"
is "$(run)" "1" "Exit"
is "$(mirror_blobs)" "1" "nichts gelöscht"

case_ "11 — unlesbarer Zeitstempel einer echten Zeile löscht NICHT"
set_ts abc
is "$(run)" "1" "Exit"
is "$(mirror_blobs)" "1" "nichts gelöscht"
has "unlesbar" "$LOG" "als unlesbar abgewiesen"

case_ "11b — REGRESSION: zerrissene Pfadspalte wird gemeldet, nicht still verworfen"
printf 'zz/zz/zerrissen\t%s\t0\n' "$(date -u +%s)" > "${STATE_DIR}/orphans.tsv"
is "$(run)" "1" "Exit"
has "weder auf eine verwaiste noch auf eine lebende Datei" "$LOG" "gemeldet statt verworfen"

# ----------------------------------------------------------------------------
fresh; mails_reset; export ORPHAN_RETENTION_DAYS="$NEVER_DUE"
E="$(blob eeeeeeeeeeeeeeeeeeeeeeeeeeee)"
run >/dev/null; rm -f "${SRC}/${E}"; run >/dev/null
export ORPHAN_RETENTION_DAYS="$DUE_NOW"

case_ "12 — Box-Löschung scheitert: Zähler steigt, ab dem dritten Mal harter Fehler"
export SFTP_RM_BROKEN=1
is "$(run)" "0" "1. Fehlversuch: Lauf bleibt grün"
is "$(fails_for "$E")" "1" "Zähler"
is "$(mirror_blobs)" "1" "Spiegel NICHT gelöscht, solange die Box sie hat"
is "$(run)" "0" "2. Fehlversuch"
is "$(fails_for "$E")" "2" "Zähler"
is "$(run)" "1" "3. Fehlversuch: harter Fehler"
has "scheitert wiederholt" "$(last_mail)" "Eskalations-Mail"
[ -f "${STATE_DIR}/last-success" ] && ok "Erfolgs-Marker trotzdem gesetzt (Sicherung ist aktuell)" \
  || bad "Erfolgs-Marker fehlt"
export SFTP_RM_BROKEN=""

case_ "13 — Nachweis steht auf Platte, bevor die Spiegelkopie fällt"
is "$(run)" "0" "Exit nach reparierter Box"
is "$(record_rows)" "1" "Nachweis geschrieben"
is "$(mirror_blobs)" "0" "Spiegel gelöscht"
is "$(box_blobs)" "0" "Box gelöscht"

# ----------------------------------------------------------------------------
fresh; export ORPHAN_RETENTION_DAYS="$NEVER_DUE"
blob ffffffffffffffffffffffffffff >/dev/null
mkdir -p "${MIRROR}/zz"; touch -d '-2 hours' "${MIRROR}/zz/abbruch.age.tmp"

case_ "14 — liegengebliebene .age.tmp werden abgeräumt und nie hochgeladen"
is "$(run)" "0" "Exit"
[ -e "${MIRROR}/zz/abbruch.age.tmp" ] && bad ".age.tmp liegt noch" || ok ".age.tmp abgeräumt"
[ -e "${BOX}/zz/abbruch.age.tmp" ] && bad ".age.tmp auf der Box" || ok "nicht auf der Box"

case_ "15 — Zustandskopie liegt auf der Box und wird nie selbst zum Löschkandidaten"
[ -f "${BOX}/_state/orphans.tsv.age" ] && ok "Index gesichert" || bad "Index nicht gesichert"
[ -f "${BOX}/_state/deletions.log.age" ] && ok "Nachweis gesichert" || bad "Nachweis nicht gesichert"
is "$(index_rows)" "0" "_state erzeugt keine Verwaisungs-Einträge"
export ORPHAN_RETENTION_DAYS="$DUE_NOW"
is "$(run)" "0" "Löschlauf"
[ -f "${BOX}/_state/orphans.tsv.age" ] && ok "Zustandskopie überlebt einen Löschlauf" \
  || bad "Zustandskopie wurde selbst gelöscht"

case_ "16 — fehlende Spiegelkopie zu einer lebenden Quelldatei bricht ab"
G="$(blob 11111111111111111111111111111)"
export AGE_FAIL="$(basename "$G")"
is "$(run)" "1" "Exit"
export AGE_FAIL=""

case_ "17 — ohne SRC (backup.conf nennt es nicht) bricht das Skript ab, bevor es etwas anfasst"
SAVED_SRC="$SRC"; unset SRC
before="$(find "$MIRROR" "$BOX" -type f | sort | sha256sum)"
is "$(run)" "1" "Exit"
is "$(find "$MIRROR" "$BOX" -type f | sort | sha256sum)" "$before" "Spiegel und Box unverändert"
msg="$("$SCRIPT" 2>&1 >/dev/null)"   # captured first: pipefail would report the script's exit
case "$msg" in *"backup.conf fehlt oder nennt SRC nicht"*) ok "Meldung nennt backup.conf" ;;
  *) bad "Meldung nennt backup.conf nicht" ;; esac
export SRC="$SAVED_SRC"

# ============================================================================
printf '\n────────────────────────────\n%s bestanden, %s fehlgeschlagen\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
