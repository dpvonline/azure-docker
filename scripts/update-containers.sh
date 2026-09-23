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
# How much Confluence scheduler history to keep, see the prune step below.
SCHEDULER_HISTORY_DAYS=7

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

# Confluence logs every scheduled job run into scheduler_run_details and keeps
# 90 days of it — hardcoded in DefaultSchedulerRunDetailsManager, not
# configurable in 10.2. At ~120,000 runs a day (synchronyStatusCheck alone
# fires every few seconds) that is ~6 GB, almost all of it indexes. The table
# is pure history, shown only as "last run" on the scheduled-jobs admin page,
# and Confluence's own SchedulerRunDetailsPurgeJob deletes old rows the same
# way, just with a longer horizon. Doing it here weekly keeps at most
# 7 + 7 days, well under 1 GB. Deliberately before the "nothing changed" exit
# below so it runs every week, and non-fatal: a failure here must not block
# an update. Skipped if Confluence hasn't created the table (yet).
log "pruning Confluence scheduler history older than ${SCHEDULER_HISTORY_DAYS} days..."
if docker compose exec -T --user postgres postgres psql -tAc \
    "select to_regclass('public.scheduler_run_details') is not null" -d confluence </dev/null 2>/dev/null | grep -qx t; then
  if docker compose exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -d confluence </dev/null >>"$LOG_FILE" 2>&1 \
      -c "delete from scheduler_run_details where start_time < now() - interval '${SCHEDULER_HISTORY_DAYS} days'" \
      -c "vacuum (analyze) scheduler_run_details"; then
    log "scheduler history pruned"
  else
    log "WARN: pruning scheduler history failed, continuing with the update"
  fi
else
  log "no scheduler_run_details table (Confluence not deployed yet), skipping"
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
# --ignore-buildable: postgres has both `build:` and `image:` (locally built,
# no registry counterpart) — without this flag, `pull` always fails trying to
# fetch it, triggering a spurious rollback on every run regardless of whether
# postgres actually changed.
if ! docker compose pull --ignore-buildable >>"$LOG_FILE" 2>&1; then
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
