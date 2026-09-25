#!/usr/bin/env bash
# Compares the LIVE Firestore ruleset with the local firestore.rules. Read-only.
#
# Why: on 2026-09-25 a device pass reported "User unavailable" never appearing.
# The code was correct; the live rules were three days stale (commit 01ff2b5)
# and rejected every write of the new field. No test can see a stale deploy —
# run this before any device test that depends on rules.
#
# Needs `gcloud auth login` with access to the project. Exit 0 = identical.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="${1:-time-app-1e1c9}"
TOKEN="$(gcloud auth print-access-token)"
API="https://firebaserules.googleapis.com/v1"
HDR=(-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT")

RELEASE="$(curl -fsS "${HDR[@]}" "$API/projects/$PROJECT/releases/cloud.firestore")"
RULESET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["rulesetName"])' <<<"$RELEASE")"
LIVE="$(mktemp)"
trap 'rm -f "$LIVE"' EXIT
curl -fsS "${HDR[@]}" "$API/$RULESET" |
  python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["source"]["files"][0]["content"])' >"$LIVE"

echo "Live ruleset: $RULESET"
if diff -q "$LIVE" firestore.rules >/dev/null; then
  echo "OK — live rules match firestore.rules byte-for-byte."
  exit 0
fi

echo "STALE — live rules differ from firestore.rules."
for commit in $(git log --format=%h -- firestore.rules); do
  if git show "$commit:firestore.rules" | diff -q - "$LIVE" >/dev/null; then
    echo "Live rules match commit $commit ($(git log -1 --format='%ad %s' --date=short "$commit"))."
    break
  fi
done
echo "Deploy with: firebase deploy --only firestore:rules,firestore:indexes"
exit 1
