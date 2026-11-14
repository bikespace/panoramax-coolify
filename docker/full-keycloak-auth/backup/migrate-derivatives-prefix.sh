#!/bin/sh
# One-off: copy the derivatives cache (SD, thumbnails, 360° tiles) to a new
# prefix in the same bucket — e.g. from the old `derivates` spelling to
# `derivatives`. Optional and purely cosmetic: the API reads derivatives from
# wherever FS_DERIVATIVES_URL points, so an existing `derivates` prefix keeps
# working indefinitely. See upgrade_instructions.md.
#
# The source is the location FS_DERIVATIVES_URL currently points at; the
# destination is <new-prefix> in the same bucket. Nothing is ever deleted, and
# the running instance is unaffected until you change the variables yourself.
#
# Usage (inside the backup container):
#   migrate-derivatives-prefix.sh <new-prefix>           # dry run: show what would happen
#   migrate-derivatives-prefix.sh --apply <new-prefix>   # copy, then verify
#
# Example:
#   docker exec -it <backup_container> migrate-derivatives-prefix.sh --apply derivatives
set -eu

usage() {
  sed -n '12,17p' "$0" | sed 's/^# \{0,1\}//'
}

APPLY=no
NEW_PREFIX=''
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=yes ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$NEW_PREFIX" ]; then echo "only one <new-prefix> allowed" >&2; exit 2; fi
      NEW_PREFIX=$arg
      ;;
  esac
done
if [ -z "$NEW_PREFIX" ]; then usage >&2; exit 2; fi

: "${FS_DERIVATIVES_URL:?FS_DERIVATIVES_URL is not set in this container}"

# shellcheck source-path=SCRIPTDIR source=s3-url.sh
. "$(dirname "$0")/s3-url.sh"
parse_fs_s3_url "$FS_DERIVATIVES_URL"

# Strip any leading/trailing slashes so "derivatives", "/derivatives/" etc. all
# mean the same thing.
NEW_PREFIX=$(echo "$NEW_PREFIX" | sed 's#^/*##; s#/*$##')
OLD_PATH=$(echo "$SRC_BUCKET_PATH" | sed 's#/*$##')
NEW_PATH="$SRC_BUCKET/$NEW_PREFIX"

if [ "$OLD_PATH" = "$NEW_PATH" ]; then
  echo "FS_DERIVATIVES_URL already points at $NEW_PATH — nothing to do."
  exit 0
fi
case "$NEW_PATH/" in
  "$OLD_PATH"/*) echo "refusing: $NEW_PATH is inside the source $OLD_PATH" >&2; exit 1 ;;
esac
case "$OLD_PATH/" in
  "$NEW_PATH"/*) echo "refusing: the source $OLD_PATH is inside $NEW_PATH" >&2; exit 1 ;;
esac

OLD="$SRC_REMOTE:$OLD_PATH"
NEW="$SRC_REMOTE:$NEW_PATH"

echo "Endpoint:    $SRC_ENDPOINT (region: ${SRC_REGION:-unset})"
echo "Source:      $OLD_PATH   (current FS_DERIVATIVES_URL location)"
echo "Destination: $NEW_PATH"
echo
echo "Source size:"
rclone size "$OLD" --fast-list
echo "Destination size (should be empty, or a partial earlier run):"
rclone size "$NEW" --fast-list 2>/dev/null || echo "  (nothing there yet)"

if [ "$APPLY" != yes ]; then
  echo
  echo "Dry run — nothing copied. Re-run with --apply to copy."
  exit 0
fi

echo
echo "Copying (server-side, idempotent — safe to interrupt and re-run)..."
rclone copy "$OLD" "$NEW" \
  --s3-acl public-read \
  --transfers 32 --checkers 64 --fast-list --stats-one-line -v

echo
echo "Verifying every source object exists at the destination with the same size..."
rclone check "$OLD" "$NEW" --one-way --size-only --fast-list

cat <<EOF

Copy verified. Next steps (none of these are done for you):
  1. Make sure the copies are publicly readable: fetch one through the public
     URL. If it returns 403/404, run fix-object-acls.sh on the "$NEW_PREFIX"
     prefix (some providers, e.g. OVH, ignore the ACL on server-side copies).
  2. In Coolify, change the prefix in BOTH FS_DERIVATIVES_URL and
     S3_DERIVATIVES_PUBLIC_URL from "${OLD_PATH#"$SRC_BUCKET"/}" to "$NEW_PREFIX", then redeploy.
  3. Open a few pictures (flat and 360°) and check that the SD image, thumbnail
     and tiles load from the new prefix.
  4. Only then delete the old prefix by hand. It is not part of any backup —
     derivatives can always be regenerated from the permanent originals.
EOF
