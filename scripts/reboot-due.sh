#!/usr/bin/env bash
# ExecCondition of dpv-reboot-if-required.service: decides whether this
# Sunday's reboot happens (exit 0) or waits (exit 1 — systemd then skips the
# unit without marking it failed). Runs from the repo checkout, so changes here
# need no VM rebuild.
#
# With Livepatch (Ubuntu 26.04 on ARM64, see MIGRATION.md "Ubuntu 26.04 für
# Livepatch") a pending kernel update no longer needs a reboot every week:
# Livepatch has already fixed the high and critical issues in the running
# kernel. Ubuntu Pro reports exactly that case as
# "yes-kernel-livepatches-applied": only kernel packages are waiting, and
# Livepatch both covers and has patched the running kernel. That reboot waits
# for the first Sunday of the month, which also keeps the running kernel inside
# Livepatch's 9-13 month patch window and picks up the medium and low kernel
# fixes Livepatch leaves out.
#
# Everything else reboots this Sunday, as before: "yes" (some other package
# asked for the reboot, or Livepatch does not cover the kernel — off, not
# attached, n/a on 24.04 ARM64, kernel too old), and any answer this script
# cannot read.
set -uo pipefail

# date +%d is zero-padded; [ ] compares in base 10, so "08" is 8.
if [ "$(date -u +%d)" -le 7 ]; then
  echo "First Sunday of the month, rebooting"
  exit 0
fi

status=$(pro api u.pro.security.status.reboot_required.v1 2>/dev/null \
  | jq -r '.data.attributes.reboot_required // empty' 2>/dev/null)

if [ "$status" = "yes-kernel-livepatches-applied" ]; then
  echo "Only kernel updates pending and Livepatch has patched the running kernel, reboot waits for the first Sunday of the month"
  exit 1
fi

echo "Rebooting, Ubuntu Pro says: ${status:-no answer}"
exit 0
