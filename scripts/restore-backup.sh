#!/usr/bin/env bash
# restore-backup.sh
# Run ON the VPS itself, as root, to restore the most recent backup
# produced by the vps-backup systemd service (see configuration.nix and
# the "Backups" section of readme.md). Destructive: overwrites whatever
# is currently in the target(s), always prompts for confirmation first.
#
# Usage: sudo ./restore-backup.sh [postgres|n8n|forgejo|all] [-y|--yes]
#   (default target: all)
#   -y/--yes skips the confirmation prompt (for scripting - use with care)

set -euo pipefail

BACKUP_DIR="/var/backups/vps"
TARGET="all"
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    postgres|n8n|forgejo|all) TARGET="$1"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Must be run as root (it stops/starts services and writes under /var/lib)." >&2
  exit 1
fi

latest() {
  # $1 = filename prefix (e.g. "watchlist"); prints the newest matching
  # backup file's path, or nothing if none exist.
  ls -t "$BACKUP_DIR"/"$1"-*.* 2>/dev/null | head -n1
}

restore_postgres() {
  local file; file=$(latest watchlist)
  if [ -z "$file" ]; then
    echo "No watchlist backup found in $BACKUP_DIR - skipping Postgres restore." >&2
    return
  fi
  echo "Restoring Postgres 'watchlist' from $file"
  # Dumps aren't taken with --clean, so the table is dropped here first -
  # otherwise CREATE TABLE / COPY in the dump can collide with existing
  # data (duplicate keys, "relation already exists").
  runuser -u postgres -- psql -d watchlist -c "DROP TABLE IF EXISTS to_watch CASCADE;"
  gunzip -c "$file" | runuser -u postgres -- psql -d watchlist
  echo "Postgres restore done."
}

restore_n8n() {
  local file; file=$(latest n8n)
  if [ -z "$file" ]; then
    echo "No n8n backup found in $BACKUP_DIR - skipping n8n restore." >&2
    return
  fi
  echo "Restoring n8n from $file"
  systemctl stop docker-n8n.service
  tar xzf "$file" -C /var/lib
  systemctl start docker-n8n.service
  echo "n8n restore done."
}

restore_forgejo() {
  local file; file=$(latest forgejo)
  if [ -z "$file" ]; then
    echo "No forgejo backup found in $BACKUP_DIR - skipping Forgejo restore." >&2
    return
  fi
  echo "Restoring Forgejo from $file"
  systemctl stop forgejo.service
  tar xzf "$file" -C /var/lib
  systemctl start forgejo.service
  echo "Forgejo restore done."
}

echo "About to restore: $TARGET (from the newest backup file per component in $BACKUP_DIR)"
echo "This overwrites current data. Existing files not present in the backup are NOT removed (tar extraction only adds/overwrites)."
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

case "$TARGET" in
  postgres) restore_postgres ;;
  n8n) restore_n8n ;;
  forgejo) restore_forgejo ;;
  all) restore_postgres; restore_n8n; restore_forgejo ;;
esac

echo "Done."
