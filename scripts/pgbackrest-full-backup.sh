#!/usr/bin/env bash
# Nightly full backup, installed as a cron job by cloud-init
# (see scripts/cloud-init.yaml.tftpl). Continuous WAL archiving (archive_command
# in docker-compose.postgres.yml) covers the point-in-time recovery in between.
set -euo pipefail

cd /opt/dpv/compose
docker compose \
  -f docker-compose.yml -f docker-compose.postgres.yml -f docker-compose.keycloak.yml \
  exec -T postgres \
  pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf backup --type=full
