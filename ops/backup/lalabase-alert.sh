#!/bin/bash
# Sends a system alert by mail. Subject as $1, body on stdin.
#
# Deliberately separate from the application's mail path: this uses its own SMTP
# account, so a compromised server can raise alarms but cannot write to customers
# in the product's name.
set -uo pipefail

CONF="/etc/lalabase-backup/alert.conf"
MSMTPRC="/etc/lalabase-backup/msmtprc"
LOG="/var/log/lalabase-backup.log"

SUBJECT="${1:-Lalabase Systemmeldung}"
HOSTNAME_SHORT="$(hostname -s)"

log() { printf '%s [alert] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
ALERT_TO="${ALERT_TO:-}"
ALERT_FROM="${ALERT_FROM:-}"

if [ -z "$ALERT_TO" ] || [ ! -r "$MSMTPRC" ]; then
  log "FEHLER: Alarm nicht versendet — ALERT_TO oder ${MSMTPRC} fehlt. Betreff war: ${SUBJECT}"
  exit 1
fi

BODY="$(cat)"

{
  printf 'From: %s\n' "$ALERT_FROM"
  printf 'To: %s\n' "$ALERT_TO"
  printf 'Subject: [Lalabase %s] %s\n' "$HOSTNAME_SHORT" "$SUBJECT"
  printf 'Content-Type: text/plain; charset=UTF-8\n'
  printf '\n'
  printf '%s\n' "$BODY"
} | msmtp --file="$MSMTPRC" --read-envelope-from -- "$ALERT_TO"

if [ $? -eq 0 ]; then
  log "Alarm versendet an ${ALERT_TO}: ${SUBJECT}"
else
  log "FEHLER: msmtp konnte den Alarm nicht zustellen. Betreff war: ${SUBJECT}"
  exit 1
fi
