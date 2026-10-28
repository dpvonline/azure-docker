#!/bin/bash
# Runs on the VM, as root: switches Nextcloud SSO between oidc_login (the
# community app used up to 28.10.2026) and user_oidc (Nextcloud's own app, in
# use since), both against Keycloak client "nextcloud". Provider settings for
# user_oidc: MIGRATION.md, Phase 4.
#
#   nc-sso.sh status
#   nc-sso.sh snapshot              group memberships, quota, email, display name
#   nc-sso.sh to-user-oidc          (takes a snapshot first)
#   nc-sso.sh to-oidc-login         back to oidc_login
#   nc-sso.sh diff [snapshot-dir]   memberships now vs snapshot (default: latest)
#   nc-sso.sh restore [dir] --apply put memberships back as in the snapshot
#
# Both apps leave existing accounts as ordinary Nextcloud users, so switching
# back and forth does not touch accounts, files or app passwords. What can
# change on a login is group membership: user_oidc syncs it from the "roles"
# claim and removes everything else — except "admin" (whitelist regex), which
# is maintained locally. Snapshots live in /root/sso/.
set -euo pipefail
cd /opt/dpv/compose
O() { docker compose exec -T --user www-data nextcloud php occ "$@" </dev/null; }
P() { docker compose exec -T --user postgres postgres psql -d nextcloud -v ON_ERROR_STOP=1 -At "$@" </dev/null; }
SNAPROOT=/root/sso
latest() { ls -1d "$SNAPROOT"/snapshot-* 2>/dev/null | tail -1; }

snapshot() {
  local d="$SNAPROOT/snapshot-$(date -u +%Y%m%dT%H%M%SZ)"; install -d -m 700 "$d"
  P -c "copy (select gid, uid from oc_group_user order by 1,2) to stdout" > "$d/group_user.tsv"
  P -c "copy (select gid, displayname from oc_groups order by 1) to stdout" > "$d/groups.tsv"
  P -c "copy (select userid, appid, configkey, configvalue from oc_preferences where (appid='files' and configkey='quota') or (appid='settings' and configkey='email') order by 1,2,3) to stdout" > "$d/preferences.tsv"
  P -c "copy (select uid, displayname from oc_users order by 1) to stdout" > "$d/users.tsv"
  echo "snapshot: $d ($(wc -l < "$d/group_user.tsv") Mitgliedschaften, $(wc -l < "$d/groups.tsv") Gruppen)"
}

status() {
  for a in oidc_login user_oidc; do echo "$a: $(O app:list --output=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('aktiv' if '$a' in d['enabled'] else ('installiert, aus' if '$a' in d['disabled'] else 'nicht installiert'))")"; done
  echo "user_oidc allow_multiple_user_backends: $(O config:app:get user_oidc allow_multiple_user_backends 2>/dev/null || echo '(nicht gesetzt = 1)')"
  echo "letzte Momentaufnahme: $(latest)"
}

diffsnap() {
  local d="${1:-$(latest)}"
  P -c "copy (select gid, uid from oc_group_user order by 1,2) to stdout" > /tmp/group_user.now
  echo "verglichen mit $d"
  echo "-- seitdem entfernt (gid, uid):"; comm -23 "$d/group_user.tsv" /tmp/group_user.now | tee /tmp/group_user.removed | head -50
  echo "-- seitdem hinzugekommen (gid, uid):"; comm -13 "$d/group_user.tsv" /tmp/group_user.now | tee /tmp/group_user.added | head -50
  echo "-- neue Gruppen:"; P -c "copy (select gid from oc_groups order by 1) to stdout" | comm -13 <(cut -f1 "$d/groups.tsv") - | head -20
  echo "summe: $(wc -l < /tmp/group_user.removed) entfernt, $(wc -l < /tmp/group_user.added) hinzugekommen"
}

case "${1:-}" in
  status) status ;;
  snapshot) snapshot ;;
  to-user-oidc)
    snapshot
    O app:enable user_oidc
    O config:app:set user_oidc allow_multiple_user_backends --value=0   # redirect /login straight to Keycloak
    O app:disable oidc_login
    status ;;
  to-oidc-login)
    O app:enable oidc_login
    O app:disable user_oidc
    status ;;
  diff) diffsnap "${2:-}" ;;
  restore)
    d="${2:-$(latest)}"; diffsnap "$d" >/dev/null
    [ "${3:-}" = "--apply" ] || { diffsnap "$d"; echo "Trockenlauf — mit --apply ausführen"; exit 0; }
    while IFS=$'\t' read -r g u; do O group:adduser "$g" "$u"; done < /tmp/group_user.removed
    while IFS=$'\t' read -r g u; do O group:removeuser "$g" "$u"; done < /tmp/group_user.added
    diffsnap "$d" | tail -1 ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
