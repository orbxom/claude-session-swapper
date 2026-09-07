#!/usr/bin/env bash
# test/run.sh — run every *.test.sh in the repo root; exit 1 if any fail.
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
for t in ./*.test.sh; do
  echo "=== $t"
  bash "$t" || rc=1
  echo
done
exit $rc
