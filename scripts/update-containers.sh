#!/usr/bin/env bash
# Weekly automated update run (installed as a systemd timer, see
# scripts/systemd/dpv-update.timer): pulls merged Renovate version bumps,
# rebuilds the compose stack, health-checks it, and rolls back on failure.
#
# No `set -e`: exit codes for the risky steps (pull/build/deploy) are checked
# explicitly so a failure there still reaches the rollback path below, rather
# than aborting the script before rollback can run.
set -uo pipefail

REPO_DIR="/opt/dpv/repo"
COMPOSE_DIR="/opt/dpv/compose"
LOG_FILE="/var/log/dpv-update.log"
HEALTH_TIMEOUT_SECONDS=300
HEALTH_CHECK_INTERVAL=15

log() {
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') $1" | tee -a "$LOG_FILE"
}

rollback() {
  log "rolling back to ${PREV_COMMIT}"
  git -C "$REPO_DIR" reset --hard "$PREV_COMMIT" >>"$LOG_FILE" 2>&1
  cd "$COMPOSE_DIR"
  docker compose up -d --build >>"$LOG_FILE" 2>&1
  log "=== ROLLBACK complete — manual investigation needed, see ${LOG_FILE} ==="
  exit 1
}

cd "$COMPOSE_DIR"
log "=== update run starting ==="

PREV_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
log "current commit: ${PREV_COMMIT}"

log "taking pre-update safety backup..."
if ! docker compose exec -T --user postgres postgres \
    pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf backup --type=full >>"$LOG_FILE" 2>&1; then
  log "ABORT: pre-update backup failed, not touching anything"
  exit 1
fi

log "pulling latest git changes..."
if ! git -C "$REPO_DIR" pull >>"$LOG_FILE" 2>&1; then
  log "ABORT: git pull failed, not touching anything"
  exit 1
fi

NEW_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
if [ "$NEW_COMMIT" = "$PREV_COMMIT" ]; then
  log "no changes since last run, nothing to do"
  exit 0
fi

log "pulling new images..."
if ! docker compose pull >>"$LOG_FILE" 2>&1; then
  rollback
fi

log "recreating containers..."
if ! docker compose up -d --build >>"$LOG_FILE" 2>&1; then
  rollback
fi

log "health-checking (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
healthy=false
elapsed=0
while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
  sleep "$HEALTH_CHECK_INTERVAL"
  elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))

  running_count="$(docker compose ps --status running --services | wc -l)"
  expected_count="$(docker compose config --services | wc -l)"

  keycloak_ok=false
  if docker compose exec -T caddy wget -qO- http://keycloak:9000/health/ready 2>/dev/null | grep -q '"status": "UP"'; then
    keycloak_ok=true
  fi

  postgres_ok=false
  if docker compose exec -T --user postgres postgres pg_isready >/dev/null 2>&1; then
    postgres_ok=true
  fi

  if [ "$running_count" -eq "$expected_count" ] && $keycloak_ok && $postgres_ok; then
    healthy=true
    break
  fi
done

if $healthy; then
  log "=== update succeeded (now at ${NEW_COMMIT}) ==="
  exit 0
fi

log "health check failed after ${HEALTH_TIMEOUT_SECONDS}s"
rollback
