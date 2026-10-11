#!/bin/bash
# Encrypted daily backup of the Active Storage attachments to the Storage Box.
#
# Why this exists separately from the database backup: the pg_dump holds only the
# blob RECORDS, never the files themselves. Restoring the database alone would
# leave every customer attachment dangling.
#
# Design notes:
#   * Each blob is encrypted individually into a mirror directory, so an unchanged
#     file is never re-encrypted and rsync stays incremental. Re-encrypting
#     everything nightly would produce fresh ciphertext each time and turn every
#     run into a full 2.3 GB upload.
#   * NOT append-only. A blob deleted in the app is removed from the mirror AND the
#     box once it has been missing for ORPHAN_RETENTION_DAYS. The contract promises
#     a deletion window; a backup that never forgets would make that promise untrue.
#   * WHEN a file went missing cannot be reconstructed after the fact: the mirror
#     copy carries only its encryption date, and the source file is precisely what
#     is gone. That information exists solely in the moment of a run, which is why
#     an orphan index is written first and every deletion is derived from it.
#   * Four interlocks stand between a faulty run and the loss of the attachment
#     backup: the mass-orphan brake (a run that cannot see the source would
#     otherwise orphan everything at once), the timestamp plausibility check (an
#     index entry that cannot be true must not be acted on), the per-run rate limit,
#     and a re-check of the source for every candidate before the deletion batch.
#   * A brake that HALTS on a state which does not change by itself latches forever:
#     the index is not rewritten on abort, so the next run meets the same state and
#     dies again. Every brake here therefore either drains by itself (the rate limit)
#     or is releasable by a one-time, batch-bound acknowledgement (the mass brake).
#     A permanently latched brake would not be the safe side — it would mean the
#     promised deletion deadline is never met again for any file.
#   * Ordering matters: the box copy is deleted BEFORE the mirror copy. The orphan
#     set is derived from the mirror, so a mirror-first deletion would drop the
#     index entry on the next run and leave an unreachable copy on the box forever.
#   * The index and the deletion record ARE the promise — they are encrypted into
#     the mirror under STATE_PREFIX so a rebuilt server does not silently restart
#     every running deadline. That prefix is excluded from the orphan set: it has no
#     counterpart in SRC and would otherwise delete the very index it is made of.
set -uo pipefail
# Every file this script creates carries blob keys of deleted customer attachments.
# Born 0600 rather than chmod'd afterwards, which leaves a window and is easy to
# forget at the next write site.
umask 077

# Paths are overridable so the interlocks can be exercised outside production — see
# ops/backup/test/run-tests.sh. Nothing sets these in the systemd unit, so the
# defaults below are what actually runs on the server. SRC (the Active Storage
# directory) has no default: it names the deploy root, so it comes from
# backup.conf like the other coordinates.
: "${MIRROR:=/var/backups/attachments}"
: "${RECIPIENTS:=/etc/lalabase-backup/recipients.txt}"
# Site-specific coordinates (Storage Box sub-account, SSH key). Deliberately NOT
# defaulted here: a hardcoded account travels with every published copy of this
# repo. Template: ops/backup/backup.conf.example. The file assigns with
# `: "${VAR:=…}"`, so an environment override set by the test harness still wins.
# shellcheck source=/dev/null
[ -r /etc/lalabase-backup/backup.conf ] && . /etc/lalabase-backup/backup.conf
: "${SSH_KEY:?nicht gesetzt - /etc/lalabase-backup/backup.conf fehlt (Vorlage: ops/backup/backup.conf.example)}"
: "${REMOTE:?nicht gesetzt - /etc/lalabase-backup/backup.conf fehlt (Vorlage: ops/backup/backup.conf.example)}"
: "${SRC:?nicht gesetzt - /etc/lalabase-backup/backup.conf fehlt oder nennt SRC nicht (Vorlage: ops/backup/backup.conf.example)}"
# NOTE: ssh takes the port as -p, sftp as -P. Sharing one option string between
# them silently turns -p into sftp's "preserve permissions" flag and swallows 23.
SSH_OPTS="-p 23 -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30"
SFTP_OPTS="-P 23 -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30"
: "${LOG:=/var/log/lalabase-backup.log}"
: "${LOCK:=/var/lock/lalabase-attachments-backup.lock}"
: "${STATE_DIR:=/var/lib/lalabase-backup}"
: "${ALERT:=/usr/local/sbin/lalabase-alert.sh}"

# --- Deadline deletion: tunables -------------------------------------------
# Index of orphaned files: relative mirror path (without .age), unix timestamp of
# the first run that saw it missing, count of failed deletions.
ORPHAN_INDEX="${STATE_DIR}/orphans.tsv"
# Second copy of the deletion proof, outside /var/log so no rotation ever truncates
# it. The mail is what reaches a human; this is what survives.
DELETION_RECORD="${STATE_DIR}/deletions.log"
# Written by an operator to release ONE specific mass-orphan batch. Contains that
# batch's fingerprint, so an old file can never wave a later, different batch through.
MASS_ORPHAN_ACK="${STATE_DIR}/mass-orphan-ack"
# Matches the box retention of the database backup. Together with the box's 14
# daily snapshots this yields the ~50 day deletion window stated in the AVV.
: "${ORPHAN_RETENTION_DAYS:=35}"
# Rate limit, NOT a halt: the oldest entries go first and the rest follow on the
# next nights. Halting here used to be permanent — orphans arrive in daily batches
# and come due as the same batch 35 days later, so any single day between this
# number and the mass-brake limit stopped the deletion forever. Whether the index
# can be TRUSTED is answered directly by the plausibility check, not inferred from
# how many entries happen to be due.
: "${MAX_PRUNE_PER_RUN:=25}"
# Last backstop for a failure mode nobody anticipated. Deleting this many
# attachments in a single night is never routine at this stock size; everything
# below it drains through the rate limit instead of stopping.
: "${MAX_PRUNE_HALT:=500}"
# An unmounted source directory or a half-finished deploy would orphan the whole
# stock in a single run. Whichever of the two is larger wins.
: "${MASS_ORPHAN_MIN_FILES:=50}"
: "${MASS_ORPHAN_PERCENT:=5}"
# A deletion that keeps failing would silently stretch the promised deadline, so it
# escalates from warning to hard error. Counts box AND mirror failures alike.
: "${DELETE_MAX_FAILS:=3}"
# Mirror sub-directory holding the encrypted state copies. Never part of the orphan
# set — see the header note.
STATE_PREFIX="_state"

log() { printf '%s [attachments] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
die() { log "FEHLER: $*"; exit 1; }

# Both index rewrites share this: the mode contract and the atomic swap live in one
# place, so a third rewrite cannot quietly drop either.
commit_index() {
  chmod 600 "${ORPHAN_INDEX}.tmp" && mv -f "${ORPHAN_INDEX}.tmp" "$ORPHAN_INDEX" \
    || die "Verwaisungs-Index nicht schreibbar ($1): $ORPHAN_INDEX"
}

exec 9>"$LOCK" || die "Lock-Datei nicht anlegbar"
flock -n 9 || die "Ein Lauf ist noch aktiv — abgebrochen"

[ -d "$SRC" ] || die "Quellverzeichnis fehlt: $SRC"
mkdir -p "$MIRROR" && chmod 700 "$MIRROR" || die "Spiegelverzeichnis nicht nutzbar"
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" || die "Zustandsverzeichnis nicht nutzbar: $STATE_DIR"

WORK="$(mktemp -d)" || die "Arbeitsverzeichnis nicht anlegbar"
trap 'rm -rf "$WORK"' EXIT

NOW="$(date -u +%s)"
RUN_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "Start"

# --- Encrypt what is new or changed ----------------------------------------
# A run killed inside age() leaves a .age.tmp behind. Nothing downstream matches it
# (*.age does not), so it would never enter the orphan set, never come due and stay
# in the backup forever — a retention hole invisible to the whole machinery.
STALE_TMP="$(find "$MIRROR" -type f -name '*.age.tmp' -mmin +60 -print -delete | wc -l)"
[ "$STALE_TMP" -eq 0 ] || log "${STALE_TMP} liegengebliebene .age.tmp aus abgebrochenen Läufen entfernt"

NEW=0
FAILED=0
while IFS= read -r -d '' f; do
  REL="${f#"$SRC"/}"
  OUT="${MIRROR}/${REL}.age"
  if [ -f "$OUT" ] && [ "$OUT" -nt "$f" ]; then
    continue
  fi
  mkdir -p "$(dirname "$OUT")"
  # The rename is part of the success condition. Counting a blob as encrypted when
  # the mv failed (ENOSPC, read-only remount) would leave it unbacked while FAILED
  # stays at zero — the count check below is not tight enough to catch that.
  if age -R "$RECIPIENTS" -o "${OUT}.tmp" "$f" 2>/dev/null && [ -s "${OUT}.tmp" ] \
     && mv -f "${OUT}.tmp" "$OUT"; then
    NEW=$((NEW + 1))
  else
    rm -f "${OUT}.tmp"
    FAILED=$((FAILED + 1))
    log "WARNUNG: Verschlüsselung fehlgeschlagen für ${REL}"
  fi
done < <(find "$SRC" -type f -print0)

[ "$FAILED" -eq 0 ] || die "${FAILED} Datei(en) konnten nicht verschlüsselt werden"

# --- Inventory --------------------------------------------------------------
# Taken ONCE, before the upload, and reused for the counts, the completeness check
# and the orphan set. Walking the trees twice let the two snapshots drift and made
# the mass-orphan limit reason about a different moment than the orphan set it
# guards.
#
# Relative paths, sorted for comm. Blob keys are alphanumeric, so a newline in a
# path cannot occur here. A find that fails partway (EACCES after a permission
# change, transient I/O error) still writes what it managed to read, and every
# source file it did not reach would look orphaned — so its exit status decides.
find "$SRC" -type f -printf '%P\n' | LC_ALL=C sort > "${WORK}/live" \
  || die "Quellverzeichnis nicht vollständig lesbar — nichts gelöscht"
find "$MIRROR" -type f -name '*.age' -not -path "${MIRROR}/${STATE_PREFIX}/*" -printf '%P\n' \
  | sed 's/\.age$//' | LC_ALL=C sort > "${WORK}/mirrored" \
  || die "Spiegelverzeichnis nicht vollständig lesbar — nichts gelöscht"

SRC_COUNT="$(wc -l < "${WORK}/live")"
MIRROR_COUNT="$(wc -l < "${WORK}/mirrored")"
log "Quelle ${SRC_COUNT} Dateien, Spiegel ${MIRROR_COUNT} (${NEW} neu verschlüsselt)"

# The real completeness check: source files with no mirror copy. The old count
# comparison had exactly the orphan backlog as slack — with N pending orphans, N
# live files could be missing from the backup entirely and it still passed.
comm -13 "${WORK}/mirrored" "${WORK}/live" > "${WORK}/unbacked"
[ ! -s "${WORK}/unbacked" ] \
  || die "$(wc -l < "${WORK}/unbacked") Quelldatei(en) fehlen im Spiegel, erste: $(head -1 "${WORK}/unbacked")"

comm -23 "${WORK}/mirrored" "${WORK}/live" > "${WORK}/orphans"

# --- Upload -----------------------------------------------------------------
# .age.tmp is excluded so a crash mid-encryption can never publish a partial
# ciphertext to the box, where nothing would ever clean it up.
rsync -e "ssh ${SSH_OPTS}" --archive --partial --prune-empty-dirs --exclude='*.age.tmp' \
  "${MIRROR}/" "${REMOTE}:./" || die "Upload zur Storage Box fehlgeschlagen"

# --- Deadline deletion ------------------------------------------------------
# Runs only after encryption, completeness check and upload have succeeded. A run
# that fails earlier never reaches this point — which is the intended order: nothing
# is ever deleted on the strength of a run that could not prove the backup is intact.
[ -f "$ORPHAN_INDEX" ] || : > "$ORPHAN_INDEX"
[ -f "$DELETION_RECORD" ] || : > "$DELETION_RECORD"
chmod 600 "$ORPHAN_INDEX" "$DELETION_RECORD"

# Optional read access to the deletion proof for ONE group. The application's
# deletion register (AVV § 12 Abs. 7) carries the backup confirmation over from
# this file, and the worker runs as `deploy` — without this it cannot even enter
# the state directory, so the register would never learn that a backup expired.
#
# Deliberately narrow: only the PROOF opens up, and only if the group really
# exists. The orphan index stays 600 (it is the live deadline, nothing outside
# this script has business reading it), and an unset or unknown group leaves
# every permission exactly as before — the script must not fail over a missing
# group, and a system that never configured one must not silently widen access.
: "${DELETION_RECORD_GROUP:=}"
if [ -n "$DELETION_RECORD_GROUP" ] && getent group "$DELETION_RECORD_GROUP" >/dev/null 2>&1; then
  chgrp "$DELETION_RECORD_GROUP" "$DELETION_RECORD" 2>/dev/null \
    && chmod 640 "$DELETION_RECORD" \
    && chgrp "$DELETION_RECORD_GROUP" "$STATE_DIR" 2>/dev/null \
    && chmod 750 "$STATE_DIR" \
    || log "WARNUNG: Lesefreigabe für Gruppe ${DELETION_RECORD_GROUP} nicht setzbar — der Nachtrag im Löschverzeichnis bleibt aus"
elif [ -n "$DELETION_RECORD_GROUP" ]; then
  log "WARNUNG: Gruppe ${DELETION_RECORD_GROUP} existiert nicht — Löschnachweis bleibt root-only"
fi
cut -f1 "$ORPHAN_INDEX" | LC_ALL=C sort > "${WORK}/known"
comm -23 "${WORK}/orphans" "${WORK}/known" > "${WORK}/new_orphans"

# Interlock 1: mass orphaning. Checked BEFORE the index is written, so a run that
# cannot see the source leaves no trace and deletes nothing.
#
# Released by an acknowledgement bound to THIS batch's fingerprint. Without that
# release the brake would be permanent: the abort writes no index, so the next run
# recomputes the identical batch and dies again — and because the index is never
# written again, the 35 day clock would never start for ANY file from then on. That
# is not the safe side of the trade. A legitimate bulk deletion (one customer
# offboarding, the pending Rails cleanup of unattached blobs) must be confirmable
# once; an unmounted source simply never gets confirmed, and the batch disappears on
# its own as soon as the mount is back.
NEW_ORPHAN_COUNT="$(wc -l < "${WORK}/new_orphans")"
MASS_LIMIT=$((MIRROR_COUNT * MASS_ORPHAN_PERCENT / 100))
[ "$MASS_LIMIT" -ge "$MASS_ORPHAN_MIN_FILES" ] || MASS_LIMIT="$MASS_ORPHAN_MIN_FILES"
if [ "$NEW_ORPHAN_COUNT" -gt "$MASS_LIMIT" ]; then
  BATCH_ID="$(sha256sum < "${WORK}/new_orphans" | cut -c1-16)"
  if [ -r "$MASS_ORPHAN_ACK" ] && [ "$(tr -d '[:space:]' < "$MASS_ORPHAN_ACK")" = "$BATCH_ID" ]; then
    rm -f "$MASS_ORPHAN_ACK"
    log "Massen-Verwaisung ${BATCH_ID} freigegeben — ${NEW_ORPHAN_COUNT} Datei(en) werden erfasst"
  else
    {
      printf 'Die Fristlöschung der Anhang-Sicherung wurde angehalten.\n\n'
      printf 'Neu verwaist: %s Datei(en)\n' "$NEW_ORPHAN_COUNT"
      printf 'Grenze:       %s\n\n' "$MASS_LIMIT"
      printf 'Es wurde NICHTS erfasst und NICHTS gelöscht. So viele Dateien auf einmal deuten\n'
      printf 'auf ein ausgehängtes Quellverzeichnis oder einen halb fertigen Deploy hin.\n\n'
      printf 'War es eine echte Massenlöschung in der Anwendung, nach Prüfung freigeben mit:\n\n'
      printf '  echo %s | sudo tee %s\n\n' "$BATCH_ID" "$MASS_ORPHAN_ACK"
      printf 'Die Freigabe gilt nur für genau diese Dateiliste und wird beim nächsten Lauf\n'
      printf 'verbraucht. War das Quellverzeichnis nur nicht lesbar, ist nichts zu tun — der\n'
      printf 'Satz verschwindet von selbst, sobald die Quelle wieder da ist.\n\n'
      printf 'Host: %s, geprüft am %s\n\n' "$(hostname -f)" "$RUN_STAMP"
      printf -- '--- die ersten zehn ---\n'
      head -10 "${WORK}/new_orphans"
    } | "$ALERT" "Anhang-Sicherung: Massen-Verwaisung, Freigabe nötig"
    die "Massen-Verwaisung: ${NEW_ORPHAN_COUNT} Dateien fehlen neu in der Quelle (Grenze ${MASS_LIMIT}) — Index unverändert, nichts gelöscht, Freigabe ${BATCH_ID} nötig"
  fi
fi

# A row whose path is neither still orphaned nor back in the source describes a file
# that exists in neither place — which can only mean the path column itself was
# mangled. The rewrite below drops such a row silently, and the mirror file it really
# meant would then be re-recorded with today's date: a deadline extended without a
# trace. The shape and plausibility checks further down cannot see this, because they
# run on the already-rewritten index.
LC_ALL=C sort -u "${WORK}/orphans" "${WORK}/live" > "${WORK}/accounted"
comm -23 "${WORK}/known" "${WORK}/accounted" > "${WORK}/vanished"
[ ! -s "${WORK}/vanished" ] \
  || die "$(wc -l < "${WORK}/vanished") Index-Eintrag/Einträge zeigen weder auf eine verwaiste noch auf eine lebende Datei, erster: $(head -1 "${WORK}/vanished") — Index unverändert, nichts gelöscht"

# Write the index: keep the ORIGINAL date of entries that are still orphaned, add
# the newly missing ones with today's date, drop everything whose source is back.
# Overwriting existing dates would push the deadline out forever.
awk -F'\t' -v OFS='\t' '
  FILENAME==ARGV[1] { orphan[$0]=1; next }
  ($1 in orphan) { print $1, $2, ($3=="" ? 0 : $3) }
' "${WORK}/orphans" "$ORPHAN_INDEX" > "${ORPHAN_INDEX}.tmp" \
  || die "Verwaisungs-Index nicht neu schreibbar"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  printf '%s\t%s\t0\n' "$rel" "$NOW" >> "${ORPHAN_INDEX}.tmp"
done < "${WORK}/new_orphans"
commit_index "Erfassung"
INDEX_COUNT="$(wc -l < "$ORPHAN_INDEX")"
[ "$NEW_ORPHAN_COUNT" -eq 0 ] || log "${NEW_ORPHAN_COUNT} Datei(en) neu verwaist"

# Interlock 2: the index has to be readable AND plausible before anything is acted
# on. Shape first — a row that is not three numeric-tailed columns cannot be
# interpreted, and an unreadable timestamp would sit in the index forever and quietly
# fall out of the promised deadline.
MALFORMED="$(awk -F'\t' 'NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/' "$ORPHAN_INDEX" | wc -l)"
[ "$MALFORMED" -eq 0 ] \
  || die "${MALFORMED} Index-Eintrag/Einträge unlesbar, erster: $(awk -F'\t' 'NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {print $1; exit}' "$ORPHAN_INDEX") — nichts gelöscht"

# Then plausibility. Being NUMERIC is not the same as being TRUE: a write torn by
# ENOSPC or a kill leaves "17859" instead of "1785920924" — still numeric, but 1970,
# therefore instantly due. That is the one corruption that fails OPEN, because
# smaller always means "more overdue", and neither the rate limit (a single entry)
# nor the source re-check (the source really is gone) would stop it. Both bounds are
# checked positively:
#   * not in the future — a jumped clock or a nonsense value
#   * not before the index itself existed — no entry can predate the feature, so a
#     truncated timestamp (every cut of a 10 digit epoch lands decades short) is
#     caught by construction
#
# Deliberately NOT floored against the mirror file's own mtime, although that would
# be the tighter bound: a mirror restored without preserving mtimes would then make
# every running entry implausible at once, and this check aborts — which is exactly
# the permanently latching brake this file is otherwise built to avoid.
ORPHAN_TS_FLOOR=1785888000   # 2026-08-05, the day the index was introduced
: > "${WORK}/implausible"
while IFS=$'\t' read -r rel ts fails; do
  [ -n "$rel" ] || continue
  if [ "$ts" -gt "$NOW" ]; then
    printf '%s\tZeitstempel in der Zukunft (%s)\n' "$rel" "$ts" >> "${WORK}/implausible"
  elif [ "$ts" -lt "$ORPHAN_TS_FLOOR" ]; then
    printf '%s\tZeitstempel vor Einführung des Index (%s)\n' "$rel" "$ts" >> "${WORK}/implausible"
  fi
done < "$ORPHAN_INDEX"
[ ! -s "${WORK}/implausible" ] \
  || die "$(wc -l < "${WORK}/implausible") Index-Eintrag/Einträge unplausibel, erster: $(head -1 "${WORK}/implausible") — nichts gelöscht"

CUTOFF=$((NOW - ORPHAN_RETENTION_DAYS * 86400))
awk -F'\t' -v c="$CUTOFF" '$2 < c' "$ORPHAN_INDEX" | LC_ALL=C sort -t"$(printf '\t')" -k2,2n \
  > "${WORK}/due"
DUE_COUNT="$(wc -l < "${WORK}/due")"
log "Verwaisungs-Index ${INDEX_COUNT} Eintrag/Einträge, davon ${DUE_COUNT} fällig (Frist ${ORPHAN_RETENTION_DAYS} Tage)"

# Interlock 3, the backstop: a number this far above normal operation means something
# nobody anticipated. Everything below drains through the rate limit rather than
# stopping, because a stop here does not clear itself.
if [ "$DUE_COUNT" -gt "$MAX_PRUNE_HALT" ]; then
  {
    printf 'Die Fristlöschung der Anhang-Sicherung wurde angehalten.\n\n'
    printf 'Fällig zur Löschung: %s Datei(en)\n' "$DUE_COUNT"
    printf 'Notbremse:           %s\n\n' "$MAX_PRUNE_HALT"
    printf 'Es wurde NICHTS gelöscht. So viele fällige Einträge auf einmal sind kein\n'
    printf 'normaler Betrieb — der Index ist vermutlich beschädigt.\n\n'
    printf 'Index: %s (%s Eintrag/Einträge)\n' "$ORPHAN_INDEX" "$INDEX_COUNT"
    printf 'Host:  %s, geprüft am %s\n\n' "$(hostname -f)" "$RUN_STAMP"
    printf -- '--- die zehn ältesten fälligen Einträge ---\n'
    head -10 "${WORK}/due" | cut -f1
  } | "$ALERT" "Anhang-Sicherung: Notbremse ausgelöst"
  die "${DUE_COUNT} fällige Einträge überschreiten die Notbremse ${MAX_PRUNE_HALT} — nichts gelöscht"
fi

# Rate limit: oldest first, the remainder follows on the next nights. "due" is
# already sorted by timestamp ascending.
DEFERRED_COUNT=0
if [ "$DUE_COUNT" -gt "$MAX_PRUNE_PER_RUN" ]; then
  DEFERRED_COUNT=$((DUE_COUNT - MAX_PRUNE_PER_RUN))
  head -"$MAX_PRUNE_PER_RUN" "${WORK}/due" > "${WORK}/due.capped"
  mv -f "${WORK}/due.capped" "${WORK}/due"
  DUE_COUNT="$MAX_PRUNE_PER_RUN"
  log "WARNUNG: Obergrenze ${MAX_PRUNE_PER_RUN} je Lauf erreicht — ${DEFERRED_COUNT} Eintrag/Einträge folgen in den nächsten Läufen"
fi

DELETED_COUNT=0
if [ "$DUE_COUNT" -gt 0 ]; then
  : > "${WORK}/candidates"
  : > "${WORK}/drop"     # index entries to remove: deleted or source reappeared
  : > "${WORK}/bump"     # index entries whose failed-deletion counter grows
  : > "${WORK}/deleted"  # proof lines: path + orphan date

  # Interlock 4: re-check the source for every candidate before the deletion batch
  # is issued. Between writing the index and this point a restore or a redeploy may
  # have put the file back. (Deliberately -e, not -f: anything at all sitting at that
  # path is reason enough not to delete.)
  while IFS=$'\t' read -r rel ts fails; do
    [ -n "$rel" ] || continue
    if [ -e "${SRC}/${rel}" ]; then
      log "Quelle wieder vorhanden — keine Löschung, Eintrag abgeräumt: ${rel}"
      printf '%s\n' "$rel" >> "${WORK}/drop"
      continue
    fi
    printf '%s\t%s\t%s\n' "$rel" "$ts" "${fails:-0}" >> "${WORK}/candidates"
  done < "${WORK}/due"

  CAND_COUNT="$(wc -l < "${WORK}/candidates")"
fi

if [ "${CAND_COUNT:-0}" -gt 0 ]; then
  # One sftp connection for all deletions: many quick connections make the box cut
  # the peer off, which then reads like a genuine failure. The leading "-" tells
  # sftp to ignore an error instead of aborting the rest of the batch.
  # SFTP_OPTS muss in einzelne Argumente zerfallen, deshalb bewusst ohne Anfuehrungszeichen.
  # shellcheck disable=SC2086
  cut -f1 "${WORK}/candidates" | sed 's|^|-rm |; s|$|.age|' \
    | sftp ${SFTP_OPTS} "$REMOTE" >/dev/null 2>&1

  # Do not trust the batch's exit code — confirm by listing. Both statements have to
  # be POSITIVE: presence is a listing line, absence is the box's own "not found".
  # Treating "no listing line" as deleted would fail OPEN — an unparsable line, an
  # unexpected permission mode or any other sftp version would silently land on the
  # deletion side, drop the mirror copy and strand the box copy for good.
  #
  # Presence is read from stdout only, where the command echo and its listing line
  # share one stream and their order is guaranteed. The absence proof lives on
  # stderr and is matched by the path inside the message, so no interleaving of the
  # two streams can confuse the classification.
  cut -f1 "${WORK}/candidates" | sed 's|$|.age|' | LC_ALL=C sort > "${WORK}/box_paths"
  # SFTP_OPTS muss in einzelne Argumente zerfallen, deshalb bewusst ohne Anfuehrungszeichen.
  # shellcheck disable=SC2086
  sed 's|^|-ls -l |' "${WORK}/box_paths" \
    | sftp ${SFTP_OPTS} "$REMOTE" > "${WORK}/verify_out" 2> "${WORK}/verify_err"

  # The echo names the path; any following listing line proves presence. Matching on
  # the permission characters rather than on "-rw" keeps an unusual mode from being
  # read as absence.
  awk '/^sftp> -ls -l / { path=$NF; next }
       /^[-dlbcps]/     { if (path != "") { print path; path="" } }' "${WORK}/verify_out" \
    | LC_ALL=C sort -u > "${WORK}/still_on_box"
  # "Can't ls: "/home/zz/pr/x.age" not found" — the box states the absence itself.
  # Matched by suffix so the jail's base path never has to be assumed.
  sed 's/\r$//' "${WORK}/verify_err" | grep -oE '"/[^"]+" not found' | tr -d '"' \
    | sed 's/ not found$//' > "${WORK}/err_paths"
  awk 'FILENAME==ARGV[1] { cand[$0]=1; next }
       { for (c in cand) if (substr($0, length($0) - length(c)) == "/" c) print c }' \
    "${WORK}/box_paths" "${WORK}/err_paths" | LC_ALL=C sort -u > "${WORK}/absent"

  # Every candidate needs exactly one verdict. Anything unclassified or contradictory
  # stops the run: an unclear answer must never be read as "deleted".
  comm -12 "${WORK}/still_on_box" "${WORK}/absent" > "${WORK}/conflict"
  LC_ALL=C sort -u "${WORK}/still_on_box" "${WORK}/absent" > "${WORK}/classified"
  comm -23 "${WORK}/box_paths" "${WORK}/classified" > "${WORK}/unclassified"
  [ ! -s "${WORK}/conflict" ] \
    || die "Box meldet einen Pfad gleichzeitig als vorhanden und als fehlend ($(head -1 "${WORK}/conflict")) — Index unverändert"
  [ ! -s "${WORK}/unclassified" ] \
    || die "Löschung auf der Box nicht verifizierbar: $(wc -l < "${WORK}/unclassified") von ${CAND_COUNT} Pfad(en) ohne Antwort, erster $(head -1 "${WORK}/unclassified") — Index unverändert"

  HARD_FAILS=""
  while IFS=$'\t' read -r rel ts fails; do
    [ -n "$rel" ] || continue
    if grep -qxF "${rel}.age" "${WORK}/still_on_box"; then
      NEXT_FAILS=$((fails + 1))
      printf '%s\n' "$rel" >> "${WORK}/bump"
      if [ "$NEXT_FAILS" -ge "$DELETE_MAX_FAILS" ]; then
        log "FEHLER: Box-Löschung zum ${NEXT_FAILS}. Mal fehlgeschlagen: ${rel}"
        HARD_FAILS="${HARD_FAILS}${rel} (Box, ${NEXT_FAILS} Fehlversuche)"$'\n'
      else
        log "WARNUNG: Box-Löschung fehlgeschlagen (${NEXT_FAILS}. Versuch), Eintrag bleibt: ${rel}"
      fi
      continue
    fi

    # The proof goes to disk BEFORE the mirror copy falls. At this point the box copy
    # is already verified gone, so this line is the only durable evidence that the
    # file ever existed — an abort between here and the end of the run must not lose
    # it. Writing it after the mail, as before, meant a reboot in that window
    # destroyed customer data in both places with nothing left but a log line that
    # rotates away after twelve months.
    printf '%s\tgeloescht\t%s\tverwaist_seit=%s\n' \
      "$RUN_STAMP" "$rel" "$(date -u -d "@${ts}" +%Y-%m-%d)" >> "$DELETION_RECORD"

    rm -f "${MIRROR}/${rel}.age"
    if [ -e "${MIRROR}/${rel}.age" ]; then
      # Same reasoning as the box branch: a mirror deletion that keeps failing lets
      # the promised deadline slip just as silently, so it carries the same counter
      # and the same escalation instead of a warning that rotates away.
      NEXT_FAILS=$((fails + 1))
      printf '%s\n' "$rel" >> "${WORK}/bump"
      if [ "$NEXT_FAILS" -ge "$DELETE_MAX_FAILS" ]; then
        log "FEHLER: Spiegel-Löschung zum ${NEXT_FAILS}. Mal fehlgeschlagen: ${rel}"
        HARD_FAILS="${HARD_FAILS}${rel} (Spiegel, ${NEXT_FAILS} Fehlversuche)"$'\n'
      else
        log "WARNUNG: Spiegel-Löschung fehlgeschlagen (${NEXT_FAILS}. Versuch), Eintrag bleibt: ${rel}"
      fi
      continue
    fi
    log "GELÖSCHT ${rel} verwaist_seit=$(date -u -d "@${ts}" +%Y-%m-%d) orte=spiegel,box"
    printf '%s\t%s\n' "$rel" "$ts" >> "${WORK}/deleted"
    printf '%s\n' "$rel" >> "${WORK}/drop"
  done < "${WORK}/candidates"

  DELETED_COUNT="$(wc -l < "${WORK}/deleted")"
fi

# Rewrite the index once, after the deletions: confirmed and reappeared entries
# vanish, entries whose deletion failed keep their date and carry a raised counter
# into the next run.
if [ -s "${WORK}/drop" ] || [ -s "${WORK}/bump" ]; then
  awk -F'\t' -v OFS='\t' '
    FILENAME==ARGV[1] { drop[$0]=1; next }
    FILENAME==ARGV[2] { bump[$0]=1; next }
    ($1 in drop) { next }
    { f = ($3=="" ? 0 : $3); if ($1 in bump) f = f + 1; print $1, $2, f }
  ' "${WORK}/drop" "${WORK}/bump" "$ORPHAN_INDEX" > "${ORPHAN_INDEX}.tmp" \
    || die "Verwaisungs-Index nach der Löschung nicht neu schreibbar"
  commit_index "nach der Löschung"
fi

# The mail is the record that reaches a human; the durable copy is already on disk
# (see the deletion loop). /var/log/lalabase-backup.log is gone after twelve months,
# and the mail path itself has failed on this host before (AppArmor blocking msmtp on
# a custom config path).
if [ "${DELETED_COUNT:-0}" -gt 0 ]; then
  {
    printf 'Fristgemäße Löschung in der Anhang-Sicherung.\n\n'
    printf 'Frist:       %s Tage nach Verwaisung (Datei in der Anwendung gelöscht)\n' "$ORPHAN_RETENTION_DAYS"
    printf 'Gelöscht am: %s\n' "$RUN_STAMP"
    printf 'Orte:        lokaler Spiegel (%s) und Storage Box\n' "$MIRROR"
    printf 'Host:        %s\n\n' "$(hostname -f)"
    printf 'Gelöschte Dateien (%s):\n\n' "$DELETED_COUNT"
    while IFS=$'\t' read -r rel ts; do
      [ -n "$rel" ] || continue
      printf '  %s\n    verwaist seit %s, gelöscht am %s\n' \
        "$rel" "$(date -u -d "@${ts}" +%Y-%m-%d)" "$RUN_STAMP"
    done < "${WORK}/deleted"
    if [ "$DEFERRED_COUNT" -gt 0 ]; then
      printf '\nGedrosselt: %s weitere fällige Datei(en) folgen in den nächsten Läufen\n' "$DEFERRED_COUNT"
      printf '(Obergrenze %s je Lauf).\n' "$MAX_PRUNE_PER_RUN"
    fi
    printf '\nDie Löschung auf der Box wurde je Datei per Listing bestätigt.\n'
    printf 'Snapshots der Storage Box (14 Stände) laufen darüber hinaus noch nach.\n'
    printf 'Zweitschrift: %s auf %s\n' "$DELETION_RECORD" "$(hostname -f)"
  } | "$ALERT" "Anhang-Sicherung: ${DELETED_COUNT} Datei(en) fristgemäß gelöscht" \
    || die "Löschnachweis konnte nicht versendet werden — Zweitschrift steht in ${DELETION_RECORD}"
  # No success marker above on purpose: if the local mail path is broken, OnFailure=
  # cannot report it either. Withholding the marker leaves the partner host's
  # peer-check as the one channel that still gets a message out.
fi

# --- State copy -------------------------------------------------------------
# The index IS the deadline and the record IS the proof, and both existed only on
# this host's disk. A rebuilt server would have started every running deadline over
# with today's date, silently, and lost the record with it. Never fatal: a failed
# state copy must not stop a backup that otherwise succeeded.
STATE_MIRROR="${MIRROR}/${STATE_PREFIX}"
if mkdir -p "$STATE_MIRROR" && chmod 700 "$STATE_MIRROR"; then
  STATE_OK=1
  for f in "$ORPHAN_INDEX" "$DELETION_RECORD"; do
    B="$(basename "$f")"
    if age -R "$RECIPIENTS" -o "${STATE_MIRROR}/${B}.age.tmp" "$f" 2>/dev/null \
       && mv -f "${STATE_MIRROR}/${B}.age.tmp" "${STATE_MIRROR}/${B}.age"; then
      continue
    fi
    rm -f "${STATE_MIRROR}/${B}.age.tmp"
    STATE_OK=0
    log "WARNUNG: Zustandskopie fehlgeschlagen: ${B}"
  done
  [ "$STATE_OK" -eq 1 ] || log "WARNUNG: Zustandskopie unvollständig — Index und Nachweis liegen nur lokal"
  rsync -e "ssh ${SSH_OPTS}" --archive --exclude='*.age.tmp' \
    "${STATE_MIRROR}/" "${REMOTE}:./${STATE_PREFIX}/" \
    || log "WARNUNG: Zustandskopie nicht zur Storage Box hochgeladen"
else
  log "WARNUNG: Zustandskopie nicht anlegbar: ${STATE_MIRROR}"
fi

# Success marker. The partner host reads this to notice a run that never happened —
# something OnFailure= can never report, because nothing failed. Written after the
# interlocks, which must never look successful, but BEFORE the stuck-deletion error
# below: at that point encryption, completeness check and upload have all succeeded,
# so the backup IS current. Suppressing the marker there would make the partner
# report "Sicherung nicht aktuell" every morning about a backup that is fine — and
# an alarm that says the wrong thing gets ignored, which is the one thing this
# whole alerting chain cannot afford.
date -u +%s > "${STATE_DIR}/last-success"

if [ -n "${HARD_FAILS:-}" ]; then
  {
    printf 'Eine Löschung scheitert wiederholt.\n\n'
    printf 'Damit verrutscht die zugesagte Löschfrist still — deshalb Fehler statt Warnung.\n'
    printf 'Schwelle: %s Fehlversuche.\n\n' "$DELETE_MAX_FAILS"
    printf '%s\n' "$HARD_FAILS"
    printf 'Die Sicherung selbst ist aktuell: Verschlüsselung, Vollständigkeitsprüfung und\n'
    printf 'Upload dieses Laufs waren erfolgreich. Hängen geblieben ist nur die Fristlöschung.\n\n'
    printf 'Host: %s, %s\n' "$(hostname -f)" "$RUN_STAMP"
  } | "$ALERT" "Anhang-Sicherung: Löschung scheitert wiederholt"
  die "Löschung überschreitet ${DELETE_MAX_FAILS} Fehlversuche"
fi

REMAINING=$((MIRROR_COUNT - DELETED_COUNT))
log "Fertig — ${REMAINING} Dateien auf der Box (${DELETED_COUNT} fristgemäß gelöscht, ${DEFERRED_COUNT} verschoben)"
