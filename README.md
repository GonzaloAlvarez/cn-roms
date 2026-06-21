# cn-roms

[RomM](https://romm.app) — self-hosted ROM library manager — on `kaiser.lan`.
Dual-ingress, like `cn-media`'s jellyfin.

- **LAN URL**: `https://roms.kaiser.lan` (step-ca cert)
- **Tailnet URL**: `https://roms.lab.gn.al` (Let's Encrypt wildcard via VPS traefik-lab)
- **On kaiser**: `/home/gonzalo/cn-roms/`
- **Operated via systemd**: `sudo systemctl restart docker-compose@cn-roms.service` (not direct `docker compose`)

## Architecture

| Service | Role |
|---|---|
| `mount-precheck` | Bails if `/home/gonzalo/docker/data/nfs/roms/library/roms` isn't there. |
| `ts-roms` | Tailscale sidecar; owns the netns. Hostname `roms` (MagicDNS → `roms.ts.gn.al`). `tag:svc`. |
| `romm-db` | MariaDB 11.4. Runs on the project bridge at fixed IP `172.30.0.10` (DNS doesn't work into ts-roms's netns — see comment in `docker-compose.yml`). |
| `romm` | `rommapp/romm:latest`. `network_mode: service:ts-roms`. `/romm/library` + `/romm/assets` on raidnas NFS; `/romm/resources` + `/romm/config` + bundled Redis on local named volumes. |
| `consul-register` | Self-registers `roms` with VPS Consul every 60 s so traefik-lab picks up the route. |
| `promtail` | Ships container logs to VPS Loki at `${INFRA_VPS_TAILNET_IP}:3100`. |
| `node-exporter` | Stack metrics for VPS Prometheus. |
| `ts-roms-watchdog` | Force-recreates dependents when ts-roms restarts (netns drift fix). |
| `watchtower` | Daily image update at 05:00 UTC with `--cleanup`. |

## First-time setup

### 1. Create the NFS subtree on raidnas

```sh
ssh raidnas.lan 'sudo mkdir -p \
  /volume1/data/roms/library/roms \
  /volume1/data/roms/library/bios \
  /volume1/data/roms/assets \
  && sudo chown -R 1000:1000 /volume1/data/roms'
```

Verify from kaiser:

```sh
ssh kaiser.lan 'ls -la /home/gonzalo/docker/data/nfs/roms/library/'
```

### 2. Mint a Tailscale preauth key (24 h, `tag:svc`)

```sh
ssh hs.gn.al 'docker exec cloudnet-headscale-1 \
  headscale preauthkeys create -u 2 --tags tag:svc --expiration 24h'
```

(User ID `2` is `gonzaloab@gmail.com` — confirm with `headscale users list`.)

### 3. Clone + .env on kaiser

```sh
ssh kaiser.lan 'cd ~ && git clone https://github.com/GonzaloAlvarez/cn-roms.git'
ssh kaiser.lan 'cd ~/cn-roms && cp .env.example .env'
# edit ~/cn-roms/.env: fill ROMS_AUTHKEY, ROMM_SECRET, DB_PASSWORD, DB_ROOT_PASSWORD
```

`ROMM_SECRET` should be a 64-char hex string: `openssl rand -hex 32`.

### 4. Run setup

```sh
ssh kaiser.lan 'cd ~/cn-roms && ./setup.sh'
```

Idempotent. Fetches step-ca root CA, checks NFS + roms subtree, installs the
systemd unit, starts the service.

### 5. Wire ingress

- **LAN** (`roms.kaiser.lan` → kaiser): already wired in
  `cn-home/traefik-lan/dynamic.yml.tmpl` + `cn-home/dashy/conf.yml`. Run
  `cn-home/deploy` to apply. `--force-recreate` dashy explicitly (single-file
  bind-mount inode quirk after `git pull`).
- **Tailnet** (`roms.lab.gn.al`): automatic — `consul-register` PUTs the
  service every 60 s; VPS `traefik-lab` picks it up.
- **VPS Glance bookmark + monitor**: wired in
  `cn-root-docker/tailnet/glance/glance.yml`. Restart glance after pulling.

### 6. First-boot admin wizard

RomM doesn't accept admin credentials via env vars — the first user is created
through a web wizard. Open `https://roms.kaiser.lan/` (LAN) or
`https://roms.lab.gn.al/` (tailnet) and complete the setup. The first account
is automatically admin.

### 6b. Authentik SSO via Traefik forward-auth

Both ingresses are gated by Authentik via Traefik's `forwardAuth` middleware
(`authentik-lan` on cn-home, `authentik-lab` on cn-root-docker tailnet). RomM
itself has **no OIDC integration** — Authentik's embedded outpost injects an
`Authorization: Basic <b64(user:pass)>` header on every authenticated request,
which RomM's `HybridAuthBackend` validates against its own user DB
(`/backend/handler/auth/hybrid_auth.py:30-46`).

Trade-off the operator has explicitly accepted: every Authentik user who's
in the `media` or `infra-admins` group lands in RomM as the **same** shared
user. RomM's user model becomes vestigial — one bootstrap admin is enough.

To wire it up:

```sh
# On neptune.lan (Authentik host):
cd ~/cn-authentik
ROMM_SSO_USERNAME=<your romm user> \
ROMM_SSO_PASSWORD=<your romm password> \
  ./setup-romm-proxy-sso.sh
```

This creates two Authentik proxy providers (`roms-lan` with
`external_host=https://roms.kaiser.lan`, `roms-lab` with `https://roms.lab.gn.al`),
two applications, four group→app bindings, and writes `romm_username` +
`romm_password` to the `media` and `infra-admins` group attributes. Re-run
any time to rotate credentials (PATCH-merge, idempotent).

**Rollback**: comment the `- authentik-lan` line on the `roms` router in
`cn-home/traefik-lan/dynamic.yml.tmpl`, drop the `middlewares=authentik-lab@file`
tag from cn-roms's `consul-register` block, force-recreate traefik-lan and
consul-register. RomM falls back to its native login page; the bootstrap
admin still works.

### 7. Argosy on Android

1. Install Tailscale from Google Play; sign in via the headscale flow
   (`https://hs.gn.al/login`).
2. In a desktop browser, open RomM → Profile → **Pair device** → QR code.
3. Install Argosy from
   [github.com/rommapp/argosy-launcher/releases](https://github.com/rommapp/argosy-launcher/releases)
   (no Play Store / F-Droid distribution; consider Obtainium).
4. Open Argosy, scan the QR. Argosy stores the token and talks to
   `https://roms.lab.gn.al` from then on. (Don't try `roms.kaiser.lan` — stock
   Android doesn't trust step-ca.)

## Operations

| Action | Command |
|---|---|
| Restart the stack | `sudo systemctl restart docker-compose@cn-roms.service` |
| Tail RomM logs | `docker logs -f cn-roms-romm-1` |
| MariaDB shell | `docker exec -it cn-roms-romm-db-1 mariadb -uroot -p` (password from `.env`) |
| Force-recreate after config change | `docker compose -p cn-roms up -d --force-recreate --no-deps <svc>` |
| Update RomM image | edit `image:` in `docker-compose.yml`, commit, push; on kaiser `git pull && sudo systemctl restart docker-compose@cn-roms.service` |
| Check tailnet IP | `docker exec cn-roms-ts-roms-1 tailscale ip --4` |

## Library layout

RomM expects (auto-creates platform subdirs as you upload):

```
/home/gonzalo/docker/data/nfs/roms/library/
├── roms/
│   ├── nes/
│   ├── snes/
│   ├── n64/
│   ├── gba/
│   ├── psx/
│   └── ...        # full slug list: https://docs.romm.app/latest/Getting-Started/Folder-Structure/
└── bios/
    ├── psx/
    └── ...
```

Saves and screenshots from in-browser play sessions land in
`/home/gonzalo/docker/data/nfs/roms/assets/`.

## Why romm-db has a fixed IP

`romm` is in `ts-roms`'s netns; tailscaled overwrites `/etc/resolv.conf` to
MagicDNS, so the container can't resolve compose service names (`romm-db`).
`extra_hosts` doesn't work on `network_mode: service:X` either. The cn-root-docker
prometheus.yml hit the same constraint with the headscale scrape and solved it
the same way (pin the IP). Subnet 172.30.0.0/24 declared explicitly under
`networks.default.ipam.config` so the assignment is stable.

## Deferred

- **DB backup.** Add `offen/docker-volume-backup` mirroring `cn-vaultwarden`'s
  block if/when RomM accumulates valuable state.
- **App-level metrics.** RomM has no `/metrics` upstream
  ([backend/main.py](https://github.com/rommapp/romm/blob/master/backend/main.py)).
  Use blackbox_exporter probe of `/api/heartbeat` or watch for a community
  exporter.
- **Image tag pin.** v1 used `:latest` unpinned. Now pinned to a specific
  digest as part of the Authentik forward-auth integration (the auth model
  depends on a stable `HybridAuthBackend`). Bump explicitly after re-verifying
  the Basic-auth path against the new image.
