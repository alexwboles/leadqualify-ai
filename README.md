# LeadQualify 🔥 — AI lead-qualifier chat widget for local businesses

**Problem:** Local businesses miss after-hours leads. A visitor lands on the site at 9pm, finds no way to get a fast answer, and bounces to a competitor.

**Solution:** A chat widget embedded with **one script tag**. It asks 5 smart qualifying questions (name → service → timeline → budget → location → contact), scores the lead **hot / warm / cold** with a plain-language reason, and drops it in the owner's lead inbox — with an after-hours auto-responder so night visitors still convert.

## Pricing vision
| Plan | Price | For |
|------|-------|-----|
| Starter | Free | 1 site, 25 leads/mo |
| Pro | $29/mo | Unlimited leads, CSV export, after-hours responder |
| Agency | $79/mo | 10 sites, white-label, priority scoring rules |

## How to run
```bash
node server.js            # http://localhost:4317/demo/
# or open the files directly — the widget works without a server
# (leads then save to the browser's localStorage instead of the API)
```

## Embed on any website (one script tag)
```html
<script src="https://YOUR-HOST/widget/leadqualify.js"></script>
<script>
LeadQualify.init({
  businessName: "Acme Plumbing",
  apiBase: "https://YOUR-HOST",   /* where leads get POSTed */
  primaryColor: "#1d4ed8",
  services: ["Leak repair", "Drain cleaning", "Water heater", "Remodel", "Other"],
  businessHours: { open: 9, close: 17, days: [1,2,3,4,5] }
});
</script>
```
Or configure inline: `<script src=".../leadqualify.js" data-lq-config='{"businessName":"Acme"}'></script>`

## How scoring works (no AI key needed)
Local heuristics, fully offline:
- **Timeline:** ASAP/emergency +40 · this week +25 · this month +15 · browsing +2
- **Budget:** over $2k +20 · $500–2k +15 · under $500 +8 · unsure +10
- **Clear service need** +10 · **contact info left** +10 · **location given** +5
- **Spam signals** (links, gibberish, repeated chars) → capped at 5/100, tier cold

Tiers: **🔥 hot ≥ 70**, **🟡 warm 40–69**, **🔵 cold < 40**. Every score ships with plain-language reasons ("Needs help ASAP — treat as urgent"). If `OPENAI_API_KEY` is ever wired up later, it can polish reasons — never required.

## Project layout
```
widget/leadqualify.js   the embeddable widget (also the scoring source of truth; require()-able in Node)
lib/scoring.js          thin Node wrapper re-exporting the widget's pure logic
server.js               zero-dependency Node server: static files + /api/lead, /api/leads, /api/export.csv, /api/score
demo/index.html         fake plumber site with the widget live
inbox/index.html        lead inbox: filter by tier, live refresh, CSV export
config/                 sample business configs
data/leads.json         created at runtime (git-ignored)
test/smoke.sh test/e2e.sh
```

## Privacy
All logic runs locally. Leads are POSTed only to **your own** `apiBase` — nothing is sent to any third party.

## Tests
```bash
bash test/smoke.sh   # 10 checks
bash test/e2e.sh     # 7 flows
```
