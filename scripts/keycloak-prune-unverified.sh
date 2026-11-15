#!/usr/bin/env bash
# Delete Keycloak users in realm DPV whose email address was never verified
# and whose account is older than MIN_AGE_HOURS (scripts/systemd/
# dpv-keycloak-prune.timer). Targets bot self-registrations that never click
# the confirmation link.
#
# Goes through the admin API (kcadm) so Keycloak's caches and events stay
# consistent; never touches the keycloak database directly.
#
# Dry run by default. Pass --delete to actually delete.
# Unverified accounts of any age are deleted. Set SINCE_EPOCH_MS to restrict
# the sweep to accounts created after a cutoff (default: none).
set -euo pipefail

REALM="${REALM:-DPV}"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-48}"
SINCE_EPOCH_MS="${SINCE_EPOCH_MS:-0}"
MAX_DELETIONS="${MAX_DELETIONS:-500}"   # safety stop if something looks off
DELETE=false
[ "${1:-}" = "--delete" ] && DELETE=true

cd /opt/dpv/compose
kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@" </dev/null; }

# Log in as the service account of the realm client "keycloak-prune" (role
# manage-users in realm-management). Its secret comes from Key Vault via
# fetch-secrets.sh -> .env. The bootstrap admin is not usable here: the
# migrated database carries its own admin password.
SECRET=$(grep '^KEYCLOAK_PRUNE_CLIENT_SECRET=' .env | cut -d= -f2-)
if [ -z "$SECRET" ]; then
  echo "KEYCLOAK_PRUNE_CLIENT_SECRET missing in .env (Key Vault secret keycloak-prune-client-secret, then rerun fetch-secrets.sh)" >&2
  exit 1
fi
docker compose exec -T -e KC_SECRET="$SECRET" keycloak bash -c \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
     --realm '"$REALM"' --client keycloak-prune --secret "$KC_SECRET"' </dev/null >/dev/null

cutoff_ms=$(( ($(date +%s) - MIN_AGE_HOURS * 3600) * 1000 ))

# CSV lines: id,createdTimestamp
ids=$(kc get users -r "$REALM" -q emailVerified=false -q max=100000 \
        --fields id,createdTimestamp --format csv --noquotes \
      | tr -d '\r' \
      | awk -F, -v c="$cutoff_ms" -v s="$SINCE_EPOCH_MS" \
          '$2 ~ /^[0-9]+$/ && $2 < c && $2 >= s {print $1}')

count=$(printf '%s' "$ids" | grep -c . || true)
echo "unverified users older than ${MIN_AGE_HOURS}h in realm ${REALM}: ${count}"

if [ "$count" -gt "$MAX_DELETIONS" ]; then
  echo "more than MAX_DELETIONS=${MAX_DELETIONS}, refusing — review manually" >&2
  exit 1
fi
if [ "$DELETE" != true ]; then
  echo "dry run, pass --delete to remove them"
  exit 0
fi

for id in $ids; do
  kc delete "users/${id}" -r "$REALM"
done
echo "deleted ${count}"
