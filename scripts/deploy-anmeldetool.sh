#!/usr/bin/env bash
# Rolls out a new Anmeldetool image (github.com/sebivtt/dpv-participant-management).
# Run every few minutes by dpv-anmeldetool-deploy.timer. The app repo's workflow
# pushes ghcr.io/sebivtt/dpv-participant-management:latest after every merge to main
# with green checks; this script notices a new image, pulls it, restarts the tool,
# health-checks it and puts the previous image back if it does not come up.
#
# Pull instead of push because SSH is only open from ADMIN_IP_CIDRS (terraform/network.tf):
# GitHub Actions has no stable address to allow. Nothing here opens a port.
#
# Safe to run when there is nothing to do: without the service in the stack (Key Vault
# secrets missing, see fetch-secrets.sh) or without a newer image it exits 0 quietly.
#
# No `set -e`: the risky steps (pull, up, health check) are checked explicitly so that a
# failure still reaches the rollback.
set -uo pipefail

COMPOSE_DIR="/opt/dpv/compose"
ENV_FILE="$COMPOSE_DIR/anmeldetool.env"
IMAGE="ghcr.io/sebivtt/dpv-participant-management:latest"
SERVICES=(anmeldetool anmeldetool-aufraeumen)
STATE_DIR="/var/lib/dpv"
# Image ID of the last image that did not become healthy. As long as the registry still
# serves that very image, nothing is retried (otherwise: restart + rollback every 5 minutes).
FAILED_FILE="$STATE_DIR/anmeldetool-failed-image"
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

container_id() { docker compose ps -q anmeldetool 2>/dev/null | head -n1; }

# Role and database for the tool in the shared Postgres. init-db.sql only runs on an
# empty cluster, so on the existing one this is what creates them. Idempotent; also
# keeps the role's password in line with Key Vault. The password travels as an
# environment variable (inherited by `docker compose exec`, `-e APP_PW` without a
# value), so it appears in no command line, neither here nor in the container.
ensure_database() {
  local db user pw
  db="$(sed -n 's/^POSTGRES_DB=//p' "$ENV_FILE")"
  user="$(sed -n 's/^POSTGRES_USER=//p' "$ENV_FILE")"
  pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ENV_FILE")"
  if ! [[ "$db" =~ ^[a-z_]+$ && "$user" =~ ^[a-z_]+$ && -n "$pw" ]]; then
    log "ABORT: POSTGRES_DB/USER/PASSWORD in $ENV_FILE missing or malformed"
    return 1
  fi
  APP_PW="$pw" docker compose exec -T -e APP_PW --user postgres postgres \
    psql -X -q -v ON_ERROR_STOP=1 -v "db=$db" -v "usr=$user" >>"$LOG_FILE" 2>&1 <<'SQL'
\set pw `printenv APP_PW`
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'usr', :'pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'usr') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'usr', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' TEMPLATE template0', :'db', :'usr')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SQL
}

wait_healthy() {
  local elapsed=0 cid status
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    sleep "$HEALTH_CHECK_INTERVAL"
    elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
    cid="$(container_id)"
    [ -n "$cid" ] || continue
    status="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
  done
  return 1
}

PREV_ID=""
if cid="$(container_id)" && [ -n "$cid" ]; then
  PREV_ID="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
fi

if ! docker compose pull --quiet anmeldetool >>"$LOG_FILE" 2>&1; then
  # Registry or network trouble, most often temporary. Only worth a line, not a failed unit.
  log "pull failed, trying again at the next run"
  exit 0
fi

NEW_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
if [ -z "$NEW_ID" ]; then
  log "ABORT: image $IMAGE not found after pull"
  exit 1
fi

if [ "$NEW_ID" = "$PREV_ID" ]; then
  # Already running this image. Still make sure the whole service set is up (a first
  # install, or the cleanup service lost after a manual `docker compose down`).
  if [ -n "$(docker compose ps --status running -q anmeldetool-aufraeumen)" ]; then
    exit 0
  fi
elif [ -f "$FAILED_FILE" ] && [ "$(cat "$FAILED_FILE")" = "$NEW_ID" ]; then
  # The pull just moved the local `latest` tag back to the blocked image. A reboot
  # starts whatever `latest` is, so point it at the image that is actually running.
  [ -n "$PREV_ID" ] && docker tag "$PREV_ID" "$IMAGE" >>"$LOG_FILE" 2>&1
  exit 0
fi

log "=== deploy starting: ${PREV_ID:-none} -> $NEW_ID ==="

ensure_database || exit 1

# The app runs `migrate` on start (docker/start.sh) and a rollback does not undo
# migrations, so an update over a running version gets a safety backup first, like the
# weekly run. Incremental: seconds, not the full backup of the weekly run. If it fails,
# nothing is touched.
if [ -n "$PREV_ID" ] && [ "$NEW_ID" != "$PREV_ID" ]; then
  log "taking pre-deploy backup (incremental)..."
  if ! docker compose exec -T --user postgres postgres \
      pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf backup --type=incr >>"$LOG_FILE" 2>&1; then
    log "ABORT: pre-deploy backup failed, not touching anything"
    exit 1
  fi
  # Keeps the old image from being pruned while we may still need it.
  docker tag "$PREV_ID" dpv-anmeldetool-previous:latest >>"$LOG_FILE" 2>&1 || true
fi

log "starting containers..."
if docker compose up -d "${SERVICES[@]}" >>"$LOG_FILE" 2>&1 && wait_healthy; then
  rm -f "$FAILED_FILE"
  # Only dangling images (older versions of this image that lost their tag).
  docker image prune -f >>"$LOG_FILE" 2>&1 || true
  log "=== deploy succeeded ($NEW_ID) ==="
  exit 0
fi

log "new image did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s"
echo "$NEW_ID" > "$FAILED_FILE"
log "last lines of the tool log:"
docker compose logs --no-color --tail 20 anmeldetool 2>&1 | tee -a "$LOG_FILE" >/dev/null

if [ -n "$PREV_ID" ] && docker image inspect "$PREV_ID" >/dev/null 2>&1; then
  log "rolling back to $PREV_ID (database migrations are NOT undone)"
  # `latest` is also what a reboot or the weekly update would start.
  docker tag "$PREV_ID" "$IMAGE" >>"$LOG_FILE" 2>&1
  if docker compose up -d --force-recreate "${SERVICES[@]}" >>"$LOG_FILE" 2>&1; then
    log "=== ROLLBACK complete, image $NEW_ID stays blocked until a newer one is published. Manual investigation needed, see ${LOG_FILE} ==="
  else
    log "=== ROLLBACK FAILED: manual intervention needed ==="
  fi
else
  # First install: nothing to go back to. Stopped rather than restart-looping.
  docker compose stop "${SERVICES[@]}" >>"$LOG_FILE" 2>&1
  log "=== first deploy failed, tool stopped. Manual investigation needed, see ${LOG_FILE} ==="
fi
exit 1
