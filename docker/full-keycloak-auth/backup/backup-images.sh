#!/bin/sh
set -eu

# --- Production creds/bucket come from FS_PERMANENT_URL (no separate vars needed) ---
# Parsing lives in s3-url.sh, shared with the other production-S3 scripts.
# shellcheck source-path=SCRIPTDIR source=s3-url.sh
. "$(dirname "$0")/s3-url.sh"
parse_fs_s3_url "$FS_PERMANENT_URL"

DST=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint='${BACKUP_S3_ENDPOINT}',region='${BACKUP_S3_REGION}':${BACKUP_S3_BUCKET}/images/permanent"

# 'sync' (default) makes the backup an exact mirror of production's permanent
# bucket: a picture removed in production is removed from the backup on the next
# run. The backup bucket's object-versioning + 30-day lifecycle rule is the
# safety net for accidental deletions (see deployment_instructions.md §2.1).
# To keep deleted pictures in the backup indefinitely, change 'sync' to 'copy'
# below (additive: never deletes from the backup) — and/or lengthen the backup
# bucket's retention window.
# -v is required for rclone to print the final transfer stats at all — at the
# default NOTICE log level a clean run is otherwise completely silent.
rclone sync "$SRC" "$DST" \
  --transfers 16 --checkers 32 --fast-list --stats-one-line -v

# Success marker for the container healthcheck (§7.3).
touch /backups/.ok-images
