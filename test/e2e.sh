#!/usr/bin/env bash
# LeadQualify e2e tests — 7 flows exercising scoring, hours, and the API end to end.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Flow 1: hot lead — asap + big budget + contact => hot, score >= 70, reasons present
node -e "
var s = require('./lib/scoring.js');
var r = s.scoreLead({name:'Jane Doe',service:'Leak repair',timeline:'asap',budget:'over2000',location:'90210',contact:'jane@example.com'}, {});
if (r.tier !== 'hot') throw new Error('expected hot, got ' + r.tier);
if (r.score < 70) throw new Error('score too low: ' + r.score);
if (!r.reasons.length) throw new Error('no reasons');
console.log('hot lead:', r.score, JSON.stringify(r.reasons));
" || fail "flow 1: hot lead scoring"
ok "flow 1: urgent + big budget + contact scores HOT with reasons"

# Flow 2: warm lead — this week + mid budget => warm
node -e "
var s = require('./lib/scoring.js');
var r = s.scoreLead({name:'Bob',service:'Drain cleaning',timeline:'this-week',budget:'500to2000',location:'10001',contact:'bob@example.com'}, {});
if (r.tier !== 'warm') throw new Error('expected warm, got ' + r.tier + ' (' + r.score + ')');
" || fail "flow 2: warm lead scoring"
ok "flow 2: this-week + mid budget scores WARM"

# Flow 3: cold lead — browsing + small budget + no contact => cold
node -e "
var s = require('./lib/scoring.js');
var r = s.scoreLead({name:'Curious',service:'Other',timeline:'browsing',budget:'under500',location:'',contact:''}, {});
if (r.tier !== 'cold') throw new Error('expected cold, got ' + r.tier + ' (' + r.score + ')');
" || fail "flow 3: cold lead scoring"
ok "flow 3: browsing + no contact scores COLD"

# Flow 4: spam lead — link in contact => cold + spam flag, score capped
node -e "
var s = require('./lib/scoring.js');
var r = s.scoreLead({name:'asdf',service:'Other',timeline:'asap',budget:'over2000',location:'xx',contact:'http://spam.ru free money click here'}, {});
if (r.tier !== 'cold') throw new Error('expected cold, got ' + r.tier);
if (!r.spam) throw new Error('spam flag not set');
if (r.score > 5) throw new Error('spam score not capped: ' + r.score);
" || fail "flow 4: spam detection"
ok "flow 4: spammy lead flagged, capped at 5/100, COLD"

# Flow 5: business hours — Wed 10:00 open, Sun 10:00 closed, Wed 20:00 closed
node -e "
var s = require('./lib/scoring.js');
var cfg = { businessHours: { open: 9, close: 17, days: [1,2,3,4,5] } };
if (!s.isOpenNow(cfg, '2026-09-30T10:00:00')) throw new Error('Wed 10am should be open');   // Wednesday
if (s.isOpenNow(cfg, '2026-10-04T10:00:00')) throw new Error('Sun 10am should be closed');  // Sunday
if (s.isOpenNow(cfg, '2026-09-30T20:00:00')) throw new Error('Wed 8pm should be closed');
" || fail "flow 5: business hours"
ok "flow 5: after-hours detection correct (open Wed 10am, closed Sun + evenings)"

# Flow 6: full API round-trip — create -> list -> CSV contains the lead
PORT=43172
PORT=$PORT node server.js >/tmp/lq_e2e_server.log 2>&1 &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null" EXIT
for i in $(seq 1 30); do curl -sf "http://localhost:$PORT/api/leads" >/dev/null 2>&1 && break; sleep 0.3; done
ID="e2e_$(date +%s)"
curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"answers\":{\"name\":\"E2E User\",\"service\":\"Water heater\",\"timeline\":\"this-month\",\"budget\":\"500to2000\",\"location\":\"60601\",\"contact\":\"e2e@example.com\"}}" >/dev/null \
  || fail "flow 6: POST /api/lead"
TIER=$(curl -sf "http://localhost:$PORT/api/leads" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  var leads=JSON.parse(d); var l=leads.find(function(x){return x.id==='$ID';});
  if(!l) throw new Error('lead missing'); console.log(l.tier);
});") || fail "flow 6: lead missing from /api/leads"
curl -sf "http://localhost:$PORT/api/export.csv" | grep -q "$ID" || fail "flow 6: lead missing from CSV"
ok "flow 6: API round-trip create -> list (tier=$TIER) -> CSV export"

# Flow 7: server re-scores — client claims 'hot' for spam, server must correct to cold
TIER2=$(curl -sf -X POST "http://localhost:$PORT/api/lead" -H 'Content-Type: application/json' \
  -d '{"id":"e2e_spamfix","tier":"hot","score":99,"answers":{"name":"xx","service":"Other","timeline":"browsing","budget":"notsure","location":"q","contact":"www.spam.xyz"}}' \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).tier))")
[ "$TIER2" = "cold" ] || fail "flow 7: server did not re-score spam (got $TIER2)"
ok "flow 7: server re-scores untrusted client tier (spam corrected to COLD)"

# Flow 8: malformed JSON to /api/lead is rejected, server stays up
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/api/lead" \
  -H 'Content-Type: application/json' -d '{not json')
[ "$CODE" = "400" ] || fail "flow 8: expected 400, got $CODE"
curl -sf "http://localhost:$PORT/api/leads" >/dev/null || fail "flow 8: server died after bad JSON"
ok "flow 8: malformed JSON rejected with 400, server healthy"

kill $SERVER_PID 2>/dev/null; trap - EXIT
echo "E2E: $PASS/8 passed"
