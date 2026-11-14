#!/bin/sh
# shellcheck disable=SC2034  # sets variables for the sourcing script
# Sourced helper, not a job: parses one of the production storage URLs
# (FS_PERMANENT_URL, FS_DERIVATIVES_URL, ...) into rclone connection pieces, so
# the scripts that need production S3 access don't each carry their own copy.
#
# Usage (from a script in the same directory):
#   . "$(dirname "$0")/s3-url.sh"
#   parse_fs_s3_url "$FS_PERMANENT_URL"
#
# Expected format:
#   s3://ACCESS_KEY:SECRET_KEY@bucket/prefix?endpoint_url=<url-encoded>&region=<region>
#
# Sets:
#   SRC_ACCESS_KEY, SRC_SECRET_KEY, SRC_ENDPOINT, SRC_REGION
#   SRC_BUCKET_PATH  bucket/prefix (everything between '@' and '?')
#   SRC_BUCKET       bucket only
#   SRC_REMOTE       rclone on-the-fly remote, without a path — append
#                    ":bucket/prefix" to use it
#   SRC              "$SRC_REMOTE:$SRC_BUCKET_PATH" — the URL's own location

parse_fs_s3_url() {
  case "$1" in
    s3://*) ;;
    *) echo "parse_fs_s3_url: expected an s3:// URL" >&2; return 1 ;;
  esac
  _rest=${1#s3://}
  _creds=${_rest%%@*}
  _after_at=${_rest#*@}
  SRC_ACCESS_KEY=${_creds%%:*}
  _secret_enc=${_creds#*:}
  SRC_SECRET_KEY=$(printf '%b' "$(echo "$_secret_enc" | sed 's/%/\\x/g')")
  SRC_BUCKET_PATH=${_after_at%%\?*}
  SRC_BUCKET=${SRC_BUCKET_PATH%%/*}
  _query=${_after_at#*\?}
  _endpoint_enc=$(echo "$_query" | sed -n 's/.*endpoint_url=\([^&]*\).*/\1/p')
  SRC_ENDPOINT=$(printf '%b' "$(echo "$_endpoint_enc" | sed 's/%/\\x/g')")
  SRC_REGION=$(echo "$_query" | sed -n 's/.*region=\([^&]*\).*/\1/p')

  # endpoint/region are single-quoted: they may contain ':' (e.g. "https://host")
  # which would otherwise be misread as the connection-string/path separator.
  SRC_REMOTE=":s3,provider=Other,access_key_id=${SRC_ACCESS_KEY},secret_access_key=${SRC_SECRET_KEY},endpoint='${SRC_ENDPOINT}',region='${SRC_REGION}'"
  SRC="${SRC_REMOTE}:${SRC_BUCKET_PATH}"
}
