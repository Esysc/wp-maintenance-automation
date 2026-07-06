#!/usr/bin/env bash
set -euo pipefail

# Export Cloudflare zone and DNS records as JSON into the provided directory.
# Requires environment variables:
# - CLOUDFLARE_API_TOKEN
# - CLOUDFLARE_ZONE_ID

OUT_DIR=${1:-./dns}
mkdir -p "$OUT_DIR"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: Required variable '$name' is not set." >&2
    exit 1
  fi
}

require_var CLOUDFLARE_API_TOKEN
require_var CLOUDFLARE_ZONE_ID

AUTH_HEADER="Authorization: Bearer $CLOUDFLARE_API_TOKEN"
BASE="https://api.cloudflare.com/client/v4"

echo "Exporting Cloudflare zone $CLOUDFLARE_ZONE_ID..."
curl -fsSL -H "$AUTH_HEADER" "$BASE/zones/$CLOUDFLARE_ZONE_ID" -o "$OUT_DIR/zone.json"

echo "Exporting DNS records..."
curl -fsSL -H "$AUTH_HEADER" "$BASE/zones/$CLOUDFLARE_ZONE_ID/dns_records?per_page=1000" -o "$OUT_DIR/dns_records.json"

echo "Cloudflare DNS export written to $OUT_DIR"
