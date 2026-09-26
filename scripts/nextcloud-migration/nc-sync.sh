#!/bin/bash
# Runs on LIGHTSAIL, as root: copies Nextcloud to vm-dpv-core (MIGRATION.md,
# Phase 3 and 4). Every run after the first only transfers the delta.
#
#   nc-sync.sh initial   first copy, config/config.php included
#   nc-sync.sh delta     refresh before the cutover, config/config.php left alone
#                        — the VM's copy carries the test-copy settings
#                        (Phase 3, step 4) and must not get production values back
#   nc-sync.sh cutover   final run inside the window, config/config.php included
#                        on purpose: it brings the production settings along
#
# Previews are not copied (20 GB, regenerated on demand); the conversion removes
# their database entries afterwards (nc-convert.sh). Log: append with
#   nc-sync.sh <mode> 2>&1 | tee -a /root/nc-sync.log
#
# Needs /root/.ssh/dpv-migration_ed25519 (authorised on the VM for dpvadmin,
# from="3.65.3.213" only) and /root/.ssh/known_hosts.vm with the VM's verified
# host key. Measured on 25.09.2026: 167 GB in 4 h 56 min, ~9.4 MB/s — EFS
# bursting throughput, not the network, is the limit.
set -uo pipefail
MODE="${1:?usage: nc-sync.sh initial|delta|cutover}"
case "$MODE" in initial|delta|cutover) ;; *) echo "unknown mode: $MODE" >&2; exit 2 ;; esac

VM=dpvadmin@4.182.232.115
SSH="ssh -i /root/.ssh/dpv-migration_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/root/.ssh/known_hosts.vm -o StrictHostKeyChecking=yes -o ServerAliveInterval=30"
RSYNC=(rsync -aH --numeric-ids --delete --partial --info=stats2 -e "$SSH" --rsync-path="sudo rsync")
log() { echo "$(date -u +%FT%TZ) $*"; }

APP_EXCLUDE=()
# Excluded paths are also protected from --delete, so the VM keeps its file.
[ "$MODE" = delta ] && APP_EXCLUDE=(--exclude=/config/config.php)

log "=== [$MODE] app: /data/nextcloud/data/ -> /data/apps/nextcloud/"
"${RSYNC[@]}" "${APP_EXCLUDE[@]}" /data/nextcloud/data/ "$VM:/data/apps/nextcloud/"
rc_app=$?; log "app exit=$rc_app"

log "=== [$MODE] user data: /data/nextcloud/user_data/ -> /data/nextcloud/"
"${RSYNC[@]}" --exclude=/lost+found --exclude=/nextcloud.log \
  --exclude='/appdata_*/preview/' --exclude='/*/uploads/' --exclude='/*/cache/' \
  /data/nextcloud/user_data/ "$VM:/data/nextcloud/"
rc_data=$?; log "user data exit=$rc_data"

log "=== fertig"
# 24 = files vanished during the transfer: normal while Lightsail is live
# (initial/delta), must not happen in the cutover, where writes are stopped.
ok() { [ "$1" -eq 0 ] || { [ "$1" -eq 24 ] && [ "$MODE" != cutover ]; }; }
ok $rc_app && ok $rc_data
