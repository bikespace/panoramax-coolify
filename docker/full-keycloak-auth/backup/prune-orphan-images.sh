#!/bin/sh
# Delete orphaned HD originals from the PRODUCTION permanent bucket — files that
# have no matching row in the `pictures` table (e.g. left behind by an interrupted
# or failed delete). Reconciles production against the database so `rclone sync`
# (see backup-images.sh) then mirrors the cleanup into the backup on its next run.
#
# Scope: the permanent bucket only (FS_PERMANENT_URL) — the only bucket that is
# backed up. Derivatives/tmp are regenerable and left untouched.
#
# Usage:
#   prune-orphan-images.sh            # dry run: list orphans, delete nothing
#   prune-orphan-images.sh --delete   # actually delete the orphaned files
#   prune-orphan-images.sh --delete --force   # skip the >50%-orphaned safety abort
set -eu

DELETE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=1 ;;
    --force)  FORCE=1 ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

# --- Production creds/bucket come from FS_PERMANENT_URL (no separate vars needed) ---
# Parsing lives in s3-url.sh, shared with the other production-S3 scripts.
# shellcheck source-path=SCRIPTDIR source=s3-url.sh
. "$(dirname "$0")/s3-url.sh"
parse_fs_s3_url "$FS_PERMANENT_URL"

EXPECTED=$(mktemp)
ACTUAL=$(mktemp)
ORPHANS=$(mktemp)
trap 'rm -f "$EXPECTED" "$ACTUAL" "$ORPHANS"' EXIT

# 1) Expected key for every picture, derived exactly like Panoramax's getHDPicturePath:
#    /{id[0:2]}/{id[2:4]}/{id[4:6]}/{id[6:8]}/{id[9:]}.jpg  (UUID text, dashes kept;
#    the index-8 dash is dropped). SQL substr() is 1-indexed, so Python [9:] -> substr(,10).
export PGPASSWORD="${PG_PASSWORD}"
psql -h db -U gvs -d geovisio -Atc \
  "SELECT substr(id::text,1,2)||'/'||substr(id::text,3,2)||'/'||substr(id::text,5,2)||'/'||substr(id::text,7,2)||'/'||substr(id::text,10)||'.jpg' FROM pictures;" \
  | sort > "$EXPECTED"
exp_n=$(wc -l < "$EXPECTED")

# Safety: never treat an empty or failed DB read as "everything is an orphan".
if [ "$exp_n" -eq 0 ]; then
  echo "Refusing to run: the pictures table returned 0 rows (empty DB or failed query)." >&2
  exit 1
fi

# 2) Actual HD files in the production permanent bucket (restricted to .jpg so a stray
#    non-picture object is never considered for deletion).
rclone lsf --files-only -R "$SRC" | grep -E '\.jpg$' | sort > "$ACTUAL"
act_n=$(wc -l < "$ACTUAL")

# 3) Orphans = actual - expected.
comm -23 "$ACTUAL" "$EXPECTED" > "$ORPHANS"
orph_n=$(wc -l < "$ORPHANS")

echo "DB pictures: $exp_n   bucket HD files: $act_n   orphans: $orph_n"

if [ "$orph_n" -eq 0 ]; then
  echo "Nothing to prune."
  exit 0
fi

# Safety: bail if orphans are an implausibly large share of the bucket (wrong bucket /
# wrong DB / schema surprise) unless the operator explicitly overrides with --force.
if [ "$FORCE" -ne 1 ] && [ $(( orph_n * 2 )) -gt "$act_n" ]; then
  echo "Refusing: >50% of bucket files look orphaned. Re-run with --force if this is expected." >&2
  exit 1
fi

if [ "$DELETE" -ne 1 ]; then
  echo "Dry run — the following would be deleted (pass --delete to remove them):"
  cat "$ORPHANS"
  exit 0
fi

echo "Deleting $orph_n orphaned file(s) from the production permanent bucket..."
rclone delete --files-from-raw "$ORPHANS" "$SRC" -v
echo "Done. The next backup-images.sh (sync) run will mirror these deletions to the backup."
