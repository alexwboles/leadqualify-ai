#!/usr/bin/env bash
# LeadQualify smoke tests — 19 checks. Fails fast on first failure.
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

# 5b. lead-management pure functions: duplicates, follow-ups, funnel stats
node -e "
var s = require('./lib/scoring.js');
['contactKey','findDuplicates','needsFollowUp','funnelStats'].forEach(function (f) {
  if (typeof s[f] !== 'function') throw new Error('missing ' + f);
});
// contactKey: emails normalized, phones digit-stripped
if (s.contactKey({ contact: 'Jane@Example.com' }) !== 'email:jane@example.com') throw new Error('email key');
if (s.contactKey({ contact: '(555) 123-4567' }) !== 'phone:5551234567') throw new Error('phone key');
if (s.contactKey({ contact: 'x' }) !== '') throw new Error('junk key should be empty');
// duplicates: same email twice within 30 days
var now = new Date('2026-10-12T12:00:00').getTime();
var leads = [
  { id: 'l1', createdAt: '2026-10-01T10:00:00.000Z', answers: { contact: 'jane@example.com' }, tier: 'warm', score: 55 },
  { id: 'l2', createdAt: '2026-09-01T10:00:00.000Z', answers: { contact: 'jane@example.com' }, tier: 'cold', score: 20 },
  { id: 'l3', createdAt: '2026-10-10T10:00:00.000Z', answers: { contact: 'bob@example.com' }, tier: 'hot', score: 80 }
];
var dups = s.findDuplicates(leads, { contact: 'Jane@Example.com' }, 30, now);
if (dups.length !== 1 || dups[0].lead.id !== 'l1') throw new Error('duplicates: ' + JSON.stringify(dups.map(function(d){return d.lead.id;})));
if (s.findDuplicates(leads, { contact: 'nobody@example.com' }, 30, now).length !== 0) throw new Error('false positive');
// follow-ups: hot/warm + new + older than 24h
var fu = s.needsFollowUp([
  { id: 'a', tier: 'hot', score: 90, status: 'new', createdAt: '2026-10-10T10:00:00.000Z' },
  { id: 'b', tier: 'warm', score: 50, status: 'new', createdAt: '2026-10-12T11:00:00.000Z' },
  { id: 'c', tier: 'hot', score: 80, status: 'contacted', createdAt: '2026-10-09T10:00:00.000Z' },
  { id: 'd', tier: 'cold', score: 10, status: 'new', createdAt: '2026-10-09T10:00:00.000Z' }
], 24, now);
if (fu.length !== 1 || fu[0].id !== 'a') throw new Error('followups: ' + JSON.stringify(fu.map(function(x){return x.id;})));
// funnel stats
var fs = s.funnelStats([
  { tier: 'hot', score: 90, status: 'contacted', spam: false, createdAt: '2026-10-12T10:00:00.000Z' },
  { tier: 'warm', score: 50, status: 'new', spam: false, createdAt: '2026-10-11T10:00:00.000Z' },
  { tier: 'cold', score: 5, status: 'new', spam: true, createdAt: '2026-10-11T10:00:00.000Z' },
  { tier: 'hot', score: 80, status: 'new', spam: false, createdAt: '2026-01-01T10:00:00.000Z' }
], 30, now);
if (fs.total !== 3 || fs.byTier.hot !== 1 || fs.hotToday !== 1) throw new Error('funnel: ' + JSON.stringify(fs));
if (fs.spamRate !== 33 || fs.contactRate !== 33) throw new Error('rates: ' + JSON.stringify(fs));
console.log('lead-mgmt pure functions ok');
" || fail "lead-management pure functions"
ok "contactKey/findDuplicates/needsFollowUp/funnelStats pure logic"

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

# 12. DELETE /api/lead/:id removes a lead; second delete 404s
ID="smoke_del_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"answers\":{\"name\":\"Delete Me\",\"service\":\"Repair\",\"timeline\":\"browsing\",\"budget\":\"notsure\",\"location\":\"00000\",\"contact\":\"x\"}}" >/dev/null \
  || fail "POST /api/lead (delete target) failed"
curl -sf -X DELETE "http://localhost:$PORT/api/lead/$ID" >/dev/null || fail "DELETE /api/lead/:id failed"
curl -sf "http://localhost:$PORT/api/leads" | grep -q "$ID" && fail "lead still listed after DELETE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:$PORT/api/lead/$ID")
[ "$CODE" = "404" ] || fail "DELETE missing lead should 404, got $CODE"
ok "DELETE /api/lead/:id removes lead, 404s on unknown id"

# 13. status endpoint: mark contacted; invalid status rejected with 400
ID="smoke_status_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"answers\":{\"name\":\"Status Test\",\"service\":\"Repair\",\"timeline\":\"this-week\",\"budget\":\"500to2000\",\"location\":\"11111\",\"contact\":\"555-0199\"}}" >/dev/null \
  || fail "POST /api/lead (status target) failed"
curl -sf -X POST "http://localhost:$PORT/api/lead/$ID/status" -H 'Content-Type: application/json' \
  -d '{"status":"contacted"}' | grep -q '"status":"contacted"' || fail "status update failed"
curl -sf "http://localhost:$PORT/api/leads" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var l=JSON.parse(d).find(function(x){return x.id==='$ID';});
  if(!l||l.status!=='contacted') throw new Error('status not persisted');
});" || fail "status not persisted in /api/leads"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/api/lead/$ID/status" \
  -H 'Content-Type: application/json' -d '{"status":"bogus"}')
[ "$CODE" = "400" ] || fail "invalid status should 400, got $CODE"
curl -sf -X DELETE "http://localhost:$PORT/api/lead/$ID" >/dev/null || fail "cleanup delete failed"
ok "POST /api/lead/:id/status marks contacted (400 on invalid), persisted"

# 14. filtered CSV export: tier + q + days params
HOT="smoke_fhot_$(date +%s)"; COLD="smoke_fcold_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$HOT\",\"answers\":{\"name\":\"Zelda Hotwell\",\"service\":\"Emergency repair\",\"timeline\":\"asap\",\"budget\":\"over2000\",\"location\":\"90210\",\"contact\":\"zelda@example.com\"}}" >/dev/null || fail "seed hot lead"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$COLD\",\"answers\":{\"name\":\"Chilly McCold\",\"service\":\"Repair\",\"timeline\":\"browsing\",\"budget\":\"notsure\",\"location\":\"00000\",\"contact\":\"x\"}}" >/dev/null || fail "seed cold lead"
CSV=$(curl -sf "http://localhost:$PORT/api/export.csv?tier=hot&q=Hotwell&days=7")
echo "$CSV" | head -1 | grep -q "status" || fail "CSV header missing status column"
echo "$CSV" | grep -q "$HOT" || fail "filtered CSV missing hot lead"
echo "$CSV" | grep -q "$COLD" && fail "filtered CSV should exclude cold lead"
CSVQ=$(curl -sf "http://localhost:$PORT/api/export.csv?q=nonexistentnamezzz")
echo "$CSVQ" | grep -q "$HOT\|$COLD" && fail "q= filter should match nothing"
curl -sf -X DELETE "http://localhost:$PORT/api/lead/$HOT" >/dev/null
curl -sf -X DELETE "http://localhost:$PORT/api/lead/$COLD" >/dev/null
ok "GET /api/export.csv?tier=&q=&days= filters rows + adds status column"

# 15. duplicate detection: same contact twice -> second flags duplicateOf
DUP="smoke_dup_$(date +%s)"
R1=$(curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"${DUP}_1\",\"answers\":{\"name\":\"Dup Test\",\"service\":\"Repair\",\"timeline\":\"asap\",\"budget\":\"over2000\",\"location\":\"90210\",\"contact\":\"duptest@example.com\"}}")
echo "$R1" | grep -q '"duplicates":0' || fail "first lead should have 0 duplicates: $R1"
R2=$(curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"${DUP}_2\",\"answers\":{\"name\":\"Dup Test Again\",\"service\":\"Repair\",\"timeline\":\"asap\",\"budget\":\"over2000\",\"location\":\"90210\",\"contact\":\"DUPTEST@example.com\"}}")
echo "$R2" | grep -q '"duplicates":1' || fail "second lead should flag 1 duplicate: $R2"
curl -sf "http://localhost:$PORT/api/leads" | grep -q "${DUP}_2" || fail "dup lead not listed"
curl -sf "http://localhost:$PORT/api/export.csv" | grep -q "duplicates" || fail "CSV missing duplicates column"
curl -sf -X DELETE "http://localhost:$PORT/api/lead/${DUP}_1" >/dev/null
curl -sf -X DELETE "http://localhost:$PORT/api/lead/${DUP}_2" >/dev/null
ok "duplicate detection: same contact twice -> duplicateOf flagged + CSV column"

# 16. /api/stats + /api/followups endpoints
curl -sf "http://localhost:$PORT/api/stats" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var s=JSON.parse(d);
  if(typeof s.total!=='number'||!s.byTier||typeof s.contactRate!=='number') throw new Error('bad stats: '+d);
});" || fail "GET /api/stats bad shape"
ok "GET /api/stats returns funnel snapshot"
curl -sf "http://localhost:$PORT/api/followups?hours=1" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var f=JSON.parse(d);
  if(!Array.isArray(f)) throw new Error('not an array');
});" || fail "GET /api/followups bad shape"
ok "GET /api/followups returns follow-up queue array"

# 17. inbox shows duplicate badge + follow-up section wiring
grep -q 'duplicateOf' inbox/index.html || fail "inbox missing duplicate badge"
grep -q 'api/followups' inbox/index.html || fail "inbox missing followups fetch"
grep -q 'api/stats' inbox/index.html || fail "inbox missing stats fetch"
ok "inbox wires duplicate badge, follow-up queue, funnel stats"

kill $SERVER_PID 2>/dev/null; trap - EXIT
echo "SMOKE: $PASS/19 passed"
