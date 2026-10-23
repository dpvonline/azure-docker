#!/bin/bash
# Runs on LIGHTSAIL, as root: streams a MariaDB dump of Nextcloud straight into
# the temporary nextcloud-mariadb container on vm-dpv-core (MIGRATION.md,
# Phase 3, step 3). Recreates the target database first, so it can be repeated
# — in the cutover this is the fresh dump taken after the write stop.
# Measured on 25.09.2026: 17 s for 458 MB.
set -euo pipefail
SSH="ssh -i /root/.ssh/dpv-migration_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/root/.ssh/known_hosts.vm -o StrictHostKeyChecking=yes"
VM=dpvadmin@4.182.232.115
start=$(date +%s)

$SSH $VM 'sudo docker start nextcloud-mariadb >/dev/null
for i in $(seq 1 30); do
  sudo docker exec nextcloud-mariadb sh -c "mariadb -unextcloud -p\"\$MARIADB_PASSWORD\" -e \"select 1\"" >/dev/null 2>&1 && break
  sleep 2
done
sudo docker exec nextcloud-mariadb sh -c "mariadb -unextcloud -p\"\$MARIADB_PASSWORD\" -e \"drop database if exists nextcloud; create database nextcloud\""'

docker exec nextcloud_db sh -c 'mysqldump --single-transaction --default-character-set=utf8mb4 -unextcloud -p"$MYSQL_PASSWORD" nextcloud' \
  | gzip \
  | $SSH $VM 'gunzip | sudo docker exec -i nextcloud-mariadb sh -c "mariadb -unextcloud -p\"\$MARIADB_PASSWORD\" nextcloud"'

echo "dump+import ok, $(( $(date +%s)-start ))s"
# Same four numbers on both sides = complete (Phase 3: 201 / 263 / 52066 / 20).
Q="select count(*) from information_schema.tables where table_schema='nextcloud'; select count(*) from oc_users; select count(*) from oc_filecache; select count(*) from oc_group_folders;"
echo "lightsail: $(echo "$Q" | docker exec -i nextcloud_db sh -c 'mysql -N -unextcloud -p"$MYSQL_PASSWORD" nextcloud' 2>/dev/null | tr '\n' ' ')"
echo "vm:        $(echo "$Q" | $SSH $VM 'sudo docker exec -i nextcloud-mariadb sh -c "mariadb -N -unextcloud -p\"\$MARIADB_PASSWORD\" nextcloud"' 2>/dev/null | tr '\n' ' ')"
