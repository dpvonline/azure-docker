#!/usr/bin/env bash
# Placeholder for a later increment: weekly `docker compose pull` +
# health-check + automatic rollback if a service doesn't come back healthy.
# Deliberately not implemented yet — image tags in compose/*.yml are pinned
# (never :latest) so this can be added without changing the deploy model.
set -euo pipefail
echo "update-containers.sh: not implemented yet — see README / plan for the intended design." >&2
exit 1
