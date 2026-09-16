# configuration.nix — Athena, a Hostinger VPS.
# One flat file, nothing hardcoded behind toggles: every service below
# is one you actually turned on (Obsidian sync, git server, local AI,
# n8n, Uptime Kuma). Everything reachable is tailnet-only except SSH, which is also
# open on the public interface until Tailscale SSH is confirmed working
# (see the firewall section below).
{ config, pkgs, lib, ... }:

{
  # --- Identity / locale ------------------------------------------------
  networking.hostName = "Athena";
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  # /etc/resolv.conf on this VPS had no nameserver lines at all (DHCP
  # never handed any over) — every hostname lookup failed while raw IP
  # traffic worked fine, which is what broke n8n's image pull. Setting
  # these explicitly is what actually populates resolv.conf's
  # nameserver entries.
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # --- Nix itself ---------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Without this, every rebuild leaves the old generation in the store
  # and disk usage only ever grows — worth being deliberate about this
  # on a VPS, where disk is usually the tightest resource.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-generations +2";
  };
  nix.settings.auto-optimise-store = true;

  # --- Bootloader -----------------------------------------------------
  # Confirmed via `lsblk`: this VPS's disk is /dev/sda (virtio-scsi).
  # Confirmed via `sudo parted /dev/sda -- print`: "msdos" partition
  # table (BIOS/legacy boot) — that's why this is GRUB, not
  # systemd-boot (which is UEFI-only).
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  # --- User account -----------------------------------------------------
  # Set a real password after first boot with: passwd deploy
  users.users.deploy = {
    isNormalUser = true;
    description = "vps admin";
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    initialPassword = "changeme"; # CHANGE on first login
  };
  users.users.enexolgort = {
    isNormalUser = true;
    description = "enexolgort";
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
    initialPassword = "changeme"; # CHANGE on first login
  };

  system.stateVersion = "24.11"; # do not change after initial install

  # --- Tailscale + firewall lockdown -------------------------------
  # trustedInterfaces means any service that binds 0.0.0.0 is
  # automatically tailnet-only with zero extra config — that's why
  # forgejo/ollama/open-webui/n8n below need no firewall rules
  # of their own.
  services.tailscale.enable = true;
  systemd.services.tailscaled = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ 41641 ]; # lets Tailscale establish direct (non-relayed) connections
    # SSH on the PUBLIC interface too, deliberately — this VPS has no
    # physical console to fall back on. Without this, the very first
    # `sudo tailscale up --ssh` (which needs an SSH session to run in
    # the first place) would be unreachable the moment this applies.
    # Once Tailscale SSH is confirmed working, remove 22 here and
    # rebuild to go fully tailnet-only.
    allowedTCPPorts = [ 22 ];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true; # fine — SSH itself is tailnet-only (see above)
    settings.PermitRootLogin = "no"; # use deploy/enexolgort + sudo instead — no direct root login over SSH
  };

  # --- Docker -----------------------------------------------------------
  virtualisation.docker = {
    enable = true;
    package = pkgs.docker_29; # default (docker_28) is unmaintained/insecure as of nixos-25.11
  };
  systemd.services.docker = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
  # Unlike the Nix store (nix.gc above), nothing else here prunes old
  # Docker layers, stopped containers, or dangling images — they'd
  # otherwise grow unbounded. --all also removes unused (not just
  # dangling) images, safe here since every image this box runs is
  # declared above and gets re-pulled/rebuilt automatically if needed.
  virtualisation.docker.autoPrune = {
    enable = true;
    dates = "weekly";
    flags = [ "--all" ];
  };

  # --- Postgres (backing store for the n8n watchlist workflows below) --
  # Localhost-only, deliberately: n8n runs on the same host (--network=host,
  # so "127.0.0.1" from inside its container is this host's loopback), and
  # nothing else needs to reach this DB — so it's never added to the
  # firewall/tailnet surface at all, unlike every other service in this file.
  services.postgresql = {
    enable = true;
    enableTCPIP = true; # off by default (unix socket only) — n8n's Postgres node only speaks TCP
    ensureDatabases = [ "watchlist" ];
    ensureUsers = [
      { name = "n8n"; } # not ensureDBOwnership: that shortcut requires a database
                        # named identically to the user ("n8n"), which "watchlist"
                        # isn't — privileges are granted explicitly by the oneshot below.
    ];
    # ensureUsers has no password support (it's for peer-auth roles) —
    # password + privileges + schema are set by the oneshot below instead.
    authentication = lib.mkForce ''
      local all all peer
      host watchlist n8n 127.0.0.1/32 scram-sha-256
    '';
  };
  # ensureDatabases/ensureUsers don't run inside postgresql.service itself —
  # NixOS applies them via a separate "postgresql-setup.service" unit that
  # is merely `after`/`requires` postgresql.service. Our first attempt
  # ordered against postgresql.service directly and raced that setup unit
  # (postgresql.service was "active" before "watchlist" existed). Ordering
  # against postgresql-setup.service instead guarantees the database and
  # the "n8n" role both already exist by the time this runs.
  systemd.services.postgresql-watchlist-init = {
    description = "Set n8n's watchlist DB password and create the to_watch table";
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
    };
    path = [ config.services.postgresql.package ];
    script = ''
      psql -d watchlist -c "ALTER USER n8n WITH PASSWORD 'changeme-db';"
      psql -d watchlist -c "CREATE TABLE IF NOT EXISTS to_watch (
        id serial PRIMARY KEY,
        title text NOT NULL,
        kind text NOT NULL CHECK (kind IN ('book','movie','tv show')),
        status text NOT NULL DEFAULT 'to watch' CHECK (status IN ('to watch','watching','done')),
        notes text,
        added_at timestamptz NOT NULL DEFAULT now()
      );"
      # The table above is created by the postgres superuser, so n8n's role
      # needs explicit grants — including on the id sequence, since INSERT
      # needs to advance it too.
      psql -d watchlist -c "GRANT ALL PRIVILEGES ON TABLE to_watch TO n8n;"
      psql -d watchlist -c "GRANT USAGE, SELECT ON SEQUENCE to_watch_id_seq TO n8n;"
    '';
  };

  # --- Self-hosted git server (Forgejo) --------------------------------
  # Lightweight (single Go binary, SQLite by default). Reachable at
  # http://<tailscale-ip>:3000.
  services.forgejo = {
    enable = true;
    settings.server = {
      HTTP_ADDR = "0.0.0.0"; # firewall (trustedInterfaces above) restricts real exposure
      HTTP_PORT = 3000;
      ROOT_URL = "http://Athena:3000/";
    };
    settings.service.DISABLE_REGISTRATION = true; # single-user server — no public signup
    settings.webhook.ALLOWED_HOST_LIST = "loopback"; # allow webhooks to call 127.0.0.1 — needed since n8n runs on the same host
  };
  # Declaratively ensures the admin account exists — idempotent (`|| true`
  # means it doesn't fail on every subsequent rebuild once already
  # created). "admin" itself is a reserved username in Forgejo, hence
  # "enexolgort" below instead.
  systemd.services.forgejo.preStart = ''
    ${lib.getExe config.services.forgejo.package} admin user create \
      --admin --username enexolgort --password "changeme-git" \
      --email "enexolgort@athena.local" || true
  '';
  systemd.services.forgejo.after = [ "network-online.target" ];
  systemd.services.forgejo.wants = [ "network-online.target" ];

  # --- Local AI: Ollama + Open WebUI -----------------------------------
  # CPU-only (no GPU passthrough on this plan). Ollama listens on 11434,
  # Open WebUI's frontend on 8080.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cpu;
    # Start conservative — size up once you know this VPS plan's actual
    # RAM/core count (`nproc`, `free -h`).
    loadModels = [ "qwen2.5:7b" ];
    host = "0.0.0.0"; # defaults to 127.0.0.1-only otherwise
  };
  services.open-webui = {
    enable = true;
    # NOT host = ""; despite that being the "bind all interfaces"
    # convention some docs mention — known nixpkgs bug
    # (NixOS/nixpkgs#378188) breaks the generated systemd unit's shell
    # quoting with an empty string. Explicit "0.0.0.0" avoids it.
    host = "0.0.0.0";
    environment = {
      OLLAMA_API_BASE_URL = "http://127.0.0.1:11434/api";
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
    };
  };
  systemd.services.ollama = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
  systemd.services.open-webui = {
    after = [ "network-online.target" "ollama.service" ];
    wants = [ "network-online.target" ];
  };

  # --- n8n (workflow automation) ---------------------------------------
  # Official pre-built Docker image, not the native services.n8n module —
  # that one builds n8n's whole TypeScript monorepo from source, which
  # reliably OOMs on a modest VPS. --network=host (not a port mapping)
  # so it stays genuinely tailnet-only via the firewall above instead of
  # bypassing it through Docker's own NAT.
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.n8n = {
    image = "docker.n8n.io/n8nio/n8n:latest";
    autoStart = true;
    extraOptions = [ "--network=host" ];
    volumes = [ "/var/lib/n8n:/home/node/.n8n" ];
    environment = {
      N8N_PORT = "5678";
      N8N_SECURE_COOKIE = "false"; # n8n expects HTTPS by default; Tailscale's WireGuard already covers the transport layer
      GENERIC_TIMEZONE = "UTC"; # n8n defaults to America/New_York internally otherwise, regardless of
                                 # the host's time.timeZone above — throws off Schedule Trigger cron times
      # Same IPv6 gotcha as Uptime Kuma's NODE_OPTIONS above: this VPS
      # advertises an AAAA route for api.telegram.org (and possibly other
      # hosts) that isn't actually reachable, so Node tries IPv6 first and
      # hangs until ETIMEDOUT instead of falling back to IPv4. Affects any
      # node here that calls out externally (Telegram, HTTP Request, etc).
      NODE_OPTIONS = "--dns-result-order=ipv4first";
      NODES_EXCLUDE = "[]"; # re-enables the Execute Command node (disabled by default since n8n 2.0)
      # Code node's require() allowlist — broad but deliberately
      # excludes child_process and vm, which would recreate the same
      # arbitrary-shell-execution risk the Execute Command gate exists
      # to contain.
      NODE_FUNCTION_ALLOW_BUILTIN = "net,crypto,fs,path,util,querystring,url,os,stream,zlib,dns,http,https,buffer,assert";
    };
  };
  systemd.tmpfiles.rules = [
    # 1000 = the "node" user's UID *inside* the official n8n container —
    # this is a bind mount, not a Docker-managed volume, so there's no
    # UID remapping; root:root here causes a hard EACCES crash-loop.
    "d /var/lib/n8n 0755 1000 1000 -"
    # Uptime Kuma's container runs as root internally, unlike n8n above —
    # root:root here is correct, not a leftover.
    "d /var/lib/uptime-kuma 0755 root root -"
  ];
  systemd.services.docker-n8n = {
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
  };

  # --- Uptime Kuma (status/monitoring dashboard) -----------------------
  # Watches Forgejo/n8n/Ollama/Open WebUI over tailnet HTTP(S)/TCP checks
  # and can hit an n8n webhook on state change, so failures actually
  # surface instead of being noticed days later. --network=host, same
  # reasoning as n8n above: a bridge-mode ports mapping would bypass the
  # firewall's trustedInterfaces and expose it publicly.
  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:1";
    autoStart = true;
    extraOptions = [ "--network=host" ];
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
    environment = {
      UPTIME_KUMA_PORT = "3001"; # 3000 is already Forgejo above
      # This VPS advertises an AAAA route for api.telegram.org that isn't
      # actually reachable (IPv6 egress is broken/half-configured here),
      # so Node tries the IPv6 address first and hangs until ETIMEDOUT
      # instead of falling back to IPv4. Forces IPv4-first resolution so
      # Telegram notifications (and anything else this container calls
      # out to) don't stall on that dead route.
      NODE_OPTIONS = "--dns-result-order=ipv4first";
    };
  };
  systemd.services.docker-uptime-kuma = {
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
  };

  # --- Backups -----------------------------------------------------------
  # Local-only, deliberately staged as step one: this protects against a
  # bad rebuild, an accidental rm, or a corrupted DB, but NOT against the
  # whole disk/VPS dying — that needs an off-box destination (rsync/restic
  # to another host or object storage), which isn't set up here because
  # none has been chosen yet. Revisit once one exists.
  systemd.services.vps-backup = {
    description = "Back up Postgres watchlist DB, n8n data, and Forgejo data";
    after = [ "postgresql.service" "docker-n8n.service" "forgejo.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ config.services.postgresql.package pkgs.gnutar pkgs.gzip pkgs.util-linux ];
    script = ''
      set -eu
      DEST=/var/backups/vps
      STAMP=$(date +%Y-%m-%d)
      mkdir -p "$DEST"

      # runuser, not psql -U postgres directly: pg_dump needs to connect
      # as the "postgres" role, which is peer-auth only (see the
      # authentication block above) - has to actually run as that OS user.
      runuser -u postgres -- pg_dump watchlist | gzip -c > "$DEST/watchlist-$STAMP.sql.gz"
      tar czf "$DEST/n8n-$STAMP.tar.gz" -C /var/lib n8n
      # /var/lib/forgejo is Forgejo's default stateDir - not overridden above.
      tar czf "$DEST/forgejo-$STAMP.tar.gz" -C /var/lib forgejo

      # Keep 14 days of daily backups, drop anything older.
      find "$DEST" -mindepth 1 -mtime +14 -delete
    '';
  };
  systemd.timers.vps-backup = {
    description = "Run vps-backup daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true; # catches up on the next boot if the VPS was off at the scheduled time
    };
  };

  # --- Base packages ------------------------------------------------
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    btop
    ncdu
    jq
    tmux
  ];
}
