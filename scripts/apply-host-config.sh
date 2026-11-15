#!/usr/bin/env bash
# Brings the host-level configuration kept in this repo (systemd units, drop-ins,
# apt/journald/zram config) to its place under /etc and runs only the steps
# needed to activate what changed.
#
# Why this exists: cloud-init copies these files once, when the VM is created,
# and Terraform ignores custom_data changes on the existing VM. A file added or
# edited in the repo therefore never reached the running host (the weekly update
# does `git pull`, which only helps the compose files). This script closes that
# gap. It is called
#   - by scripts/update-containers.sh after `git pull`, on EVERY run (also on
#     the "no changes since last run" early exit), and
#   - by cloud-init on first boot, instead of individual cp/install lines.
#
# To add a host file: add one sync_file line and its activation below. The list
# is deliberately explicit (no globbing over scripts/systemd): the repo also
# holds files that must not land in /etc.
#
# Properties:
#   - Idempotent: a file is only written when its content differs (cmp), and
#     only the steps belonging to a changed file run. A run on an up-to-date
#     host logs nothing but the final line. File mode is not compared.
#   - Never restarts docker (that would restart every container): the docker
#     drop-in only gets a daemon-reload and applies from the next boot. Never
#     restarts dpv-update.service either, it is usually the caller.
#   - Errors are loud but not fatal: every step is attempted, failures are
#     logged as WARNING and reflected in the exit code (1). The caller only
#     warns, so a broken host config never blocks a container update.
#   - Files deleted from the repo are removed from /etc: every file in the
#     directories below whose name contains "dpv" and that is not in the
#     sync_file list is an orphan (timers are disabled first). The list in this
#     script is the reference, not the repo layout. Only "dpv" names in these
#     directories are ever touched, never anything else in /etc, and
#     dpv-compose.service is exempt (cloud-init renders it). A source file that
#     is missing counts as managed, so a broken checkout deletes nothing.
#   - A rollback in update-containers.sh (git reset --hard) does not revert host
#     files already installed. They do not depend on the containers and the
#     health check does not cover them, so a failed container update says
#     nothing about them. The next run applies whatever the repo holds then.
#     If a host file itself is the culprit, fix it with a new commit.
#
# Not managed here: dpv-compose.service and boot.sh (cloud-init renders them
# with Terraform values) and /etc/cron.d/pgbackrest-full. The latter is written
# by an inline `echo` in cloud-init, so there is no repo file to sync, and its
# content has not changed since it was introduced. Moving it into the repo
# would be a reasonable follow-up, it is just not needed for this change.
#
# DPV_ROOT prefixes every destination path; it exists only so the script can be
# tested against a scratch directory (with systemctl/apt-get stubbed on PATH).

set -uo pipefail

ROOT="${DPV_ROOT:-}"
# -P: /opt/dpv/scripts is a symlink into the repo, resolve it so that the
# source files are found next to this script however it was called.
SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

ZRAM_PACKAGE="systemd-zram-generator"
# Seconds to wait for the dpkg/apt lock: unattended-upgrades holds it at night.
APT_LOCK_TIMEOUT=600

FAILED=0
CHANGED=0
MANAGED=""
NEED_RELOAD=0
DOCKER_DROPIN_CHANGED=0
UPDATE_TIMER_CHANGED=0
PRUNE_TIMER_CHANGED=0
REBOOT_TIMER_CHANGED=0
APT_TIMER_DROPIN_CHANGED=0
JOURNALD_CHANGED=0
ZRAM_CONF_CHANGED=0

log() {
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') apply-host-config: $1"
}

warn() {
  log "WARNING: $1"
  FAILED=1
}

# sync_file SRC DEST — SRC relative to scripts/, DEST absolute on the host.
# Returns 0 only when it wrote the file; unchanged and failed both return 1
# (a failure is recorded via warn), so `sync_file … && FLAG=1` sets the flag
# for real changes only.
sync_file() {
  local src="$SCRIPTS_DIR/$1" dest="$ROOT$2" verb="installed"
  # Recorded first, whatever happens below: see the orphan cleanup.
  MANAGED="$MANAGED$2"$'\n'
  if [ ! -f "$src" ]; then
    warn "source file missing: $src"
    return 1
  fi
  if [ -f "$dest" ]; then
    cmp -s "$src" "$dest" && return 1
    verb="updated"
  fi
  if mkdir -p "$(dirname "$dest")" && install -m 0644 "$src" "$dest"; then
    log "$verb $2"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  warn "could not install $2"
  return 1
}

# activate_timer UNIT CHANGED — start/enable a timer; restart it when its file
# changed, because a daemon-reload alone does not re-arm an active timer with a
# new schedule. Restarting a timer never touches the service it triggers.
activate_timer() {
  local unit="$1" changed="$2"
  if [ "$changed" = 1 ] && systemctl is-active --quiet "$unit"; then
    if systemctl restart "$unit"; then
      log "restarted $unit (file changed)"
    else
      warn "could not restart $unit"
    fi
  fi
  if ! systemctl is-enabled --quiet "$unit" || ! systemctl is-active --quiet "$unit"; then
    if systemctl enable --now "$unit"; then
      log "enabled and started $unit"
    else
      warn "could not enable $unit"
    fi
  fi
}

if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
  log "ERROR: must run as root"
  exit 1
fi

# --- 1. Copy files ------------------------------------------------------------
# source (below scripts/)                          -> destination

# Weekly container update, daily Confluence prune, Sunday reboot after updates.
sync_file systemd/dpv-update.service            /etc/systemd/system/dpv-update.service            && NEED_RELOAD=1
sync_file systemd/dpv-update.timer              /etc/systemd/system/dpv-update.timer              && { NEED_RELOAD=1; UPDATE_TIMER_CHANGED=1; }
sync_file systemd/dpv-confluence-prune.service  /etc/systemd/system/dpv-confluence-prune.service  && NEED_RELOAD=1
sync_file systemd/dpv-confluence-prune.timer    /etc/systemd/system/dpv-confluence-prune.timer    && { NEED_RELOAD=1; PRUNE_TIMER_CHANGED=1; }
sync_file systemd/dpv-reboot-if-required.service /etc/systemd/system/dpv-reboot-if-required.service && NEED_RELOAD=1
sync_file systemd/dpv-reboot-if-required.timer  /etc/systemd/system/dpv-reboot-if-required.timer  && { NEED_RELOAD=1; REBOOT_TIMER_CHANGED=1; }

# Keeps docker from starting while a data disk is missing.
sync_file systemd/docker.service.d/10-dpv-data-mounts.conf /etc/systemd/system/docker.service.d/10-dpv-data-mounts.conf && { NEED_RELOAD=1; DOCKER_DROPIN_CHANGED=1; }

# Schedule of the nightly OS updates.
sync_file systemd/apt-daily-upgrade.timer.d/10-dpv-schedule.conf /etc/systemd/system/apt-daily-upgrade.timer.d/10-dpv-schedule.conf && { NEED_RELOAD=1; APT_TIMER_DROPIN_CHANGED=1; }

# What unattended-upgrades installs. apt reads it on every run: no activation.
sync_file apt/52dpv-unattended-upgrades /etc/apt/apt.conf.d/52dpv-unattended-upgrades

# Journal retention for the container logs.
sync_file journald/10-dpv-retention.conf /etc/systemd/journald.conf.d/10-dpv-retention.conf && JOURNALD_CHANGED=1

# zram swap. Only the generator turns this file into units, so the package must
# be there before the daemon-reload below.
sync_file systemd/zram-generator.conf /etc/systemd/zram-generator.conf && { NEED_RELOAD=1; ZRAM_CONF_CHANGED=1; }

# --- 1b. Remove orphans ---------------------------------------------------------
# Same names the explicit list above uses, found by their "dpv" in the name.
# dpv-compose.service is not from the repo and must stay.
for f in \
  "$ROOT"/etc/systemd/system/dpv-*.service \
  "$ROOT"/etc/systemd/system/dpv-*.timer \
  "$ROOT"/etc/systemd/system/docker.service.d/*dpv*.conf \
  "$ROOT"/etc/systemd/system/apt-daily-upgrade.timer.d/*dpv*.conf \
  "$ROOT"/etc/apt/apt.conf.d/*dpv* \
  "$ROOT"/etc/systemd/journald.conf.d/*dpv*; do
  [ -f "$f" ] || continue
  path="${f#"$ROOT"}"
  [ "$path" = /etc/systemd/system/dpv-compose.service ] && continue
  printf '%s' "$MANAGED" | grep -Fxq -- "$path" && continue
  unit="$(basename "$path")"
  case "$path" in
    /etc/systemd/system/*.timer) systemctl disable --now "$unit" || warn "could not disable $unit" ;;
    /etc/systemd/system/*.service) systemctl disable "$unit" || warn "could not disable $unit" ;;
  esac
  if rm -f "$f"; then
    log "removed $path (no longer in the repo)"
    CHANGED=$((CHANGED + 1))
    NEED_RELOAD=1
    case "$path" in
      /etc/systemd/system/docker.service.d/*) DOCKER_DROPIN_CHANGED=1 ;;
      /etc/systemd/system/apt-daily-upgrade.timer.d/*) APT_TIMER_DROPIN_CHANGED=1 ;;
      /etc/systemd/journald.conf.d/*) JOURNALD_CHANGED=1 ;;
    esac
  else
    warn "could not remove $path"
  fi
done

# --- 2. zram package ----------------------------------------------------------
# cloud-init installs it on first boot; the existing VM got it by hand. Checked
# every run (cheap) so a rebuilt or drifted host repairs itself.
if ! dpkg-query -W -f='${Status}' "$ZRAM_PACKAGE" 2>/dev/null | grep -q '^install ok installed'; then
  log "installing package $ZRAM_PACKAGE"
  if DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" install -y "$ZRAM_PACKAGE"; then
    NEED_RELOAD=1
  else
    warn "could not install $ZRAM_PACKAGE (swap stays off until the next run)"
  fi
fi

# --- 3. Activate --------------------------------------------------------------
if [ "$NEED_RELOAD" = 1 ]; then
  if systemctl daemon-reload; then
    log "daemon-reload done"
  else
    warn "daemon-reload failed"
  fi
fi

[ "$DOCKER_DROPIN_CHANGED" = 1 ] && log "docker drop-in changed: not restarting docker (would restart all containers), applies from the next boot"

activate_timer dpv-update.timer "$UPDATE_TIMER_CHANGED"
activate_timer dpv-confluence-prune.timer "$PRUNE_TIMER_CHANGED"
activate_timer dpv-reboot-if-required.timer "$REBOOT_TIMER_CHANGED"

if [ "$APT_TIMER_DROPIN_CHANGED" = 1 ]; then
  if systemctl restart apt-daily-upgrade.timer; then
    log "restarted apt-daily-upgrade.timer (new schedule)"
  else
    warn "could not restart apt-daily-upgrade.timer"
  fi
fi

if [ "$JOURNALD_CHANGED" = 1 ]; then
  if systemctl restart systemd-journald; then
    log "restarted systemd-journald (new retention)"
  else
    warn "could not restart systemd-journald"
  fi
fi

# `start dev-zram0.swap`, NOT systemd-zram-setup@zram0: the latter only prepares
# the device, the .swap unit requires it and switches the swap on. A live zram
# device is never swapped off here (swapoff under memory pressure is the thing
# it exists to avoid): changed size/algorithm applies from the next boot.
if ! systemctl is-active --quiet dev-zram0.swap; then
  if systemctl start dev-zram0.swap; then
    log "started dev-zram0.swap"
  else
    warn "could not start dev-zram0.swap"
  fi
elif [ "$ZRAM_CONF_CHANGED" = 1 ]; then
  log "zram config changed: the active device keeps its old settings until the next boot"
fi

if [ "$FAILED" = 1 ]; then
  log "finished with warnings, $CHANGED file(s) changed"
  exit 1
fi
log "finished, $CHANGED file(s) changed"
