#!/bin/bash
# Read-only, one-shot diagnostics. Usage: ./scripts/diagnose_wake.sh > ~/clamopen-wake.txt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
printf '\n=== Captured at ===\n'
date
sw_vers
uname -m
printf '\n=== Running ClamOpen processes ===\n'
pgrep -fl 'ClamOpen|ClamRestore' || true
printf '\n=== Power profiles (read-only) ===\n'
/usr/bin/pmset -g custom
printf '\n=== Recent actual sleep/wake events ===\n'
/usr/bin/pmset -g log | awk '$4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake" || $4 == "Failure" || $4 == "HibernateStats"' | tail -60
printf '\n=== Current display state and API availability (read-only) ===\n'
if command -v swift >/dev/null 2>&1; then
    swift "$ROOT/scripts/probe.swift" || echo 'Display probe failed (Swift command-line tools may be unavailable).'
else
    echo 'Swift unavailable; display probe skipped.'
fi
printf '\n=== Recovery request files (existence/metadata only) ===\n'
ls -l "$HOME/Library/Application Support/ClamOpen/" 2>/dev/null || true
printf '\n=== ClamOpen recovery log, last hour ===\n'
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "com.clamopen.app" AND category == "DisplayRecovery"' || true
