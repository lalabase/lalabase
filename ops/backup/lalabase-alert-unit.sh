#!/bin/bash
# Called by systemd via OnFailure= with the failed unit name as $1.
# Collects enough context that the mail alone explains what happened.
set -uo pipefail

UNIT="${1:-unbekannt}"

{
  printf 'Die Unit %s ist fehlgeschlagen.\n\n' "$UNIT"
  printf 'Host:      %s\n' "$(hostname -f)"
  printf 'Zeitpunkt: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '--- systemctl status ---\n'
  systemctl status --no-pager --lines=0 "$UNIT" 2>&1 | head -20
  printf '\n--- Journal (letzte 30 Zeilen) ---\n'
  journalctl --no-pager -u "$UNIT" -n 30 2>&1
  printf '\n--- /var/log/lalabase-backup.log (letzte 20 Zeilen) ---\n'
  tail -20 /var/log/lalabase-backup.log 2>/dev/null
} | /usr/local/sbin/lalabase-alert.sh "FEHLGESCHLAGEN: ${UNIT}"
