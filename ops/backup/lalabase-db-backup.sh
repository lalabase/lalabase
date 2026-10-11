#!/bin/bash
# Encrypted daily backup of the production database to the Hetzner Storage Box.
#
# Design notes:
#   * Only the age PUBLIC key lives on this host. A compromised server can create
#     backups but cannot read older ones. The private key is on the operator's Mac.
#   * The Storage Box sub-account is jailed to its own directory and speaks SSH on
#     port 23 (not 22). It needs delete rights for pruning, so deletion protection
#     comes from the Storage Box snapshots, not from the account's permissions.
#   * Remote pruning is driven by the timestamp in the filename, because the box
#     offers no shell to run `find` in.
set -uo pipefail

BACKUP_DIR="/var/backups/postgres"
RECIPIENTS="/etc/lalabase-backup/recipients.txt"
# Site-specific coordinates (database name, Storage Box sub-account, SSH key).
# Deliberately NOT defaulted here: a hardcoded name or account travels with every
# published copy of this repo. Template: ops/backup/backup.conf.example.
# shellcheck source=/dev/null
[ -r /etc/lalabase-backup/backup.conf ] && . /etc/lalabase-backup/backup.conf
: "${DB_NAME:?nicht gesetzt - /etc/lalabase-backup/backup.conf fehlt oder nennt DB_NAME nicht (Vorlage: ops/backup/backup.conf.example)}"
: "${SSH_KEY:?nicht gesetzt - /etc/lalabase-backup/backup.conf fehlt (Vorlage: ops/backup/backup.conf.example)}"
: "${REMOTE:?nicht gesetzt - /etc/lalabase-backup/backup.conf fehlt (Vorlage: ops/backup/backup.conf.example)}"
# NOTE: ssh takes the port as -p, sftp as -P. Sharing one option string between
# them silently turns -p into sftp's "preserve permissions" flag and swallows 23.
SSH_OPTS="-p 23 -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30"
SFTP_OPTS="-P 23 -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30"
KEEP_LOCAL_DAYS=7
KEEP_REMOTE_DAYS=35
LOG="/var/log/lalabase-backup.log"
LOCK="/var/lock/lalabase-db-backup.lock"

log() { printf '%s [db-backup] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
die() { log "FEHLER: $*"; exit 1; }

exec 9>"$LOCK" || die "Lock-Datei nicht anlegbar"
flock -n 9 || die "Ein Lauf ist noch aktiv — abgebrochen"

STAMP="$(date -u +%Y%m%d_%H%M%SZ)"
PLAIN="${BACKUP_DIR}/${DB_NAME}_${STAMP}.dump"
CRYPT="${PLAIN}.age"

mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || die "Backup-Verzeichnis nicht nutzbar"

log "Start"

# --- Dump -------------------------------------------------------------------
sudo -n -u postgres pg_dump -Fc -Z6 -d "$DB_NAME" -f "$PLAIN" || die "pg_dump fehlgeschlagen"
[ -s "$PLAIN" ] || die "Dump ist leer"

# --- Verification: does the dump contain every table the live DB has? -------
# `grep -c` exits 1 on zero matches, so both counts are captured defensively.
EXPECTED="$(sudo -n -u postgres psql -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'" \
  -d "$DB_NAME" 2>/dev/null)"
ACTUAL="$(pg_restore -l "$PLAIN" 2>/dev/null | grep -c 'TABLE DATA' || true)"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  rm -f "$PLAIN"
  die "Tabellenzahl weicht ab (DB: ${EXPECTED:-?}, Dump: ${ACTUAL:-?}) — Dump verworfen"
fi
log "Dump ok: $(du -h "$PLAIN" | cut -f1), ${ACTUAL} Tabellen"

# --- Encrypt, then drop the plaintext immediately ---------------------------
age -R "$RECIPIENTS" -o "$CRYPT" "$PLAIN" || { rm -f "$PLAIN" "$CRYPT"; die "Verschlüsselung fehlgeschlagen"; }
rm -f "$PLAIN"
[ -s "$CRYPT" ] || die "Verschlüsselte Datei ist leer"
chmod 600 "$CRYPT"
log "Verschlüsselt: $(basename "$CRYPT") ($(du -h "$CRYPT" | cut -f1))"

# --- Upload -----------------------------------------------------------------
rsync -e "ssh ${SSH_OPTS}" --partial --times "$CRYPT" "${REMOTE}:./" \
  || die "Upload zur Storage Box fehlgeschlagen"

# sftp echoes the command back, and that echo line carries the filename too —
# matching on the name alone would capture the echo as well. Match the listing
# line itself instead.
REMOTE_SIZE="$(printf 'ls -l %s\n' "$(basename "$CRYPT")" | sftp ${SFTP_OPTS} "$REMOTE" 2>/dev/null \
  | awk '/^-rw/ {print $5}' | tail -1)"
LOCAL_SIZE="$(stat -c %s "$CRYPT")"
[ "$REMOTE_SIZE" = "$LOCAL_SIZE" ] || die "Größe auf der Box weicht ab (lokal ${LOCAL_SIZE}, remote ${REMOTE_SIZE:-fehlt})"
log "Upload verifiziert: ${LOCAL_SIZE} Bytes"

# --- Prune locally ----------------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}_*.dump.age" -mtime "+${KEEP_LOCAL_DAYS}" -print -delete \
  | while read -r f; do log "lokal gelöscht: $(basename "$f")"; done

# --- Prune on the box (filename-driven; the box has no shell) ---------------
CUTOFF="$(date -u -d "${KEEP_REMOTE_DAYS} days ago" +%Y%m%d)"
REMOTE_LIST="$(printf 'ls -1\n' | sftp ${SFTP_OPTS} "$REMOTE" 2>/dev/null \
  | grep -oE "${DB_NAME}_[0-9]{8}_[0-9]{6}Z\.dump\.age" || true)"
RM_BATCH=""
while read -r f; do
  [ -n "$f" ] || continue
  FDATE="$(printf '%s' "$f" | grep -oE '[0-9]{8}' | head -1)"
  [ -n "$FDATE" ] || continue
  if [ "$FDATE" -lt "$CUTOFF" ]; then
    RM_BATCH="${RM_BATCH}rm ${f}"$'\n'
    log "Box gelöscht: ${f}"
  fi
done <<< "$REMOTE_LIST"
if [ -n "$RM_BATCH" ]; then
  printf '%s' "$RM_BATCH" | sftp ${SFTP_OPTS} "$REMOTE" >/dev/null 2>&1 \
    || log "WARNUNG: Aufräumen auf der Box unvollständig"
fi

# Success marker. The partner host reads this to notice a run that never happened —
# something OnFailure= can never report, because nothing failed.
mkdir -p /var/lib/lalabase-backup
date -u +%s > /var/lib/lalabase-backup/last-success

log "Fertig"
