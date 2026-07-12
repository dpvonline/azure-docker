#!/usr/bin/env bash
# Nightly full backup, installed as a cron job by cloud-init
# (see scripts/cloud-init.yaml.tftpl). Continuous WAL archiving (archive_command
# in docker-compose.postgres.yml) covers the point-in-time recovery in between.
set -euo pipefail

# COMPOSE_FILE in compose/.env (written by fetch-secrets.sh) already lists all
# three compose files, so no -f flags needed here.
cd /opt/dpv/compose
docker compose exec -T postgres \
  pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf backup --type=full
