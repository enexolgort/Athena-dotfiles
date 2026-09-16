#!/usr/bin/env bash
# setup.sh — Athena, a Hostinger VPS (Debian).
# One flat script, sectioned like the old configuration.nix was: every
# service below is idempotent (safe to re-run the whole thing, or just
# one section) and converges the machine to match what's declared here —
# the same "edit, then apply" loop nixos-rebuild switch gave us, just
# implemented in bash + systemd instead of Nix.
#
# Usage:
#   sudo ./setup.sh              # run everything, in order
#   sudo ./setup.sh docker n8n   # run only the named section(s)
#   sudo ./setup.sh --list       # list section names
#
# Safe to re-run any time after editing this file — each section only
# changes what's actually out of date (see run_container/ensure_* below).

set -euo pipefail

# --- Config (the "options" block — edit these, then re-run) -----------
HOSTNAME_NEW="athena"
DEPLOY_USER="deploy"
ENEXOLGORT_USER="enexolgort"
TIMEZONE="UTC"

FORGEJO_VERSION="10.0.3"  # check https://codeberg.org/forgejo/forgejo/releases/latest
                          # and bump this, then re-run `./setup.sh forgejo` to upgrade
FORGEJO_DATA_DIR="/var/lib/forgejo"
FORGEJO_USER="forgejo"
FORGEJO_ADMIN_USER="enexolgort"
FORGEJO_ADMIN_EMAIL="enexolgort@athena.local"

OLLAMA_MODEL="qwen2.5:7b"

N8N_DATA_DIR="/var/lib/n8n"

BACKUP_DIR="/var/backups/athena"
BACKUP_RETENTION_DAYS=14

STATE_DIR="/var/lib/vps-setup"  # tracks per-section "desired config" hashes, so
                                 # re-running only touches things that actually changed

# --- Helpers ------------------------------------------------------------
log() { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m!!\033[0m $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo ./setup.sh ...)" >&2
    exit 1
  fi
}

mkdir_state() { mkdir -p "$STATE_DIR"; }

# changed_since <key> <content>: writes $content's hash under $STATE_DIR/$key
# and returns 0 (true/"changed") if it differs from what's stored, 1 otherwise.
# Use this to skip re-doing expensive/disruptive work (like recreating a
# container) when nothing about its desired config actually changed.
changed_since() {
  local key="$1" content="$2" file="$STATE_DIR/$key.hash" newhash
  newhash=$(echo -n "$content" | sha256sum | cut -d' ' -f1)
  mkdir_state
  if [ -f "$file" ] && [ "$(cat "$file")" = "$newhash" ]; then
    return 1
  fi
  echo "$newhash" > "$file"
  return 0
}

prompt_password() {
  # prompt_password <description> <outvar> — interactive, hidden input,
  # confirmed twice. Only called at actual creation time (see call
  # sites below), never on a no-op re-run, so it doesn't nag you for a
  # password on every `./setup.sh`.
  local desc="$1" __outvar="$2" p1 p2
  while true; do
    read -r -s -p "Set a password for $desc: " p1; echo >&2
    read -r -s -p "Confirm: " p2; echo >&2
    if [ -z "$p1" ]; then
      echo "Password can't be empty." >&2
    elif [ "$p1" != "$p2" ]; then
      echo "Passwords didn't match — try again." >&2
    else
      break
    fi
  done
  printf -v "$__outvar" '%s' "$p1"
}

pkg_install() {
  local missing=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt-get update -qq
    apt-get install -y "${missing[@]}"
  fi
}

user_ensure() {
  # user_ensure <name> <groups-csv>
  local name="$1" groups="$2" pass
  if ! id "$name" >/dev/null 2>&1; then
    prompt_password "the new '$name' user" pass
    useradd -m -s /bin/bash -G "$groups" "$name"
    echo "$name:$pass" | chpasswd
    log "Created user $name"
  else
    usermod -G "$groups" "$name"
  fi
}

system_user_ensure() {
  # system_user_ensure <name> <home-dir>
  local name="$1" home="$2"
  if ! id "$name" >/dev/null 2>&1; then
    useradd --system --home "$home" --create-home --shell /usr/sbin/nologin "$name"
  fi
}

line_in_file() {
  # line_in_file <file> <exact-line>  — appends only if not already present
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

enable_now() { systemctl enable --now "$1" >/dev/null; }

run_container() {
  # run_container <name> <image> <run-args...>
  # Recreates the container only if the image or run args actually changed
  # (or it's not currently running) — mirrors how NixOS's oci-containers
  # module only touches a container when its definition changes.
  local name="$1" image="$2"; shift 2
  local desired="$image $*"
  if changed_since "container-$name" "$desired" || ! docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
    log "(Re)creating container: $name"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker pull "$image" >/dev/null
    # shellcheck disable=SC2068
    docker run -d --name "$name" --restart unless-stopped $@ "$image" >/dev/null
  else
    log "Container $name unchanged, skipping"
  fi
}

# --- Sections -------------------------------------------------------------

section_base_packages() {
  log "Base packages"
  apt-get update -qq
  pkg_install vim git wget curl htop btop ncdu jq tmux ca-certificates gnupg lsb-release ufw
}

section_hostname() {
  log "Hostname -> $HOSTNAME_NEW"
  hostnamectl set-hostname "$HOSTNAME_NEW"
  line_in_file /etc/hosts "127.0.1.1 $HOSTNAME_NEW"
  timedatectl set-timezone "$TIMEZONE"
}

section_users() {
  log "Users"
  user_ensure "$DEPLOY_USER" "sudo,docker"
  user_ensure "$ENEXOLGORT_USER" "sudo"
}

section_ssh() {
  log "SSH hardening"
  pkg_install openssh-server
  line_in_file /etc/ssh/sshd_config.d/99-local.conf "PermitRootLogin no"
  line_in_file /etc/ssh/sshd_config.d/99-local.conf "PasswordAuthentication yes"
  systemctl reload sshd || systemctl reload ssh
}

section_tailscale() {
  log "Tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  enable_now tailscaled
  # --ssh deliberately NOT passed: Tailscale SSH bypasses sshd_config
  # entirely (including PermitRootLogin above), so it's kept off and
  # explicitly disabled below in case it was ever turned on manually.
  tailscale set --ssh=false || true
  echo "Run manually if not already joined: sudo tailscale up --hostname=$HOSTNAME_NEW"
}

section_firewall() {
  log "Firewall (ufw)"
  ufw --force enable
  ufw allow 22/tcp comment 'SSH - public + tailnet until confirmed working over tailnet only'
  ufw allow 41641/udp comment 'Tailscale direct connections'
  ufw allow in on tailscale0 comment 'trust the whole tailnet, like NixOS trustedInterfaces did'
}

section_docker() {
  log "Docker"
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
  fi
  pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  enable_now docker

  log "Docker autoprune (weekly)"
  cat > /etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Prune unused Docker data
[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -af
EOF
  cat > /etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Run docker-prune weekly
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  enable_now docker-prune.timer
}

section_postgres() {
  log "Postgres (backs the n8n watchlist workflows — localhost-only)"
  pkg_install postgresql

  local pgconf pghba
  pgconf=$(find /etc/postgresql -maxdepth 2 -name postgresql.conf | head -n1)
  pghba=$(find /etc/postgresql -maxdepth 2 -name pg_hba.conf | head -n1)

  sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" "$pgconf"
  line_in_file "$pghba" "host watchlist n8n 127.0.0.1/32 scram-sha-256"

  systemctl restart postgresql

  if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='n8n'" | grep -q 1; then
    local pgpass
    prompt_password "the Postgres 'n8n' role (used by n8n's Postgres credential)" pgpass
    sudo -u postgres psql -c "CREATE ROLE n8n WITH LOGIN PASSWORD '$pgpass';"
  fi

  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='watchlist'" | grep -q 1 || \
    sudo -u postgres createdb watchlist

  sudo -u postgres psql -d watchlist -c "CREATE TABLE IF NOT EXISTS to_watch (
    id serial PRIMARY KEY,
    title text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('book','movie','tv show')),
    status text NOT NULL DEFAULT 'to watch' CHECK (status IN ('to watch','watching','done')),
    notes text,
    added_at timestamptz NOT NULL DEFAULT now()
  );" >/dev/null
  sudo -u postgres psql -d watchlist -c "GRANT ALL PRIVILEGES ON TABLE to_watch TO n8n;" >/dev/null
  sudo -u postgres psql -d watchlist -c "GRANT USAGE, SELECT ON SEQUENCE to_watch_id_seq TO n8n;" >/dev/null
}

section_forgejo() {
  log "Forgejo (git server) v$FORGEJO_VERSION"
  system_user_ensure "$FORGEJO_USER" "$FORGEJO_DATA_DIR"
  mkdir -p "$FORGEJO_DATA_DIR" /etc/forgejo
  chown "$FORGEJO_USER:$FORGEJO_USER" "$FORGEJO_DATA_DIR"

  local bin=/usr/local/bin/forgejo
  if [ ! -x "$bin" ] || ! "$bin" --version 2>/dev/null | grep -q "$FORGEJO_VERSION"; then
    curl -fsSL -o "$bin" \
      "https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}/forgejo-${FORGEJO_VERSION}-linux-amd64"
    chmod +x "$bin"
  fi

  cat > /etc/forgejo/app.ini <<EOF
[server]
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
ROOT_URL  = http://${HOSTNAME_NEW}:3000/
[service]
DISABLE_REGISTRATION = true
[webhook]
ALLOWED_HOST_LIST = loopback
EOF
  chown "$FORGEJO_USER:$FORGEJO_USER" /etc/forgejo/app.ini

  cat > /etc/systemd/system/forgejo.service <<EOF
[Unit]
Description=Forgejo git server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=$FORGEJO_USER
WorkingDirectory=$FORGEJO_DATA_DIR
ExecStart=$bin web --config /etc/forgejo/app.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  enable_now forgejo

  sleep 3
  if ! sudo -u "$FORGEJO_USER" "$bin" admin user list --config /etc/forgejo/app.ini 2>/dev/null \
      | awk '{print $2}' | grep -qx "$FORGEJO_ADMIN_USER"; then
    local fjpass
    prompt_password "the Forgejo admin user '$FORGEJO_ADMIN_USER'" fjpass
    sudo -u "$FORGEJO_USER" "$bin" admin user create --config /etc/forgejo/app.ini \
      --admin --username "$FORGEJO_ADMIN_USER" --password "$fjpass" \
      --email "$FORGEJO_ADMIN_EMAIL" || true
  fi
}

section_ollama() {
  log "Ollama + Open WebUI"
  if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  mkdir -p /etc/systemd/system/ollama.service.d
  cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
  systemctl daemon-reload
  enable_now ollama
  ollama pull "$OLLAMA_MODEL" || warn "ollama pull failed — check ollama.service is up"

  run_container open-webui ghcr.io/open-webui/open-webui:main \
    --network=host \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -v open-webui:/app/backend/data
}

section_n8n() {
  log "n8n"
  mkdir -p "$N8N_DATA_DIR"
  chown 1000:1000 "$N8N_DATA_DIR"
  run_container n8n docker.n8n.io/n8nio/n8n:latest \
    --network=host \
    -v "$N8N_DATA_DIR:/home/node/.n8n" \
    -e N8N_PORT=5678 \
    -e N8N_SECURE_COOKIE=false \
    -e GENERIC_TIMEZONE="$TIMEZONE" \
    -e NODE_OPTIONS=--dns-result-order=ipv4first \
    -e NODES_EXCLUDE='[]' \
    -e NODE_FUNCTION_ALLOW_BUILTIN=net,crypto,fs,path,util,querystring,url,os,stream,zlib,dns,http,https,buffer,assert
}

section_uptime_kuma() {
  log "Uptime Kuma"
  mkdir -p /var/lib/uptime-kuma
  run_container uptime-kuma louislam/uptime-kuma:1 \
    --network=host \
    -v /var/lib/uptime-kuma:/app/data \
    -e UPTIME_KUMA_PORT=3001 \
    -e NODE_OPTIONS=--dns-result-order=ipv4first
}

section_backups() {
  log "Backups (daily, $BACKUP_RETENTION_DAYS-day retention, local-only — see readme)"
  mkdir -p "$BACKUP_DIR"
  cat > /usr/local/bin/athena-backup.sh <<EOF
#!/usr/bin/env bash
set -eu
DEST=$BACKUP_DIR
STAMP=\$(date +%Y-%m-%d)
mkdir -p "\$DEST"
sudo -u postgres pg_dump watchlist | gzip -c > "\$DEST/watchlist-\$STAMP.sql.gz"
tar czf "\$DEST/n8n-\$STAMP.tar.gz" -C "$(dirname "$N8N_DATA_DIR")" "$(basename "$N8N_DATA_DIR")"
tar czf "\$DEST/forgejo-\$STAMP.tar.gz" -C "$(dirname "$FORGEJO_DATA_DIR")" "$(basename "$FORGEJO_DATA_DIR")"
find "\$DEST" -mindepth 1 -mtime +$BACKUP_RETENTION_DAYS -delete
EOF
  chmod +x /usr/local/bin/athena-backup.sh

  cat > /etc/systemd/system/athena-backup.service <<'EOF'
[Unit]
Description=Back up Postgres watchlist DB, n8n data, and Forgejo data
[Service]
Type=oneshot
ExecStart=/usr/local/bin/athena-backup.sh
EOF
  cat > /etc/systemd/system/athena-backup.timer <<'EOF'
[Unit]
Description=Run athena-backup daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  enable_now athena-backup.timer
}

# --- Runner -----------------------------------------------------------
ALL_SECTIONS=(base_packages hostname docker users ssh tailscale firewall postgres forgejo ollama n8n uptime_kuma backups)

main() {
  require_root
  mkdir_state

  if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${ALL_SECTIONS[@]}"
    exit 0
  fi

  local targets=("$@")
  [ "${#targets[@]}" -eq 0 ] && targets=("${ALL_SECTIONS[@]}")

  for t in "${targets[@]}"; do
    if declare -f "section_$t" >/dev/null; then
      "section_$t"
    else
      echo "Unknown section: $t (see --list)" >&2
      exit 1
    fi
  done

  log "Done."
}

main "$@"
