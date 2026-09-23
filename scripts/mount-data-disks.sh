#!/usr/bin/env bash
# Formats (first time only), registers in fstab and mounts the three data
# disks under /data, addressed by LUN (assigned in terraform/vm.tf). Called by
# boot.sh on EVERY start of dpv-compose.service, not just on first boot.
#
# Why this lives here and not in cloud-init: it used to run exactly once, in
# cloud-init, with a 60 s wait per disk. When the Postgres disk was replaced by
# terraform it was attached after that window closed, the mount was silently
# skipped, and nothing ever retried. Docker then created the bind-mount source
# directory on the OS disk and Postgres ran there until the OS disk filled up
# (hit in a real deploy, see MIGRATION.md). Running on every start means a
# late-attached disk is picked up on the next service restart, and the final
# check below refuses to start the stack at all if any disk is missing.
#
# Idempotent: an existing filesystem is never reformatted, an existing fstab
# entry is never duplicated, a mounted disk is left alone.
set -euo pipefail

# How long to wait for each device to appear. Generous on purpose — a disk
# that terraform attaches after the VM has booted can take minutes.
WAIT_SECONDS=300

declare -A DISKS=(
  [0]=/data/postgres
  [1]=/data/apps
  [2]=/data/nextcloud
)

fail() {
  echo "ERROR: $1" >&2
  logger -p user.err -t dpv-boot "$1"
  exit 1
}

find_device() {
  local lun="$1" waited=0 candidate
  # Retry loop outside, candidates inside: the exact path differs by storage
  # controller, and waiting out the full timeout on one name before trying
  # the next would delay every boot by minutes.
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    for candidate in "/dev/disk/azure/scsi1/lun$lun" "/dev/disk/azure/scsi0/lun$lun" "/dev/disk/azure/data/by-lun/$lun"; do
      if [ -e "$candidate" ]; then
        echo "$candidate"
        return 0
      fi
    done
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

for lun in "${!DISKS[@]}"; do
  mount_point="${DISKS[$lun]}"

  if mountpoint -q "$mount_point"; then
    continue
  fi

  dev="$(find_device "$lun")" \
    || fail "no data disk for LUN $lun (${mount_point}) appeared within ${WAIT_SECONDS}s — lsblk: $(lsblk -dno NAME,SIZE | tr '\n' ' ')"

  if ! blkid "$dev" >/dev/null 2>&1; then
    mkfs.ext4 -q -F "$dev"
  fi

  mkdir -p "$mount_point"
  if ! grep -q " ${mount_point} " /etc/fstab; then
    echo "$dev $mount_point ext4 defaults,nofail 0 2" >> /etc/fstab
    systemctl daemon-reload
  fi
  mount "$mount_point"
done

# The actual safety net. Everything above can go wrong in ways nobody sees
# (fstab has `nofail`, so a missing disk never blocks boot); this check turns
# "silently running on the OS disk" into "stack does not start and an error
# lands in syslog", which the monitoring alert picks up.
for mount_point in "${DISKS[@]}"; do
  mountpoint -q "$mount_point" || fail "${mount_point} is not a mountpoint — refusing to start the stack on the OS disk"
done

# 999 is the postgres user inside the container. Only the mount root: the
# data directory underneath is created and owned by the postgres entrypoint,
# and a recursive chown on every boot would be slow for no benefit. The other
# two disks get their ownership when the applications using them arrive.
chown 999:999 /data/postgres
