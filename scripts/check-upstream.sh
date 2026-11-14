#!/bin/sh
# Report upstream changes to the deployment files this repo tracks.
# Usage: sh scripts/check-upstream.sh [--record]
set -eu

UPSTREAM_URL=https://gitlab.com/panoramax/server/api.git
UPSTREAM_BRANCH=main
TRACKED_PATH=docker/full-keycloak-auth/

RECORD=no
case "${1:-}" in
  --record) RECORD=yes ;;
  '') ;;
  *) echo "usage: $0 [--record]" >&2; exit 2 ;;
esac

ROOT=$(git rev-parse --show-toplevel)
STATE="$ROOT/.upstream-sync"

# Fetch by URL rather than via a named remote, so this works on a fresh clone
# with no setup. FETCH_HEAD is the upstream tip for the rest of the script.
git -C "$ROOT" fetch --quiet "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
TIP=$(git -C "$ROOT" rev-parse FETCH_HEAD)

# Release tag pointing at the tip, if any — informational only, the SHA is what
# gets compared. Annotated tags are listed twice by ls-remote (the tag object,
# then the peeled commit as "<tag>^{}"); lightweight tags only once. Matching
# the commit SHA on either form covers both.
TIP_TAG=$(git ls-remote --tags "$UPSTREAM_URL" \
  | awk -v tip="$TIP" '$1 == tip { sub("^refs/tags/", "", $2); sub("\\^\\{\\}$", "", $2); print $2; exit }')
TIP_TAG=${TIP_TAG:-none}

echo "Upstream $UPSTREAM_BRANCH tip: $(git -C "$ROOT" log -1 --pretty='%h %ad %s' --date=short "$TIP") (tag: $TIP_TAG)"

SINCE=''
SINCE_TAG=''
if [ -f "$STATE" ]; then
  SINCE=$(sed -n 's/^last_reviewed_sha=//p' "$STATE")
  SINCE_TAG=$(sed -n 's/^last_reviewed_tag=//p' "$STATE")
fi

if [ -z "$SINCE" ]; then
  echo "No last_reviewed_sha in $STATE — showing the full history of $TRACKED_PATH."
elif ! git -C "$ROOT" cat-file -e "$SINCE^{commit}" 2>/dev/null; then
  echo "Recorded SHA $SINCE is not in the fetched history (force-push, or a typo)."
  echo "Showing the full history of $TRACKED_PATH instead."
  SINCE=''
fi

if [ -n "$SINCE" ]; then
  RANGE="$SINCE..$TIP"
  SINCE_DESC="$(git -C "$ROOT" log -1 --pretty='%h (%ad)' --date=short "$SINCE")"
  if [ -n "$SINCE_TAG" ] && [ "$SINCE_TAG" != none ]; then
    SINCE_DESC="$SINCE_TAG, $SINCE_DESC"
  fi
else
  RANGE="$TIP"
  SINCE_DESC='the beginning'
fi

CHANGES=$(git -C "$ROOT" log --oneline "$RANGE" -- "$TRACKED_PATH")

if [ -z "$CHANGES" ]; then
  echo "No upstream changes to $TRACKED_PATH since $SINCE_DESC."
  RESULT=clean
else
  echo
  echo "Upstream commits touching $TRACKED_PATH since $SINCE_DESC:"
  echo "$CHANGES"
  echo
  git -C "$ROOT" diff --stat "$RANGE" -- "$TRACKED_PATH"
  RESULT=changes
fi

if [ "$RECORD" = yes ]; then
  TMP="$STATE.tmp"
  {
    echo "last_reviewed_sha=$TIP"
    echo "last_reviewed_tag=$TIP_TAG"
    echo "last_checked_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$TMP"
  mv "$TMP" "$STATE"
  echo
  echo "Recorded $TIP (tag: $TIP_TAG) as reviewed in .upstream-sync."
elif [ "$RESULT" = changes ]; then
  echo
  echo "Once these are reviewed or ported, re-run with --record to mark them done."
fi
