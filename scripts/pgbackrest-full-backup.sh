#!/usr/bin/env bash
# Nightly full backup, installed as a cron job by cloud-init
# (see scripts/cloud-init.yaml.tftpl). Continuous WAL archiving (archive_command
# in docker-compose.postgres.yml) covers the point-in-time recovery in between.
#
# A failure here is reported to syslog, which the monitoring alert watches.
# This is also the early warning for broken WAL archiving: a full backup waits
# for its final WAL segment to be archived and fails if that never happens.
# Broken archiving is dangerous precisely because it is quiet — Postgres keeps
# every unarchived segment, and with archive_timeout=600 that grows by ~2 GB a
# day until the disk is full (hit in a real deploy, see MIGRATION.md).
set -euo pipefail

trap 'logger -p user.err -t dpv-backup "pgbackrest full backup FAILED (exit $?) — WAL archiving may be broken too, see /var/log/pgbackrest-full.log"' ERR

# COMPOSE_FILE in compose/.env (written by fetch-secrets.sh) already lists all
# three compose files, so no -f flags needed here.
cd /opt/dpv/compose
docker compose exec -T --user postgres postgres \
  pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf backup --type=full
