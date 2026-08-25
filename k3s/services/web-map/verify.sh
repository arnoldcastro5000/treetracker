#!/usr/bin/env bash
# verify: definition-of-done for the web-map thin spine (decision 07: high-zoom-only dots).
# 1. The client serves HTML at /map/. 2. query-api answers on /query/ AND the /webmap/ compat
# prefix. 3. The tile server renders a z16 PNG over the seeded capture area (Buwagi; z>15 is the
# `trees`-backed zoom band). 4. The webmap schema exists. All through the gateway, like a browser.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/orchestrator-lib.sh"

GW="${GATEWAY_URL:-http://localhost:${GATEWAY_HTTP_PORT:-8088}}"
fails=0
check() {   # check <name> <want-substring-of-content-type|-> <url> [attempts]
  local name="$1" want="$2" url="$3" attempts="${4:-30}" code ctype
  for i in $(seq 1 "$attempts"); do
    code=$(curl -sL -o /tmp/webmap-verify-body -w '%{http_code}' --max-time 15 "$url" || echo 000)
    if [ "$code" = 200 ]; then
      ctype=$(curl -sL -o /dev/null -w '%{content_type}' --max-time 15 "$url" || true)
      if [ "$want" = "-" ] || printf '%s' "$ctype" | grep -qi "$want"; then
        log "verify OK: $name"
        return 0
      fi
    fi
    sleep 2
  done
  warn "verify FAIL: $name ($url -> $code, content-type ${ctype:-?})"
  fails=$((fails + 1))
}

log "web-map verify (gateway $GW)"
check "client HTML at /map/"        "text/html" "$GW/map/"
check "query-api /query/trees"      "json"      "$GW/query/trees?limit=1"
check "query-api compat /webmap"    "json"      "$GW/webmap/trees?limit=1"
# Tile over the Buwagi capture area: z16 x38805 y32670 (lat 0.5385, lon 33.1592).
check "tile z16 over capture area"  "image/png" "$GW/tiles/16/38805/32670.png" 45

if k -n data exec deploy/postgres -- psql -U postgres -d treetracker -tAc \
     "select 1 from information_schema.schemata where schema_name='webmap'" 2>/dev/null | grep -q 1; then
  log "verify OK: webmap schema exists"
else
  warn "verify FAIL: webmap schema missing"
  fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] || die "web-map verify: $fails check(s) failed"
log "web-map verify: all green"
