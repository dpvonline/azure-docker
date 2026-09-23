#!/usr/bin/env bash
# Daily trim of Confluence's scheduled-job history (scripts/systemd/
# dpv-confluence-prune.timer).
#
# Confluence logs every scheduled job run into scheduler_run_details and keeps
# 90 days of it — hardcoded in DefaultSchedulerRunDetailsManager, not
# configurable in 10.2. At ~120,000 runs a day (synchronyStatusCheck alone
# fires every few seconds) that is ~6 GB, almost all of it indexes. The table
# is pure history, shown only as "last run" on the scheduled-jobs admin page,
# and Confluence's own SchedulerRunDetailsPurgeJob deletes old rows the same
# way, just with a longer horizon. Running daily with KEEP_DAYS=7 caps it at
# about a week, a few hundred MB.
set -euo pipefail

KEEP_DAYS=7

cd /opt/dpv/compose

# Nothing to do before Confluence has created its schema (or when its
# database does not exist at all, e.g. right after a fresh cluster init).
if ! docker compose exec -T --user postgres postgres psql -tA -d confluence \
    -c "select to_regclass('public.scheduler_run_details') is not null" </dev/null 2>/dev/null | grep -qx t; then
  echo "no scheduler_run_details table (Confluence not deployed yet), nothing to do"
  exit 0
fi

docker compose exec -T --user postgres postgres psql -v ON_ERROR_STOP=1 -d confluence </dev/null \
  -c "delete from scheduler_run_details where start_time < now() - interval '${KEEP_DAYS} days'" \
  -c "vacuum (analyze) scheduler_run_details"
