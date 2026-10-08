// LeadQualify tiny server — zero dependencies, Node built-ins only.
// Serves the demo page, widget, inbox UI, and a small JSON API for leads.
var http = require("http");
var fs = require("fs");
var path = require("path");

var ROOT = path.join(__dirname);
var DATA_FILE = path.join(ROOT, "data", "leads.json");
var PORT = process.env.PORT || 4317;

var MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml"
};

function readLeads() {
  try {
    return JSON.parse(fs.readFileSync(DATA_FILE, "utf8"));
  } catch (e) {
    return [];
  }
}

function writeLeads(leads) {
  fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
  fs.writeFileSync(DATA_FILE, JSON.stringify(leads, null, 2));
}

function send(res, code, body, type) {
  res.writeHead(code, { "Content-Type": type || "text/plain; charset=utf-8" });
  res.end(body);
}

function serveFile(res, filePath) {
  fs.readFile(filePath, function (err, data) {
    if (err) return send(res, 404, "Not found");
    send(res, 200, data, MIME[path.extname(filePath)] || "application/octet-stream");
  });
}

function readBody(req, cb) {
  var chunks = [];
  req.on("data", function (c) { chunks.push(c); });
  req.on("end", function () { cb(Buffer.concat(chunks).toString("utf8")); });
}

function csvEscape(v) {
  v = String(v == null ? "" : v);
  return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
}

var scoring = require("./lib/scoring.js");

function parseQuery(req) {
  var query = {};
  var idx = req.url.indexOf("?");
  if (idx === -1) return query;
  req.url.slice(idx + 1).split("&").forEach(function (pair) {
    var kv = pair.split("=");
    if (kv[0]) {
      try { query[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1] || ""); }
      catch (e) { query[kv[0]] = kv[1] || ""; }
    }
  });
  return query;
}

// Filter leads for the inbox search box, date-range chips, and filtered CSV export.
// opts: { tier, q, days } — tier exact match; q matches name/service/location/contact;
// days keeps leads created within the last N days.
function filterLeads(leads, opts) {
  opts = opts || {};
  var q = String(opts.q || "").toLowerCase();
  var days = parseFloat(opts.days);
  var cutoff = isNaN(days) || days < 0 ? null : Date.now() - days * 86400000;
  return leads.filter(function (l) {
    if (opts.tier && opts.tier !== "all" && l.tier !== opts.tier) return false;
    if (cutoff && (!l.createdAt || new Date(l.createdAt).getTime() < cutoff)) return false;
    if (q) {
      var a = l.answers || {};
      var blob = [l.id, a.name, a.service, a.location, a.contact].join(" ").toLowerCase();
      if (blob.indexOf(q) === -1) return false;
    }
    return true;
  });
}

var server = http.createServer(function (req, res) {
  var url = req.url.split("?")[0];
  var query = parseQuery(req);

  if (url === "/" || url === "") { send(res, 302, "", "text/plain"); res.setHeader("Location", "/demo/"); res.end(); return; }

  // --- API ---
  if (url === "/api/lead" && req.method === "POST") {
    return readBody(req, function (body) {
      var lead;
      try { lead = JSON.parse(body); } catch (e) { return send(res, 400, "Invalid JSON"); }
      if (!lead || typeof lead !== "object") return send(res, 400, "Invalid lead");
      lead.id = lead.id || ("lead_" + Date.now().toString(36));
      lead.createdAt = lead.createdAt || new Date().toISOString();
      // Server-side re-score so stored tiers are trustworthy
      try {
        var r = scoring.scoreLead(lead.answers || {}, {});
        lead.score = r.score; lead.tier = r.tier; lead.reasons = r.reasons;
      } catch (e) { /* keep client values */ }
      var leads = readLeads();
      leads.push(lead);
      writeLeads(leads);
      send(res, 200, JSON.stringify({ ok: true, id: lead.id, tier: lead.tier }), "application/json");
    });
  }

  if (url === "/api/leads" && req.method === "GET") {
    return send(res, 200, JSON.stringify(readLeads()), "application/json");
  }

  if (url === "/api/export.csv" && req.method === "GET") {
    var leads = filterLeads(readLeads(), query);
    var rows = [["id", "createdAt", "name", "service", "timeline", "budget", "location", "contact", "tier", "score", "status", "reasons"]];
    leads.forEach(function (l) {
      var a = l.answers || {};
      rows.push([l.id, l.createdAt, a.name, a.service, a.timeline, a.budget, a.location, a.contact,
        l.tier, l.score, l.status || "new", (l.reasons || []).join(" | ")]);
    });
    var csv = rows.map(function (r) { return r.map(csvEscape).join(","); }).join("\n");
    res.writeHead(200, { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=leads.csv" });
    return res.end(csv);
  }

  if (url === "/api/score" && req.method === "POST") {
    return readBody(req, function (body) {
      var payload;
      try { payload = JSON.parse(body); } catch (e) { return send(res, 400, "Invalid JSON"); }
      var r = scoring.scoreLead(payload.answers || {}, payload.config || {});
      send(res, 200, JSON.stringify(r), "application/json");
    });
  }

  // Mark a lead new/contacted (follow-up status lives server-side).
  var leadMatch = url.match(/^\/api\/lead\/([^/]+)\/status$/);
  if (leadMatch && req.method === "POST") {
    return readBody(req, function (body) {
      var payload;
      try { payload = JSON.parse(body); } catch (e) { return send(res, 400, "Invalid JSON"); }
      var status = String(payload.status || "");
      if (status !== "new" && status !== "contacted") return send(res, 400, "status must be 'new' or 'contacted'");
      var leads = readLeads();
      var id = decodeURIComponent(leadMatch[1]);
      var lead = leads.filter(function (l) { return l.id === id; })[0];
      if (!lead) return send(res, 404, "Lead not found");
      lead.status = status;
      writeLeads(leads);
      send(res, 200, JSON.stringify({ ok: true, id: lead.id, status: lead.status }), "application/json");
    });
  }

  // Delete a lead (e.g. test chats, spam that slipped through).
  var delMatch = url.match(/^\/api\/lead\/([^/]+)$/);
  if (delMatch && req.method === "DELETE") {
    var leads = readLeads();
    var id = decodeURIComponent(delMatch[1]);
    var before = leads.length;
    leads = leads.filter(function (l) { return l.id !== id; });
    if (leads.length === before) return send(res, 404, "Lead not found");
    writeLeads(leads);
    return send(res, 200, JSON.stringify({ ok: true, id: id }), "application/json");
  }

  // --- Static ---
  var filePath = path.join(ROOT, decodeURIComponent(url));
  if (url.endsWith("/")) filePath = path.join(filePath, "index.html");
  // block path traversal
  if (!filePath.startsWith(ROOT)) return send(res, 403, "Forbidden");
  serveFile(res, filePath);
});

server.listen(PORT, function () {
  console.log("LeadQualify running at http://localhost:" + PORT + "/demo/");
});
