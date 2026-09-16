# Athena — Debian setup for a Hostinger VPS

One re-runnable bash script (`setup.sh`), sectioned like the old NixOS config was, for a Hostinger VPS running plain Debian. Everything reachable — a self-hosted git server (Forgejo), local AI (Ollama + Open WebUI), n8n, and Uptime Kuma — is locked to your Tailscale tailnet. Edit `setup.sh`, re-run it, and only what actually changed gets touched — the same loop `nixos-rebuild switch` gave us, minus NixOS.

```
Athena-dotfiles/
├── setup.sh                   # the entire provisioning script - install, configure, autostart everything
├── scripts/
│   ├── check-remote.sh        # client-side reachability check (run from your laptop, not the VPS)
│   └── restore-backup.sh      # restores the latest backup output (run on the VPS, as root)
└── workflow/                  # n8n workflow exports — see workflow/readme.md
```

## Deploy
```bash
git clone <your-repo-url> ~/Athena-dotfiles
cd ~/Athena-dotfiles
sudo ./setup.sh
```
On later changes: edit `setup.sh` locally, `git push`, then on the VPS `git pull && sudo ./setup.sh` (re-running the whole thing is safe — see "How re-running works" below). Or run just one section while iterating: `sudo ./setup.sh forgejo`. `sudo ./setup.sh --list` prints all section names.

## How re-running works
Each section in `setup.sh` is idempotent:
- Packages/users/config files: checked before being touched (`dpkg -s`, `id`, `grep -qxF`, etc.) — skipped if already correct.
- Docker containers (n8n, Uptime Kuma, Open WebUI): a hash of the container's desired image+args is stored under `/var/lib/vps-setup/`; the container is only stopped/recreated if that hash changed since the last run, or it isn't currently running. Otherwise the section no-ops.
- Nothing here does a full od "converge from scratch" diff the way Nix does — it's closer to "run each step's own idempotency check," which is weaker but covers everything actually declared in this script.

## First boot
1. **Change the placeholder passwords** in `setup.sh` before this box is actually exposed: `deploy`/`enexolgort`'s default password, Forgejo's admin password, and the `n8n` Postgres role's password. All currently say `changeme*` — search for it, at the top of the file (the "Config" block).
2. **Join your tailnet, matching the machine's hostname:**
   ```bash
   sudo tailscale up --hostname=athena
   ```
   (Tailscale's MagicDNS lowercases device names regardless of the OS hostname's case, hence `athena` here even though the hostname is set to `Athena`.) Note **no `--ssh` flag** — Tailscale SSH bypasses `sshd_config` entirely (including `PermitRootLogin`), so it's deliberately left off; `setup.sh`'s tailscale section also explicitly runs `tailscale set --ssh=false` in case it was ever turned on manually.
3. **Change your login password**: `passwd deploy` and `passwd enexolgort`
4. Both `deploy` and `enexolgort` are regular (non-root) users in the `sudo` group — full `sudo` access, no direct root login. **Root login over SSH is disabled** (`PermitRootLogin no`, set in `/etc/ssh/sshd_config.d/99-local.conf`); always log in as one of these two and `sudo` from there.

## Services (all at `http://<tailscale-ip>:<port>`, tailnet-only)
| Service | Port | Notes |
|---|---|---|
| SSH | 22 | Public + tailnet — see the firewall section in `setup.sh` for the plan to eventually go tailnet-only |
| Forgejo (git server) | 3000 | Admin account created on first run of `section_forgejo` |
| Ollama | 11434 | API only |
| Open WebUI | 8080 | Chat frontend for Ollama |
| n8n | 5678 | Workflow automation |
| Uptime Kuma | 3001 | Status/monitoring dashboard for the other services |
| Postgres | 5432 | localhost-only (backs the n8n watchlist workflows) — not tailnet-reachable |

## Checking everything's actually reachable
Run from **any device on your tailnet**, not the VPS itself:
```bash
./scripts/check-remote.sh --host athena
```

## Backups
A daily systemd timer (`athena-backup.timer`, catches up on next boot via `Persistent=true` if the VPS was off at the scheduled time) runs `/usr/local/bin/athena-backup.sh`, dumping to `/var/backups/athena/`:
- `watchlist-<date>.sql.gz` — `pg_dump` of the Postgres `watchlist` database
- `n8n-<date>.tar.gz` — all of `/var/lib/n8n` (workflows **and** credentials)
- `forgejo-<date>.tar.gz` — all of `/var/lib/forgejo` (repos, SQLite DB, admin account)

Old backups are pruned after 14 days. Run it on demand / check it worked:
```bash
sudo systemctl start athena-backup.service
sudo systemctl status athena-backup.service
ls -la /var/backups/athena/
```

**This is local-only.** It protects against a bad script edit, an accidental `rm`, or a corrupted DB — it does **not** protect against the VPS or its disk dying, since the backups live on that same disk. That needs an off-box destination (rsync/restic to another host, or object storage) that hasn't been set up yet — until then, treat this as a safety net for mistakes, not a real disaster-recovery plan.

**Restoring:** `scripts/restore-backup.sh` (run on the VPS as root) automates this — finds the newest backup file per component and restores it, with a confirmation prompt since it overwrites current data:
```bash
sudo ./scripts/restore-backup.sh              # restores postgres + n8n + forgejo
sudo ./scripts/restore-backup.sh postgres     # just one component
sudo ./scripts/restore-backup.sh -y           # skip the confirmation prompt (scripting only)
```
Postgres restore drops the `to_watch` table before replaying the dump (the dumps aren't taken with `--clean`, so restoring on top of existing data would otherwise collide on duplicate keys / "relation already exists"). n8n restore just `docker stop`/`start`s the container around the tar extraction (it's a normal persistent container, not `--rm`); Forgejo restore stops/starts the systemd service the same way. tar extraction only adds/overwrites files present in the archive — it doesn't remove files created since that backup was taken.

## Notes
- Forgejo's and Postgres's admin/role passwords are plaintext in `setup.sh` — this repo doesn't set up any secrets management, on purpose, to keep things simple. Fine for a single-user tailnet-only box; revisit if that stops being true.
- `setup.sh` assumes Debian (apt, systemd, `useradd`/`usermod`) — this was ported straight from a NixOS config, so double-check anything version-specific (Postgres's config path under `/etc/postgresql/<version>/main/`, Docker's official apt repo setup) still matches whatever Debian release you're actually on.
- Forgejo is installed from a pinned binary release (`FORGEJO_VERSION` at the top of `setup.sh`), not an apt package — Debian doesn't ship one. Bump the version and re-run `sudo ./setup.sh forgejo` to upgrade.
- Firewall is `ufw`; `trustedInterfaces`-style "trust the whole tailnet" is done via `ufw allow in on tailscale0`, matching what NixOS's `trustedInterfaces` gave every 0.0.0.0-bound service for free.
