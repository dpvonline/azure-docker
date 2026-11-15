#!/bin/bash
# Runs on the VM, as root: snapshots Nextcloud group memberships and compares or
# restores them. user_oidc syncs groups from the Keycloak "roles" claim on every
# login and removes everything else — except "admin" (whitelist regex), which is
# maintained locally. The group folders hang on these groups, so take a snapshot
# before touching roles, client mappers or the user_oidc provider in Keycloak.
#
#   nc-groups.sh snapshot              group memberships, quota, email, display name
#   nc-groups.sh diff [snapshot-dir]   memberships now vs snapshot (default: latest)
#   nc-groups.sh restore [dir] --apply put memberships back as in the snapshot
#
# Up to 15.11.2026 this was nc-sso.sh, which also switched between oidc_login
# and user_oidc (MIGRATION.md, Phase 4). Snapshots live in /root/nc-groups/.
set -euo pipefail
cd /opt/dpv/compose
O() { docker compose exec -T --user www-data nextcloud php occ "$@" </dev/null; }
P() { docker compose exec -T --user postgres postgres psql -d nextcloud -v ON_ERROR_STOP=1 -At "$@" </dev/null; }
# comm needs byte order; Postgres sorts by the database collation.
csort() { LC_ALL=C sort; }
SNAPROOT=/root/nc-groups
latest() { ls -1d "$SNAPROOT"/snapshot-* 2>/dev/null | tail -1; }

snapshot() {
  local d="$SNAPROOT/snapshot-$(date -u +%Y%m%dT%H%M%SZ)"; install -d -m 700 "$d"
  P -c "copy (select gid, uid from oc_group_user) to stdout" | csort > "$d/group_user.tsv"
  P -c "copy (select gid, displayname from oc_groups) to stdout" | csort > "$d/groups.tsv"
  P -c "copy (select userid, appid, configkey, configvalue from oc_preferences where (appid='files' and configkey='quota') or (appid='settings' and configkey='email')) to stdout" | csort > "$d/preferences.tsv"
  P -c "copy (select uid, displayname from oc_users) to stdout" | csort > "$d/users.tsv"
  echo "snapshot: $d ($(wc -l < "$d/group_user.tsv") Mitgliedschaften, $(wc -l < "$d/groups.tsv") Gruppen)"
}

diffsnap() {
  local d="${1:-$(latest)}"
  [ -n "$d" ] || { echo "keine Momentaufnahme in $SNAPROOT" >&2; exit 1; }
  P -c "copy (select gid, uid from oc_group_user) to stdout" | csort > /tmp/group_user.now
  csort < "$d/group_user.tsv" > /tmp/group_user.snap
  echo "verglichen mit $d"
  echo "-- seitdem entfernt (gid, uid):"; LC_ALL=C comm -23 /tmp/group_user.snap /tmp/group_user.now | tee /tmp/group_user.removed | head -50
  echo "-- seitdem hinzugekommen (gid, uid):"; LC_ALL=C comm -13 /tmp/group_user.snap /tmp/group_user.now | tee /tmp/group_user.added | head -50
  echo "-- neue Gruppen:"; P -c "copy (select gid from oc_groups) to stdout" | csort | LC_ALL=C comm -13 <(cut -f1 "$d/groups.tsv" | csort) - | head -20
  echo "summe: $(wc -l < /tmp/group_user.removed) entfernt, $(wc -l < /tmp/group_user.added) hinzugekommen"
}

case "${1:-}" in
  snapshot) snapshot ;;
  diff) diffsnap "${2:-}" ;;
  restore)
    d="${2:-$(latest)}"; diffsnap "$d" >/dev/null
    [ "${3:-}" = "--apply" ] || { diffsnap "$d"; echo "Trockenlauf — mit --apply ausführen"; exit 0; }
    while IFS=$'\t' read -r g u; do O group:adduser "$g" "$u"; done < /tmp/group_user.removed
    while IFS=$'\t' read -r g u; do O group:removeuser "$g" "$u"; done < /tmp/group_user.added
    diffsnap "$d" | tail -1 ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
