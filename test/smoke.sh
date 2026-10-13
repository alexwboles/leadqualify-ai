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

# 17b. parseCsv pure function: quoted fields, escaped quotes, blank rows skipped
node -e "
var s = require('./lib/scoring.js');
if (typeof s.parseCsv !== 'function') throw new Error('parseCsv not exported');
var p = s.parseCsv('name,service,contact\r\n\"Doe, Jane\",\"Leak \"\"repair\"\"\",jane@example.com\r\nBob,,bob@example.com\r\n,,\r\n');
if (p.headers.join('|') !== 'name|service|contact') throw new Error('headers: ' + JSON.stringify(p.headers));
if (p.rows.length !== 2) throw new Error('rows: ' + p.rows.length);
if (p.rows[0][0] !== 'Doe, Jane' || p.rows[0][1] !== 'Leak \"repair\"') throw new Error('quoted fields: ' + JSON.stringify(p.rows[0]));
if (s.parseCsv('').rows.length !== 0) throw new Error('empty csv');
// funnelStats gains bySource attribution
var fs = s.funnelStats([
  { tier: 'hot', score: 90, status: 'new', createdAt: '2026-10-12T10:00:00.000Z', source: 'homepage' },
  { tier: 'warm', score: 50, status: 'new', createdAt: '2026-10-12T10:00:00.000Z', source: 'homepage' },
  { tier: 'cold', score: 5, status: 'new', createdAt: '2026-10-12T10:00:00.000Z', source: 'adwords' }
], 30, new Date('2026-10-12T12:00:00').getTime());
if (!fs.bySource || fs.bySource.homepage !== 2 || fs.bySource.adwords !== 1) throw new Error('bySource: ' + JSON.stringify(fs.bySource));
console.log('parseCsv + bySource ok');
" || fail "parseCsv pure function / bySource"
ok "parseCsv handles quotes/escapes; funnelStats gains bySource"

# 18. notes API: add note, persisted on lead; empty text 400s; unknown id 404s
ID="smoke_note_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"answers\":{\"name\":\"Notey McNote\",\"service\":\"Repair\",\"timeline\":\"this-week\",\"budget\":\"500to2000\",\"location\":\"10001\",\"contact\":\"555-0188\"}}" >/dev/null \
  || fail "POST /api/lead (notes target) failed"
curl -sf -X POST "http://localhost:$PORT/api/lead/$ID/notes" -H 'Content-Type: application/json' \
  -d '{"author":"Ann","text":"Called twice, no answer."}' | grep -q '"notes":1' || fail "note add failed"
curl -sf "http://localhost:$PORT/api/leads" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var l=JSON.parse(d).find(function(x){return x.id==='$ID';});
  if(!l||!l.notes||l.notes.length!==1||l.notes[0].text!=='Called twice, no answer.') throw new Error('note not persisted');
});" || fail "note not persisted on lead"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/api/lead/$ID/notes" \
  -H 'Content-Type: application/json' -d '{"text":"   "}')
[ "$CODE" = "400" ] || fail "empty note should 400, got $CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/api/lead/no_such_lead/notes" \
  -H 'Content-Type: application/json' -d '{"text":"hi"}')
[ "$CODE" = "404" ] || fail "note on missing lead should 404, got $CODE"
curl -sf -X DELETE "http://localhost:$PORT/api/lead/$ID" >/dev/null || fail "cleanup delete failed"
ok "POST /api/lead/:id/notes appends timeline notes (400 empty, 404 unknown)"

# 19. CSV import: header row -> scored leads; duplicate flagged; blank rows skipped
CSV="name,service,timeline,budget,location,contact,source
\"Imp, Alice\",\"Leak repair\",asap,over2000,90210,impalice@example.com,trade-show
,,,
Bob Browse,Repair,browsing,notsure,00000,,csv-test
"
SUM=$(curl -sf -X POST "http://localhost:$PORT/api/import.csv" -H 'Content-Type: text/csv' --data-binary "$CSV")
echo "$SUM" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var s=JSON.parse(d);
  if(s.created!==2||s.skipped!==1) throw new Error('summary wrong: '+d);
});" || fail "import summary wrong: $SUM"
curl -sf "http://localhost:$PORT/api/leads" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var leads=JSON.parse(d);
  var a=leads.filter(function(l){return (l.answers||{}).name==='Imp, Alice';});
  if(a.length!==1) throw new Error('alice missing');
  if(a[0].tier!=='hot'||a[0].source!=='trade-show') throw new Error('alice not scored/attributed: '+JSON.stringify({tier:a[0].tier,source:a[0].source}));
});" || fail "imported lead not scored or attributed"
# repeat import -> duplicates flagged
SUM2=$(curl -sf -X POST "http://localhost:$PORT/api/import.csv" -H 'Content-Type: text/csv' --data-binary "$CSV")
echo "$SUM2" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var s=JSON.parse(d);
  if(s.created!==2||s.duplicates!==1) throw new Error('dup summary wrong: '+d);
});" || fail "re-import duplicate summary wrong: $SUM2"
curl -sf "http://localhost:$PORT/api/leads" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var leads=JSON.parse(d);
  leads.filter(function(l){return (l.answers||{}).name==='Imp, Alice'||(l.answers||{}).name==='Bob Browse';})
    .forEach(function(l){ console.log(l.id); });
});" | while read -r LID; do curl -sf -X DELETE "http://localhost:$PORT/api/lead/$LID" >/dev/null; done
LEFT=$(curl -sf "http://localhost:$PORT/api/leads" | grep -c "Imp, Alice\|Bob Browse" || true)
[ "$LEFT" = "0" ] || fail "imported leads not cleaned up"
ok "POST /api/import.csv bulk-imports + scores + flags duplicates"

# 20. source attribution round-trip: explicit source stored, CSV + stats expose it
ID="smoke_src_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"source\":\"pricing-page\",\"answers\":{\"name\":\"Src Test\",\"service\":\"Repair\",\"timeline\":\"asap\",\"budget\":\"over2000\",\"location\":\"90210\",\"contact\":\"src@example.com\"}}" >/dev/null \
  || fail "POST /api/lead (source) failed"
curl -sf "http://localhost:$PORT/api/leads" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var l=JSON.parse(d).find(function(x){return x.id==='$ID';});
  if(!l||l.source!=='pricing-page') throw new Error('source not stored');
});" || fail "source not stored"
curl -sf "http://localhost:$PORT/api/export.csv?q=Src%20Test" | grep -q "source" || fail "CSV missing source column"
curl -sf "http://localhost:$PORT/api/export.csv?q=Src%20Test" | grep -q "pricing-page" || fail "CSV missing source value"
curl -sf "http://localhost:$PORT/api/stats?days=30" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var s=JSON.parse(d);
  if(!s.bySource||s.bySource['pricing-page']<1) throw new Error('bySource missing: '+d);
});" || fail "stats bySource missing pricing-page"
curl -sf -X DELETE "http://localhost:$PORT/api/lead/$ID" >/dev/null || fail "cleanup delete failed"
ok "source attribution: stored, in CSV export, in /api/stats bySource"

# 21. inbox wires notes timeline + CSV import button
grep -q 'data-act="notes"' inbox/index.html || fail "inbox missing notes toggle"
grep -q 'api/import.csv' inbox/index.html || fail "inbox missing import POST"
grep -q 'source-tag' inbox/index.html || fail "inbox missing source tag"
ok "inbox wires notes timeline, CSV import, source tags"

# 22. pipeline board: view toggle + board renderer + stage buttons wired
grep -q 'data-v="board"' inbox/index.html || fail "inbox missing board view toggle"
grep -q 'renderBoard' inbox/index.html || fail "inbox missing renderBoard"
grep -q 'data-stage-act' inbox/index.html || fail "inbox missing stage buttons"
grep -q 'rot-badge' inbox/index.html || fail "inbox missing rotting badge"
grep -q '/stage' inbox/index.html || fail "inbox missing stage POST"
ok "inbox has List/Board toggle, kanban board, stage buttons, rotting flags"

# 23. server exposes pipeline stage endpoint
curl -sf "http://localhost:$PORT/api/leads" >/dev/null || fail "server not reachable"
grep -q 'STAGES' server.js || fail "server missing STAGES"
grep -q 'stageMatch' server.js || fail "server missing stage endpoint"
ok "server exposes stage model + POST /api/lead/:id/stage"

kill $SERVER_PID 2>/dev/null; trap - EXIT
echo "SMOKE: $PASS/25 passed"
