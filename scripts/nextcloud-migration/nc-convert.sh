#!/bin/bash
# Runs on the VM, as root: converts Nextcloud from the temporary MariaDB
# (container nextcloud-mariadb, network alias "db") to Postgres (MIGRATION.md,
# Phase 3, step 5). Repeatable: --clear-schema empties the target first.
#
#   nc-convert.sh              test copy — ends with maintenance mode off
#   KEEP_MAINTENANCE=1 nc-convert.sh   cutover — stays in maintenance mode
#
# Log: nc-convert.sh 2>&1 | tee -a /root/nc-convert.log (run it in tmux).
#
# Why it does more than `occ db:convert-type`: on Nextcloud 33 that command
# copies every row and then fails in PgSqlTools::resynchronizeDatabaseSequences().
# Four sequences (oc_jobs, oc_previews, oc_preview_locations, oc_preview_versions)
# are left over from before those tables switched to Snowflake IDs and no longer
# belong to any column, which the code does not expect (still so in master,
# 25.09.2026). The two steps it never reaches — resynchronising the remaining
# sequences and saving the database settings — are done here instead, the same
# way. It also drops `dbport`, which convert-type would have left at 3306.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd /opt/dpv/compose
O() { docker compose exec -T --user www-data nextcloud php occ "$@" </dev/null; }
P() { docker compose exec -T --user postgres postgres psql -d nextcloud -v ON_ERROR_STOP=1 -At "$@" </dev/null; }
PGPW="$(grep ^POSTGRES_NEXTCLOUD_PASSWORD= .env | cut -d= -f2)"
log() { echo "$(date -u +%FT%TZ) $*"; }
die() { log "ABBRUCH: $*"; exit 1; }

[ "$(O config:system:get dbtype)" = mysql ] || die "config.php zeigt nicht auf MariaDB — schon konvertiert?"
docker start nextcloud-mariadb >/dev/null

log "=== maintenance on"; O maintenance:mode --on
log "=== db:convert-type"; start=$(date +%s)
O db:convert-type --no-interaction --all-apps --clear-schema --password="$PGPW" pgsql nextcloud postgres nextcloud \
  > /root/nc-convert-type.out 2>&1
rc=$?; log "convert-type exit=$rc, $(( $(date +%s)-start ))s (Ausgabe: /root/nc-convert-type.out)"
if [ $rc -ne 0 ] && ! grep -q "SELECT setval(" /root/nc-convert-type.out; then
  die "anderer Fehler als der bekannte Sequenz-Fehler, siehe /root/nc-convert-type.out"
fi
# convert-type switches maintenance off again when it fails.
O maintenance:mode --on

log "=== Zeilen vergleichen"
"$HERE/nc-compare.sh" | tee /root/nc-compare.out
grep -q "^Abweichungen: keine außer oc_migrations$" /root/nc-compare.out || die "Zeilenzahlen weichen ab, siehe /root/nc-compare.out"

if [ "$(O config:system:get dbtype)" != pgsql ]; then
  log "=== Sequenzen"
  P -c "
  do \$\$
  declare r record; n int := 0; skipped text := '';
  begin
    for r in select s.sequencename, c.table_name, c.column_name
               from pg_sequences s
               left join information_schema.columns c
                 on c.column_default = 'nextval(''' || s.sequencename || '''::regclass)'
                and c.table_catalog = current_database()
              where s.schemaname = 'public' and s.sequencename like 'oc\_%'
    loop
      if r.table_name is null then
        skipped := skipped || ' ' || r.sequencename;
      else
        execute format('select setval(%L, (select max(%I) from %I))', r.sequencename, r.column_name, r.table_name);
        n := n + 1;
      end if;
    end loop;
    raise notice 'resynchronized % sequences, skipped:%', n, skipped;
  end \$\$;" || die "Sequenzen"

  log "=== config.php auf Postgres"
  cp -p /data/apps/nextcloud/config/config.php "/root/config.php.before-pgsql.$(date +%s)"
  # One write for all values: after dbtype alone, every further occ call
  # would already try Postgres on the old host and fail.
  docker compose exec -T -e PGPW="$PGPW" --user www-data nextcloud php -f /dev/stdin < "$HERE/nc-dbconfig.php" || die "config.php"
fi
for k in dbtype dbhost dbname dbuser; do log "$k=$(O config:system:get $k)"; done
[ -z "$(O config:system:get dbport)" ] || die "dbport ist noch gesetzt"

log "=== Nacharbeiten"
docker stop nextcloud-mariadb >/dev/null   # proves Nextcloud no longer needs it
O db:add-missing-indices; O db:add-missing-columns; O db:add-missing-primary-keys
# Previews are not copied (nc-sync.sh), but their rows are — without this,
# Nextcloud tries to serve files that are not there instead of regenerating them.
O preview:cleanup --no-interaction
O maintenance:repair --include-expensive

if [ "${KEEP_MAINTENANCE:-0}" = 1 ]; then
  log "=== Wartungsmodus bleibt an (Cutover)"
else
  log "=== maintenance off"; O maintenance:mode --off
fi
O status
log "=== fertig"
