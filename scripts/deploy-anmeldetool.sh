#!/usr/bin/env bash
# Rolls out a new Anmeldetool version (github.com/sebivtt/dpv-participant-management).
# Run every few minutes by dpv-anmeldetool-deploy.timer. The app repo's workflow pushes
# ghcr.io/sebivtt/dpv-participant-management:<YYYY.MM.DD-run> after every merge to main
# with green checks, plus `latest` as a pointer to the newest one. This script reads the
# version out of `latest`, pulls that exact tag, restarts the tool on it, health-checks it
# and goes back to the previous version if it does not come up.
#
# Pull instead of push because SSH is only open from ADMIN_IP_CIDRS (terraform/network.tf):
# GitHub Actions has no stable address to allow. Nothing here opens a port.
#
# What runs where: role and database are created by the one-shot service
# anmeldetool-db-init, migrations by the tool itself on start, both in
# compose/docker-compose.anmeldetool.yml. This script only decides WHICH version runs.
#
# Safe to run when there is nothing to do: without the service in the stack (Key Vault
# secrets missing, see fetch-secrets.sh) or without a newer version it exits 0 quietly.
#
# No `set -e`: the risky steps (pull, up, health check) are checked explicitly so that a
# failure still reaches the rollback.
set -uo pipefail

COMPOSE_DIR="/opt/dpv/compose"
REPO="ghcr.io/sebivtt/dpv-participant-management"
SERVICES=(anmeldetool anmeldetool-aufraeumen)
STATE_DIR="/var/lib/dpv"
# The version that runs (and that fetch-secrets.sh writes back into .env after a reboot).
VERSION_FILE="$STATE_DIR/anmeldetool-version"
# Last version that did not become healthy. As long as `latest` still is that version,
# nothing is retried (otherwise: restart + rollback every 5 minutes).
FAILED_FILE="$STATE_DIR/anmeldetool-failed-version"
LOG_FILE="/var/log/dpv-update.log"
HEALTH_TIMEOUT_SECONDS=240
HEALTH_CHECK_INTERVAL=5

log() {
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') anmeldetool-deploy: $1" | tee -a "$LOG_FILE"
}

cd "$COMPOSE_DIR" || exit 1

# One run at a time (a slow health check must not overlap with the next timer tick).
exec 9>/run/dpv-anmeldetool-deploy.lock
flock -n 9 || exit 0

# The weekly update run recreates containers and takes a backup; stay out of its way.
if systemctl is-active --quiet dpv-update.service; then
  exit 0
fi

# Not part of the stack (yet): nothing to deploy.
if ! docker compose config --services 2>/dev/null | grep -qx anmeldetool; then
  exit 0
fi

mkdir -p "$STATE_DIR"

CURRENT=""
[ -f "$VERSION_FILE" ] && CURRENT="$(cat "$VERSION_FILE")"

# Compose reads ANMELDETOOL_VERSION from .env, which is what a reboot or the weekly update
# use. It is only changed after a successful rollout, so a failed one never sticks.
set_env_version() {
  if grep -q '^ANMELDETOOL_VERSION=' .env; then
    sed -i "s/^ANMELDETOOL_VERSION=.*/ANMELDETOOL_VERSION=$1/" .env
  else
    echo "ANMELDETOOL_VERSION=$1" >> .env
  fi
  echo "$1" > "$VERSION_FILE"
}

wait_healthy() {
  local elapsed=0 cid status
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    sleep "$HEALTH_CHECK_INTERVAL"
    elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
    cid="$(docker compose ps -q anmeldetool 2>/dev/null | head -n1)"
    [ -n "$cid" ] || continue
    status="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
  done
  return 1
}

# Which version is `latest`? Its image carries it as the OCI label.
if ! docker pull --quiet "$REPO:latest" >>"$LOG_FILE" 2>&1; then
  # Registry or network trouble, most often temporary. Only worth a line, not a failed unit.
  log "pull of $REPO:latest failed, trying again at the next run"
  exit 0
fi
NEW="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$REPO:latest" 2>/dev/null || true)"
if ! [[ "$NEW" =~ ^[0-9A-Za-z._-]+$ ]]; then
  log "ABORT: image $REPO:latest has no usable org.opencontainers.image.version label (got '${NEW}')"
  exit 1
fi

if [ "$NEW" = "$CURRENT" ]; then
  # Already on this version. Still make sure the whole service set is up (a first
  # install, or a service lost after a manual `docker compose down`).
  if [ -n "$(docker compose ps --status running -q anmeldetool-aufraeumen)" ]; then
    exit 0
  fi
elif [ -f "$FAILED_FILE" ] && [ "$(cat "$FAILED_FILE")" = "$NEW" ]; then
  exit 0
fi

# Pull the exact version; this is the tag Compose starts.
if ! docker pull --quiet "$REPO:$NEW" >>"$LOG_FILE" 2>&1; then
  log "pull of $REPO:$NEW failed, trying again at the next run"
  exit 0
fi

log "=== deploy starting: ${CURRENT:-none} -> $NEW ==="

# The tool runs `migrate` on start and a rollback does not undo migrations, so an update
# over a running version gets a safety backup first, like the weekly run. Incremental:
# seconds, not the full backup of the weekly run. If it fails, nothing is touched.
if [ -n "$CURRENT" ] && [ "$NEW" != "$CURRENT" ]; then
  log "taking pre-deploy backup (incremental)..."
  if ! docker compose exec -T --user postgres postgres \
      pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf backup --type=incr >>"$LOG_FILE" 2>&1; then
    log "ABORT: pre-deploy backup failed, not touching anything"
    exit 1
  fi
fi

log "starting containers on $NEW..."
if ANMELDETOOL_VERSION="$NEW" docker compose up -d "${SERVICES[@]}" >>"$LOG_FILE" 2>&1 && wait_healthy; then
  set_env_version "$NEW"
  rm -f "$FAILED_FILE"
  # Older versions of this image stay as tagged images until the weekly `image prune -af`
  # in update-containers.sh; only untagged leftovers go now.
  docker image prune -f >>"$LOG_FILE" 2>&1 || true
  log "=== deploy succeeded ($NEW) ==="
  exit 0
fi

log "version $NEW did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s"
echo "$NEW" > "$FAILED_FILE"
log "last lines of the tool log:"
docker compose logs --no-color --tail 20 anmeldetool 2>&1 | tee -a "$LOG_FILE" >/dev/null

if [ -n "$CURRENT" ]; then
  log "rolling back to $CURRENT (database migrations are NOT undone)"
  # The old tag is pulled again if the weekly prune removed it; tags are never overwritten.
  docker pull --quiet "$REPO:$CURRENT" >>"$LOG_FILE" 2>&1 || true
  if ANMELDETOOL_VERSION="$CURRENT" docker compose up -d --force-recreate "${SERVICES[@]}" >>"$LOG_FILE" 2>&1; then
    log "=== ROLLBACK complete, $NEW stays blocked until a newer version is published. Manual investigation needed, see ${LOG_FILE} ==="
  else
    log "=== ROLLBACK FAILED: manual intervention needed ==="
  fi
else
  # First install: nothing to go back to. Stopped rather than restart-looping.
  docker compose stop "${SERVICES[@]}" >>"$LOG_FILE" 2>&1
  log "=== first deploy failed, tool stopped. Manual investigation needed, see ${LOG_FILE} ==="
fi
exit 1
