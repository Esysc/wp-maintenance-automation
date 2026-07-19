#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Export Cloudflare zone and DNS records as JSON into the provided directory.
# Requires environment variables:
# - CLOUDFLARE_API_TOKEN
# - CLOUDFLARE_ZONE_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

OUT_DIR=${1:-./dns}
mkdir -p "$OUT_DIR"

require_var CLOUDFLARE_API_TOKEN
require_var CLOUDFLARE_ZONE_ID

# Write auth header to a temp file to avoid exposing the token in the process
# table while curl is running.
AUTH_HEADER_FILE=$(mktemp /tmp/cf_auth.XXXXXX)
chmod 600 "$AUTH_HEADER_FILE"
printf 'Authorization: Bearer %s' "$CLOUDFLARE_API_TOKEN" > "$AUTH_HEADER_FILE"
cleanup() { rm -f "$AUTH_HEADER_FILE"; }
trap cleanup EXIT

BASE="https://api.cloudflare.com/client/v4"

echo "Exporting Cloudflare zone $CLOUDFLARE_ZONE_ID..."
curl -fsSL -H "@$AUTH_HEADER_FILE" "$BASE/zones/$CLOUDFLARE_ZONE_ID" -o "$OUT_DIR/zone.json"

echo "Exporting DNS records..."
curl -fsSL -H "@$AUTH_HEADER_FILE" "$BASE/zones/$CLOUDFLARE_ZONE_ID/dns_records?per_page=1000" -o "$OUT_DIR/dns_records.json"

echo "Cloudflare DNS export written to $OUT_DIR"
