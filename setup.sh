#!/usr/bin/env bash
# cn-roms — host setup on kaiser.lan. Idempotent: safe to re-run.
#
#   1. sanity check (hostname=kaiser)
#   2. fetch step-ca root CA → ./certs/
#   3. NFS sanity (refuse if /home/gonzalo/docker/data/nfs isn't mounted)
#   4. roms subtree sanity (refuse if /roms/library/roms is missing — mkdir
#      it on raidnas first per README §1)
#   5. install /etc/systemd/system/docker-compose@cn-roms.service + reload
#   6. enable + start the service
#   7. print status

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NFS_MOUNTPOINT="/home/gonzalo/docker/data/nfs"
ROMS_SUBTREE="$NFS_MOUNTPOINT/roms/library/roms"

if [ "$(hostname -s)" != "kaiser" ]; then
  echo "ERROR: must run on kaiser.lan (hostname is '$(hostname -s)')" >&2
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo (systemd install). You may be prompted."
fi

# ── 1. step-ca root CA ───────────────────────────────────────────────────
if [ ! -f "$REPO_DIR/certs/root_ca.crt" ]; then
  mkdir -p "$REPO_DIR/certs"
  echo "[1/6] fetching step-ca root CA"
  curl -sfo "$REPO_DIR/certs/root_ca.crt" http://pki.lan/cert/ca.crt
else
  echo "[1/6] step-ca root CA already in place"
fi

# ── 2. NFS sanity ────────────────────────────────────────────────────────
if ! mountpoint -q "$NFS_MOUNTPOINT"; then
  echo "ERROR: $NFS_MOUNTPOINT not mounted — cn-roms needs the raidnas NFS share" >&2
  echo "       fix the mount first (see cn-bittorrent/setup.sh §1-2)" >&2
  exit 1
fi
echo "[2/6] NFS mounted: $(mount | grep raidnas | head -1)"

# ── 3. roms subtree sanity ───────────────────────────────────────────────
if [ ! -d "$ROMS_SUBTREE" ]; then
  echo "ERROR: $ROMS_SUBTREE missing — create it on raidnas first:" >&2
  echo "       ssh raidnas.lan 'sudo mkdir -p /volume1/data/roms/library/roms" >&2
  echo "         /volume1/data/roms/library/bios /volume1/data/roms/assets" >&2
  echo "         && sudo chown -R 1000:1000 /volume1/data/roms'" >&2
  exit 1
fi
echo "[3/6] roms subtree present: $ROMS_SUBTREE"

# ── 4. systemd unit ──────────────────────────────────────────────────────
UNIT_SRC="$REPO_DIR/systemd/docker-compose@cn-roms.service"
UNIT_DST="/etc/systemd/system/docker-compose@cn-roms.service"
if [ ! -f "$UNIT_DST" ] || ! sudo cmp -s "$UNIT_SRC" "$UNIT_DST"; then
  echo "[4/6] installing $UNIT_DST"
  sudo cp "$UNIT_SRC" "$UNIT_DST"
  sudo systemctl daemon-reload
else
  echo "[4/6] systemd unit already in place"
fi

# ── 5. enable + start ────────────────────────────────────────────────────
echo "[5/6] enabling + starting docker-compose@cn-roms"
sudo systemctl enable --now docker-compose@cn-roms.service

# ── 6. status ────────────────────────────────────────────────────────────
echo "[6/6] status:"
sudo systemctl status docker-compose@cn-roms.service --no-pager -l | head -15
echo
docker compose -p cn-roms ps

echo
echo "Done. First-boot: open https://roms.kaiser.lan (LAN) or"
echo "      https://roms.lab.gn.al (tailnet) to complete the admin wizard."
