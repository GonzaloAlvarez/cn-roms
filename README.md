# cn-roms

[RomM](https://romm.app) — self-hosted ROM library manager — on `kaiser.lan`.
**One canonical URL**, reachable from both networks (same shape as `cn-librechat`):

- **Canonical**: `https://roms.lab.gn.al` — tailnet: LE wildcard via VPS traefik-lab;
  LAN: split-horizon DNS (Technitium `cn-dnsdhcpd/dns/records.tsv` + pfSense
  `cn-home` `LAN_HOSTS`) → kaiser traefik-lan, step-ca leaf.
- **Alias**: `https://roms.kaiser.lan` → **301** to the canonical URL (cn-home
  `roms-canonical` middleware). It cannot be a second origin: RomM's OIDC
  redirect URI is static, the OAuth state lives in a host-scoped cookie, and the
  Argosy pairing QR is built from `window.location.origin`.
- **On kaiser**: `/home/gonzalo/cn-roms/`
- **Operated via systemd**: `sudo systemctl restart docker-compose@cn-roms.service` (not direct `docker compose`)

## Architecture

| Service | Role |
|---|---|
| `mount-precheck` | Bails if `/home/gonzalo/docker/data/nfs/roms/library/roms` isn't there. |
| `ts-roms` | Tailscale sidecar; owns the netns. Hostname `roms` (MagicDNS → `roms.ts.gn.al`). `tag:svc`. |
| `romm-db` | MariaDB 11.4. Runs on the project bridge at fixed IP `172.30.0.10` (DNS doesn't work into ts-roms's netns — see comment in `docker-compose.yml`). |
| `romm` | `rommapp/romm:5.3.1` (explicit tag, watchtower-excluded — see *Upgrading*). `network_mode: service:ts-roms`. `/romm/library` + `/romm/assets` on raidnas NFS; `/romm/resources` + `/romm/config` + bundled Redis on local named volumes. |
| `consul-register` | Self-registers `roms` with VPS Consul every 60 s so traefik-lab picks up the route. |
| `promtail` | Ships container logs to VPS Loki at `${INFRA_VPS_TAILNET_IP}:3100`. |
| `node-exporter` | Stack metrics for VPS Prometheus. |
| `ts-roms-watchdog` | Force-recreates dependents when ts-roms restarts (netns drift fix). |

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
ssh kaiser.lan 'cd ~/cn-roms && kauket get kaiser.cn_roms_env'   # installs .env (0600)
```

`.env` is **Kauket-managed** (`kaiser.cn_roms_env`; keys documented in
`.env.example`). To change a value: edit a copy on the Mac, `kauket add
kaiser.cn_roms_env <file> --dest /home/gonzalo/cn-roms/.env --mode 0600 --force`,
then `kauket get` on kaiser and force-recreate `romm`. `ROMM_SECRET` is a
64-char hex string (`openssl rand -hex 32`) — never rotate it casually, it
invalidates every session and Client API Token pairing in flight.

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
through a web wizard. Open `https://roms.lab.gn.al/` and complete the setup.
The first account is automatically admin — it is also the **break-glass local
admin** once OIDC is on (see §6b); give it the same email as your Authentik
user so the first OIDC login links to it instead of creating a duplicate.

### 6b. Authentik SSO via native OIDC

RomM speaks OIDC natively (since 3.7). The Authentik side is provisioned by
`cn-authentik/setup-roms-oidc.sh` (idempotent — provider + application `roms`,
ONE strict redirect `https://roms.lab.gn.al/api/oauth/openid`, custom scope
mappings `roms-email` / `roms-groups`, bindings for `media` + `infra-admins`):

```sh
ssh neptune.lan 'cd ~/cn-authentik && ./setup-roms-oidc.sh'   # prints OIDC_CLIENT_ID/SECRET
# on the Mac: add them to the Kauket env (kaiser.cn_roms_env), then on kaiser:
kauket get kaiser.cn_roms_env && docker compose -p cn-roms up -d --force-recreate --no-deps romm
```

RomM-side settings live in `docker-compose.yml` (`ROMM_BASE_URL`, `OIDC_*`);
only the client id/secret come from `.env`. Roles come from the Authentik
`groups` claim on **every** login: `infra-admins` → ADMIN, `media` → USER
(`OIDC_ROLE_VIEWER`; RomM 5.x has only those two roles — USER's permission
group covers saves/states/devices, which is what Argosy needs). Anyone
outside those groups is refused by Authentik before reaching RomM. New
people: `cn-authentik/setup-user.sh --groups media`; their RomM account is
auto-created on first login (`OIDC_ALLOW_REGISTRATION=true`).

**Account linking is by email.** An existing local user with the same email
as the Authentik identity is linked; otherwise RomM creates a second account.

**Why not the Traefik forward-auth gate any more:** Authentik's proxy provider
(`forward_single` + Basic injection) intercepted every non-browser request,
so Argosy's `Authorization: Bearer rmm_…` calls got an Authentik HTML page
instead of JSON, and every person landed as the same shared RomM user. With
native OIDC Authentik only sees browsers; RomM validates Client API Tokens
itself and each person has their own saves and devices.

**Break-glass / rollback** (all via the Kauket env + `up -d --force-recreate
--no-deps romm`):

| Situation | Do |
|---|---|
| OIDC broken, need in | `OIDC_ENABLED=false` → login page shows local user/password only |
| Locked out with `DISABLE_USERPASS_LOGIN=true` | set it to `false`, recreate `romm`, log in as the local admin `gonzalo` |
| Back to forward-auth entirely | not supported any more — `setup-romm-proxy-sso.sh` was retired; see git history |

### 7. Argosy on Android (phones, handhelds, TV boxes)

Argosy authenticates with a per-user **RomM Client API Token**, paired by
device-managed registration (RomM ≥ 5.0). Authentik is not involved.

1. Install Tailscale from Google Play; sign in via the headscale flow
   (`https://hs.gn.al/login`). **Keep it on** — `roms.lab.gn.al` must
   resolve to the tailnet ingress (LE cert). On home Wi-Fi *without*
   Tailscale the name resolves to kaiser's **step-ca** leaf, which stock
   Android rejects (RomM is not on a public CA on the LAN side — a
   Cloudflare DNS-01 resolver on traefik-lan would lift that; deliberately
   not done).
2. Install Argosy from
   [github.com/rommapp/argosy-launcher/releases](https://github.com/rommapp/argosy-launcher/releases)
   (no Play Store / F-Droid; consider Obtainium).
3. In Argosy: Settings → RomM → server `https://roms.lab.gn.al`. It shows a QR
   code / short code.
4. In a browser signed in to RomM **as the person who owns the device**
   (via "Login with Authentik" at `https://roms.lab.gn.al`), approve the
   device. Argosy stores the token and syncs library, saves and states.
5. Tokens are per user per device: review/revoke under Settings → Client API
   Tokens (up to 25 per user; revoke all before disabling a user).

Pair only from the canonical URL — the QR encodes the page origin.

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

## Upgrading

`romm` is on an explicit tag and excluded from kaiser's host-wide watchtower
(`com.centurylinklabs.watchtower.enable=false`) on purpose: RomM minors have
shipped config-affecting changes (5.3.0: `filesystem.structure` in
`config.yml`, content-hash ROM identity). Alembic migrations are one-way, so:

1. Dump the DB first (the only rollback):
   ```sh
   docker exec cn-roms-romm-db-1 sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" \
     --single-transaction --routines --triggers romm' | gzip > ~/romm-db-$(date +%F).sql.gz
   ```
2. Read the release notes between the current and target tag; re-check
   `config/config.yml` against `config/config.yml.example`.
3. Bump `image:` in `docker-compose.yml`, commit, push; on kaiser
   `git pull && ./setup.sh && sudo systemctl restart docker-compose@cn-roms.service`
   and watch `docker logs -f cn-roms-romm-1` until migrations finish.
4. Kick a library scan off-hours if the release changed ROM identity/hashing.

Rollback: revert the commit, `docker compose -p cn-roms stop romm`, drop +
recreate the `romm` database, import the dump, restart the unit.

## Deferred

- **DB backup.** Add `offen/docker-volume-backup` mirroring `cn-vaultwarden`'s
  block if/when RomM accumulates valuable state.
- **App-level metrics.** RomM has no `/metrics` upstream
  ([backend/main.py](https://github.com/rommapp/romm/blob/master/backend/main.py)).
  Use blackbox_exporter probe of `/api/heartbeat` or watch for a community
  exporter.
- **DB backup automation.** A manual `mariadb-dump` recipe lives under
  *Upgrading*; automate it (offen) if RomM state keeps growing.
