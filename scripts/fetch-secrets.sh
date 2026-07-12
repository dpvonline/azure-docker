#!/usr/bin/env bash
# Pulls runtime secrets from Key Vault via the VM's managed identity and
# writes compose/.env + compose/init-db.sql. Run at boot (cloud-init) and
# again by a systemd unit on every subsequent boot/reboot, so nothing is
# ever hand-entered or persisted outside Key Vault.
set -euo pipefail

VAULT_NAME="$1"
DOMAIN_AUTH="$2"
LETSENCRYPT_EMAIL="$3"
COMPOSE_DIR="/opt/dpv/compose"

az login --identity --allow-no-subscriptions >/dev/null

get_secret() {
  az keyvault secret show --vault-name "${VAULT_NAME}" --name "$1" --query value -o tsv
}

POSTGRES_SUPERUSER_PASSWORD="$(get_secret postgres-superuser-password)"
POSTGRES_KEYCLOAK_PASSWORD="$(get_secret postgres-keycloak-password)"
KEYCLOAK_ADMIN_PASSWORD="$(get_secret keycloak-admin-password)"

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

# Only ever read by Postgres on first init of an empty data directory.
sed "s/__POSTGRES_KEYCLOAK_PASSWORD__/${POSTGRES_KEYCLOAK_PASSWORD}/" \
  "${COMPOSE_DIR}/init-db.sql.template" > "${COMPOSE_DIR}/init-db.sql"
chown root:root "${COMPOSE_DIR}/init-db.sql"
chmod 600 "${COMPOSE_DIR}/init-db.sql"
