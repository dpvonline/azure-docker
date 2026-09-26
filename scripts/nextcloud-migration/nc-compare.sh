#!/bin/bash
# Runs on the VM, as root: exact row counts per table, MariaDB copy vs Postgres,
# one query per database. Called by nc-convert.sh.
#
# Expected (25.09.2026): only oc_migrations differs — convert-type fills it by
# running the migrations instead of copying it, and 25 old entries belong to
# migrations no longer in the code. Tables only in MariaDB are leftovers of
# removed apps (announcements, old app_api, oc_file_metadata).
cd /opt/dpv/compose
M() { docker exec -i nextcloud-mariadb sh -c 'mariadb -N -unextcloud -p"$MARIADB_PASSWORD" nextcloud' 2>/dev/null; }
P() { docker compose exec -T --user postgres postgres psql -d nextcloud -At; }

echo "select table_name from information_schema.tables where table_schema='nextcloud'" | M | sort > /tmp/m.tables
echo "select tablename from pg_tables where schemaname='public'" | P | sort > /tmp/p.tables
echo "nur in MariaDB: $(comm -23 /tmp/m.tables /tmp/p.tables | tr '\n' ' ')"
echo "nur in Postgres: $(comm -13 /tmp/m.tables /tmp/p.tables | tr '\n' ' ')"

q=$(for t in $(comm -12 /tmp/m.tables /tmp/p.tables); do printf "select '%s', count(*) from %s union all " "$t" "$t"; done)
q="${q% union all }"
echo "$q" | M | tr '\t' '|' | sort > /tmp/m.counts
echo "$q" | P | sort > /tmp/p.counts
echo "$(wc -l < /tmp/p.counts) gemeinsame Tabellen gezählt"
d=$(diff /tmp/m.counts /tmp/p.counts | grep '^[<>]' | grep -v '^[<>] oc_migrations|')
if [ -z "$d" ]; then
  echo "Abweichungen: keine außer oc_migrations"
else
  echo "Abweichungen:"; echo "$d"
fi
