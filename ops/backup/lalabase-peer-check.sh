#!/bin/bash
# Checks that a backup ran recently — both this host's own and the partner host's.
#
# Why the partner: an OnFailure= hook only fires when a run FAILS. It stays silent
# when a run never happens at all — timer disabled, host down, systemd broken after
# an upgrade. That is the dangerous case, because it is silent for months and only
# surfaces on the day the backup is needed. Each host therefore watches the other.
#
# The SSH key used here is pinned to a forced command on the partner side and can do
# nothing but print that one timestamp.
set -uo pipefail

CONF="/etc/lalabase-backup/alert.conf"
MARKER="/var/lib/lalabase-backup/last-success"
LOG="/var/log/lalabase-backup.log"

log() { printf '%s [peer-check] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
PEER_HOST="${PEER_HOST:-}"
PEER_LABEL="${PEER_LABEL:-Partner-Host}"
PEER_KEY="${PEER_KEY:-/root/.ssh/id_ed25519_peercheck}"
OWN_LABEL="${OWN_LABEL:-dieser Host}"
# 26 rather than 24: a run that shifts by an hour is normal. An alarm that cries
# wolf gets ignored within two weeks, which is worse than no alarm at all.
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"

NOW="$(date -u +%s)"
MAX_AGE_SECONDS=$((MAX_AGE_HOURS * 3600))
PROBLEMS=""

age_line() { # $1 = epoch, $2 = label
  local age_h=$(((NOW - $1) / 3600))
  printf '%s: letzter Erfolg %s (vor %s Stunden)\n' \
    "$2" "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)" "$age_h"
}

# --- own marker -------------------------------------------------------------
if [ -r "$MARKER" ]; then
  OWN_TS="$(cat "$MARKER" 2>/dev/null)"
  case "$OWN_TS" in
    ''|*[!0-9]*) PROBLEMS="${PROBLEMS}${OWN_LABEL}: Zeitstempel unlesbar (\"${OWN_TS}\")."$'\n' ;;
    *) if [ $((NOW - OWN_TS)) -gt "$MAX_AGE_SECONDS" ]; then
         PROBLEMS="${PROBLEMS}$(age_line "$OWN_TS" "$OWN_LABEL") — ÄLTER als ${MAX_AGE_HOURS}h."$'\n'
       fi ;;
  esac
else
  PROBLEMS="${PROBLEMS}${OWN_LABEL}: kein Erfolgs-Zeitstempel vorhanden (${MARKER})."$'\n'
fi

# --- partner marker ---------------------------------------------------------
if [ -n "$PEER_HOST" ]; then
  PEER_TS="$(ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=yes \
    -i "$PEER_KEY" "$PEER_HOST" 2>/dev/null | tr -d '[:space:]')"
  case "$PEER_TS" in
    '') PROBLEMS="${PROBLEMS}${PEER_LABEL}: nicht erreichbar oder keine Antwort (${PEER_HOST})."$'\n' ;;
    *[!0-9]*) PROBLEMS="${PROBLEMS}${PEER_LABEL}: Zeitstempel unlesbar (\"${PEER_TS}\")."$'\n' ;;
    *) if [ $((NOW - PEER_TS)) -gt "$MAX_AGE_SECONDS" ]; then
         PROBLEMS="${PROBLEMS}$(age_line "$PEER_TS" "$PEER_LABEL") — ÄLTER als ${MAX_AGE_HOURS}h."$'\n'
       fi ;;
  esac
fi

# --- verdict ----------------------------------------------------------------
if [ -n "$PROBLEMS" ]; then
  log "ALARM: $(printf '%s' "$PROBLEMS" | tr '\n' ' ')"
  {
    printf 'Mindestens eine Sicherung ist nicht aktuell.\n\n'
    printf '%s\n' "$PROBLEMS"
    printf 'Geprüft am %s von %s aus.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname -f)"
    printf 'Schwelle: %s Stunden.\n\n' "$MAX_AGE_HOURS"
    printf -- '--- /var/log/lalabase-backup.log (letzte 20 Zeilen) ---\n'
    tail -20 "$LOG" 2>/dev/null
  } | /usr/local/sbin/lalabase-alert.sh "Sicherung nicht aktuell"
  # Exit 0 on purpose: a stale backup is this unit's expected FINDING, already
  # reported by mail. A non-zero exit is reserved for the checker itself breaking,
  # which OnFailure= then reports — otherwise every alarm would arrive twice.
  exit 0
fi

log "ok — eigene und Partner-Sicherung sind aktuell"
