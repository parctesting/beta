#!/usr/bin/env bash
# Publish this site to PRODUCTION (parcradio.org).
#
#   PARC_PASSCODE=... ./tools/sync-production.sh          # build + verify only
#   PARC_PASSCODE=... ./tools/sync-production.sh --push   # also push a branch
#
# The deployment chain is:
#   this repo  -> parcradio.net  (beta,       parctesting/beta)
#              -> parcradio.org  (production, parctesting/parctesting.github.io)
#
# Production lives in a SEPARATE repo that shares no history with this one - it
# is the pre-facelift 2019 site. So this replaces its tree wholesale; there is
# no sensible merge between the two histories.
#
# Until 2026-09-07 production served all 15 VE exam scripts in plaintext,
# because that repo has no _config.yml and therefore no `exclude:` list. The
# guard below refuses to publish a tree that would repeat that.
set -euo pipefail
cd "$(dirname "$0")/.."

PROD_REPO="git@github.com:parctesting/parctesting.github.io.git"
PROD_BRANCH="master"
WORK_BRANCH="production-facelift"
PROD_DOMAIN="parcradio.org"
PUSH="${1:-}"

[ -n "$(git status --porcelain)" ] && { echo "Working tree is not clean. Commit or stash first."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BUILD="$TMP/build"; mkdir -p "$BUILD"

echo "Building for $PROD_DOMAIN …"
git archive HEAD | tar -x -C "$BUILD"
printf '%s' "$PROD_DOMAIN" > "$BUILD/CNAME"
( cd "$BUILD"
  SITE_ORIGIN="https://$PROD_DOMAIN" node tools/retheme.mjs >/dev/null
  node tools/fix-alt.mjs >/dev/null 2>&1 || true
  SITE_ORIGIN="https://$PROD_DOMAIN" node tools/build-seo.mjs >/dev/null
  node tools/build-search-index.mjs >/dev/null )

# --- guards. Any failure here means do not publish. ---
fail=0
LEAK=$(grep -rilE 'read aloud|room scan procedure' "$BUILD/pages" 2>/dev/null \
       | xargs -r grep -lL 've-payload' 2>/dev/null | wc -l)
ENC=$(grep -rl 've-payload' "$BUILD/pages" 2>/dev/null | wc -l)
[ -f "$BUILD/.nojekyll" ]   && { echo "  FAIL .nojekyll present - would publish plaintext"; fail=1; }
[ -d "$BUILD/_ve-source" ]  && { echo "  FAIL _ve-source present"; fail=1; }
grep -q '_ve-source' "$BUILD/_config.yml" 2>/dev/null || { echo "  FAIL _config.yml missing its exclude list"; fail=1; }
[ "$ENC" -lt 19 ] && { echo "  FAIL only $ENC encrypted VE pages, expected 19"; fail=1; }
TOK=$(grep -ho '"token": "[a-f0-9]*"' "$BUILD/index.html" | sed 's/.*: "//;s/"//')
[ "$TOK" = "86375f5cd0ea45a9a9083404b92011b6" ] || { echo "  FAIL wrong analytics token: $TOK"; fail=1; }
[ "$fail" = "1" ] && { echo "Refusing to publish."; exit 1; }

echo "  ok  19 VE pages encrypted, no plaintext, exclude list present"
echo "  ok  token $TOK, CNAME $(cat "$BUILD/CNAME")"

if [ "$PUSH" != "--push" ]; then
  echo
  echo "Build verified. Re-run with --push to publish a branch."
  exit 0
fi

echo "Cloning production …"
git clone -q --depth 20 --branch "$PROD_BRANCH" "$PROD_REPO" "$TMP/prod"
cd "$TMP/prod"
git checkout -q -b "$WORK_BRANCH"
# Replace the tree: drop every tracked file, then lay the new build down.
git rm -rq . >/dev/null
cp -a "$BUILD/." .
git add -A
git commit -q -m "Replace the 2019 site with the current build

Production was still the pre-facelift site, and with no _config.yml it served
all 15 VE exam scripts in plaintext at guessable URLs. This replaces the tree
with the build already running on parcradio.net, rebuilt for parcradio.org:
CNAME, canonicals, sitemap, robots and the analytics token all name .org.

The 19 VE pages are AES-256-GCM ciphertext with an unlock shell, and the
exclude: list keeps their plaintext out of the published site."
git push -u origin "$WORK_BRANCH"
echo
echo "Open the PR:"
echo "  https://github.com/parctesting/parctesting.github.io/compare/$PROD_BRANCH...$WORK_BRANCH?expand=1"
