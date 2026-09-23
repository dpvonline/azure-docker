#!/usr/bin/env bash
# Pulls runtime secrets/config from Key Vault via the VM's managed identity
# and writes compose/.env + compose/init-db.sql. Run at boot (cloud-init) and
# again by a systemd unit on every subsequent boot/reboot, so nothing is
# ever hand-entered or persisted outside Key Vault.
#
# DOMAIN_AUTH/LETSENCRYPT_EMAIL live in Key Vault too (not passed as args)
# specifically so changing them is just `terraform apply` (updates the
# secret) + `systemctl restart dpv-compose.service` on the VM — no VM
# replacement, since nothing here is baked into custom_data.
set -euo pipefail

VAULT_NAME="$1"
COMPOSE_DIR="/opt/dpv/compose"

az login --identity --allow-no-subscriptions >/dev/null

get_secret() {
  az keyvault secret show --vault-name "${VAULT_NAME}" --name "$1" --query value -o tsv
}

DOMAIN_AUTH="$(get_secret domain-auth)"
LETSENCRYPT_EMAIL="$(get_secret letsencrypt-email)"
POSTGRES_SUPERUSER_PASSWORD="$(get_secret postgres-superuser-password)"
POSTGRES_KEYCLOAK_PASSWORD="$(get_secret postgres-keycloak-password)"
KEYCLOAK_ADMIN_PASSWORD="$(get_secret keycloak-admin-password)"
# Fetched even though Confluence and Nextcloud aren't deployed yet: init-db.sql
# below creates their databases during the cluster's one and only
# initialization, so the passwords must exist by then (see MIGRATION.md).
POSTGRES_CONFLUENCE_PASSWORD="$(get_secret postgres-confluence-password)"
POSTGRES_NEXTCLOUD_PASSWORD="$(get_secret postgres-nextcloud-password)"

umask 077

cat > "${COMPOSE_DIR}/.env" <<EOF
COMPOSE_FILE=docker-compose.yml:docker-compose.postgres.yml:docker-compose.keycloak.yml
DOMAIN_AUTH=${DOMAIN_AUTH}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}
POSTGRES_KEYCLOAK_PASSWORD=${POSTGRES_KEYCLOAK_PASSWORD}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
EOF
chown root:root "${COMPOSE_DIR}/.env"
chmod 600 "${COMPOSE_DIR}/.env"

# Only ever read by Postgres on first init of an empty data directory. Bind-
# mounted INTO the postgres container and executed there by the non-root
# "postgres" user — 600/root:root (like .env) would make it unreadable to
# that user and silently skip the CREATE USER statement, which is exactly
# what caused Keycloak's "role does not exist" errors on a real deploy.
#
# The passwords are generated with `special = false` (see keyvault.tf), so they
# are alphanumeric and can't contain the sed delimiter or otherwise break the
# substitution.
sed -e "s/__POSTGRES_KEYCLOAK_PASSWORD__/${POSTGRES_KEYCLOAK_PASSWORD}/" \
    -e "s/__POSTGRES_CONFLUENCE_PASSWORD__/${POSTGRES_CONFLUENCE_PASSWORD}/" \
    -e "s/__POSTGRES_NEXTCLOUD_PASSWORD__/${POSTGRES_NEXTCLOUD_PASSWORD}/" \
  "${COMPOSE_DIR}/init-db.sql.template" > "${COMPOSE_DIR}/init-db.sql"
chown root:root "${COMPOSE_DIR}/init-db.sql"
chmod 644 "${COMPOSE_DIR}/init-db.sql"
