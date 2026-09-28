#!/usr/bin/env bash
# LeadQualify smoke tests — 10 checks. Fails fast on first failure.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# 1. required files exist
for f in widget/leadqualify.js lib/scoring.js server.js demo/index.html inbox/index.html README.md config/acme-plumbing.json package.json; do
  [ -f "$f" ] || fail "missing file $f"
done
ok "all 8 required files exist"

# 2-4. JS syntax valid
node --check widget/leadqualify.js || fail "widget/leadqualify.js syntax"
ok "widget/leadqualify.js syntax valid"
node --check server.js || fail "server.js syntax"
ok "server.js syntax valid"
node --check lib/scoring.js || fail "lib/scoring.js syntax"
ok "lib/scoring.js syntax valid"

# 5. scoring lib loads in Node and exposes pure functions
node -e "var s=require('./lib/scoring.js'); if(typeof s.scoreLead!=='function'||typeof s.isOpenNow!=='function') throw new Error('bad exports');" \
  || fail "scoring lib exports"
ok "scoring lib loads in Node with scoreLead + isOpenNow"

# 6. config sample is valid JSON with required keys
node -e "var c=require('./config/acme-plumbing.json'); if(!c.businessName||!c.businessHours||!c.services) throw new Error('bad config');" \
  || fail "config invalid"
ok "config/acme-plumbing.json valid"

PORT=43171
PORT=$PORT node server.js >/tmp/lq_smoke_server.log 2>&1 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null" EXIT
for i in $(seq 1 30); do
  curl -sf "http://localhost:$PORT/demo/" >/dev/null 2>&1 && break
  sleep 0.3
done
curl -sf "http://localhost:$PORT/demo/" >/dev/null || fail "GET /demo/ not 200"
ok "server boots, GET /demo/ returns 200"

# 7. widget served and contains the LeadQualify global
curl -sf "http://localhost:$PORT/widget/leadqualify.js" | grep -q "LeadQualify" || fail "widget not served"
ok "GET /widget/leadqualify.js served with LeadQualify global"

# 8. hot sample scores hot via API
TIER=$(curl -sf -X POST "http://localhost:$PORT/api/score" -H 'Content-Type: application/json' \
  -d '{"answers":{"name":"Jane","service":"Leak repair","timeline":"asap","budget":"over2000","location":"90210","contact":"jane@example.com"}}' \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).tier))")
[ "$TIER" = "hot" ] || fail "hot sample scored as $TIER"
ok "POST /api/score: hot sample -> hot"

# 9. spam sample scores cold via API
TIER=$(curl -sf -X POST "http://localhost:$PORT/api/score" -H 'Content-Type: application/json' \
  -d '{"answers":{"name":"asdf","service":"Other","timeline":"browsing","budget":"notsure","location":"xx","contact":"http://spam.ru free money"}}' \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).tier))")
[ "$TIER" = "cold" ] || fail "spam sample scored as $TIER"
ok "POST /api/score: spam sample -> cold"

# 10. lead round-trip: create -> list -> CSV export has header with tier column
ID="smoke_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"answers\":{\"name\":\"Smoke Test\",\"service\":\"Drain cleaning\",\"timeline\":\"this-week\",\"budget\":\"500to2000\",\"location\":\"10001\",\"contact\":\"555-0100\"}}" >/dev/null \
  || fail "POST /api/lead failed"
curl -sf "http://localhost:$PORT/api/leads" | grep -q "$ID" || fail "lead not in /api/leads"
curl -sf "http://localhost:$PORT/api/export.csv" | head -1 | grep -q "tier" || fail "CSV missing tier column"
curl -sf "http://localhost:$PORT/api/export.csv" | grep -q "$ID" || fail "lead not in CSV export"
ok "lead round-trip: create -> list -> CSV export works"

kill $SERVER_PID 2>/dev/null; trap - EXIT
echo "SMOKE: $PASS/11 passed"
