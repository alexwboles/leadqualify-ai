/* LeadQualify — embeddable AI lead-qualifier chat widget.
 * One script tag embed:
 *   <script src="https://YOUR-HOST/widget/leadqualify.js"></script>
 *   <script>LeadQualify.init({ businessName: "Acme Plumbing" })</script>
 * Pure logic (scoreLead, isOpenNow) has zero DOM dependencies so this file
 * can also be required from Node: module.exports = { scoreLead, isOpenNow, DEFAULTS }.
 */
(function (root, factory) {
  if (typeof module !== "undefined" && module.exports) {
    module.exports = factory();
  } else {
    root.LeadQualify = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var DEFAULTS = {
    businessName: "Your Business",
    tagline: "We usually reply within a few minutes.",
    apiBase: "", // same-origin by default; set to your server URL when embedded elsewhere
    primaryColor: "#2563eb",
    businessHours: { open: 9, close: 17, days: [1, 2, 3, 4, 5] }, // Mon-Fri 9-5
    openMessage: "Hi there! Want a fast quote? Answer 5 quick questions and we'll get right back to you.",
    afterHoursMessage: "We're closed right now, but leave your details below and we'll call you first thing in the morning.",
    doneMessage: "Thanks {name}! We've got your details and will be in touch shortly.",
    doneAfterHours: "Thanks {name}! We're closed now, but you're first in line — we'll call you in the morning.",
    services: ["Repair", "Installation", "Maintenance", "Emergency", "Other"],
    budgetOptions: [
      { value: "under500", label: "Under $500" },
      { value: "500to2000", label: "$500 – $2,000" },
      { value: "over2000", label: "Over $2,000" },
      { value: "notsure", label: "Not sure yet" }
    ],
    timelineOptions: [
      { value: "asap", label: "ASAP / emergency" },
      { value: "this-week", label: "This week" },
      { value: "this-month", label: "This month" },
      { value: "browsing", label: "Just browsing" }
    ]
  };

  function mergeConfig(user) {
    var c = {}, k;
    for (k in DEFAULTS) c[k] = DEFAULTS[k];
    if (user) for (k in user) c[k] = user[k];
    return c;
  }

  // nowOverride lets tests inject a date (ISO string or Date).
  function isOpenNow(config, nowOverride) {
    var bh = config.businessHours || DEFAULTS.businessHours;
    var now = nowOverride ? new Date(nowOverride) : new Date();
    var day = now.getDay();
    var hour = now.getHours() + now.getMinutes() / 60;
    if (bh.days && bh.days.indexOf(day) === -1) return false;
    return hour >= bh.open && hour < bh.close;
  }

  function looksSpammy(text) {
    if (!text) return false;
    var t = String(text).toLowerCase();
    if (/(https?:\/\/|www\.|\.ru\b|\.xyz\b|viagra|cialis|casino|free money|click here|seo services)/.test(t)) return true;
    var stripped = t.replace(/[^a-z0-9]/g, "");
    if (stripped.length > 0 && stripped.length < 4) return true; // gibberish like "asdf"
    if (/(.)\1{5,}/.test(t)) return true; // aaaaaaaa
    return false;
  }

  // Pure scoring: answers = {name, service, timeline, budget, location, contact}
  // Returns { score: 0-100, tier: 'hot'|'warm'|'cold', reasons: [strings] }
  function scoreLead(answers, config) {
    answers = answers || {};
    var points = 0;
    var reasons = [];

    var timeline = String(answers.timeline || "").toLowerCase();
    if (/asap|emergency/.test(timeline)) {
      points += 40; reasons.push("Needs help ASAP — treat as urgent");
    } else if (/this-week|this week/.test(timeline)) {
      points += 25; reasons.push("Wants it done this week");
    } else if (/this-month|this month/.test(timeline)) {
      points += 15; reasons.push("Planning for this month");
    } else if (/browsing|just looking|research/.test(timeline)) {
      points += 2; reasons.push("Just browsing for now");
    } else if (timeline) {
      points += 10; reasons.push("Has a timeline in mind");
    }

    var budget = String(answers.budget || "").toLowerCase();
    if (/over2000|over \$?2/.test(budget)) {
      points += 20; reasons.push("Healthy budget signal");
    } else if (/500to2000|500/.test(budget)) {
      points += 15; reasons.push("Realistic mid-range budget");
    } else if (/under500|under/.test(budget)) {
      points += 8; reasons.push("Smaller budget — still worth a call");
    } else {
      points += 10; reasons.push("Budget to be discussed on the call");
    }

    if (answers.service && !/other/i.test(String(answers.service))) {
      points += 10; reasons.push("Clear service need: " + answers.service);
    } else if (answers.service) {
      points += 5; reasons.push("Service need described");
    }

    var contact = String(answers.contact || "");
    if (/@/.test(contact) || /\d{7,}/.test(contact.replace(/\D/g, ""))) {
      points += 10; reasons.push("Left contact info — reachable");
    }

    if (answers.location && String(answers.location).trim().length >= 2) {
      points += 5; reasons.push("In service area check: " + answers.location);
    }

    var blob = [answers.name, answers.service, answers.location, answers.contact]
      .map(function (x) { return String(x || ""); }).join(" ");
    var spam = looksSpammy(blob);
    if (spam) {
      points = Math.min(points, 5);
      reasons.unshift("Looks like spam — deprioritize");
    }

    var tier = points >= 70 ? "hot" : points >= 40 ? "warm" : "cold";
    if (points > 100) points = 100;
    return { score: points, tier: tier, reasons: reasons.slice(0, 4), spam: spam };
  }

  /* ---------------- Browser widget ---------------- */
  var api = { DEFAULTS: DEFAULTS, mergeConfig: mergeConfig, isOpenNow: isOpenNow, scoreLead: scoreLead, looksSpammy: looksSpammy };

  if (typeof window !== "undefined" && typeof document !== "undefined") {
    api.init = function (userConfig) {
      var config = mergeConfig(userConfig || readDataConfig());
      if (document.getElementById("lq-root")) return; // already mounted
      mountWidget(config);
    };

    // Allow <script src=".../leadqualify.js" data-lq-config='{"businessName":"Acme"}'>
    function readDataConfig() {
      try {
        var scripts = document.getElementsByTagName("script");
        for (var i = 0; i < scripts.length; i++) {
          var raw = scripts[i].getAttribute("data-lq-config");
          if (raw) return JSON.parse(raw);
        }
      } catch (e) { /* ignore */ }
      return {};
    }

    function mountWidget(config) {
      var open = isOpenNow(config);
      var root = document.createElement("div");
      root.id = "lq-root";
      root.innerHTML =
        '<button id="lq-bubble" aria-label="Chat with us">💬</button>' +
        '<div id="lq-panel" style="display:none">' +
          '<div id="lq-header"><div><strong id="lq-biz"></strong><div id="lq-status"></div></div>' +
          '<button id="lq-close" aria-label="Close">✕</button></div>' +
          '<div id="lq-messages"></div>' +
          '<div id="lq-quick"></div>' +
          '<div id="lq-inputrow"><input id="lq-input" placeholder="Type your answer…" autocomplete="off"/>' +
          '<button id="lq-send">➤</button></div>' +
        '</div>';
      document.body.appendChild(root);
      injectCss(config);

      var biz = document.getElementById("lq-biz");
      biz.textContent = config.businessName;
      var status = document.getElementById("lq-status");
      status.textContent = open ? "● Online now" : "● After hours — we reply in the morning";
      status.style.color = open ? "#4ade80" : "#fbbf24";

      var state = { step: 0, answers: {}, done: false, open: open };

      var steps = buildSteps(config);

      function buildSteps(c) {
        return [
          { id: "name", prompt: "Great — what's your name?", type: "text" },
          { id: "service", prompt: "What do you need help with?", type: "choice", options: c.services },
          { id: "timeline", prompt: "When do you need it done?", type: "choice",
            options: c.timelineOptions.map(function (o) { return { value: o.value, label: o.label }; }) },
          { id: "budget", prompt: "Rough budget range?", type: "choice",
            options: c.budgetOptions.map(function (o) { return { value: o.value, label: o.label }; }) },
          { id: "location", prompt: "What's your ZIP or town?", type: "text" },
          { id: "contact", prompt: "Best phone or email to reach you?", type: "text" }
        ];
      }

      var bubble = document.getElementById("lq-bubble");
      var panel = document.getElementById("lq-panel");
      bubble.style.background = config.primaryColor;
      bubble.onclick = function () {
        var showing = panel.style.display !== "none";
        panel.style.display = showing ? "none" : "flex";
        if (!showing && state.step === 0 && !state.started) {
          state.started = true;
          botSay(open ? config.openMessage : config.afterHoursMessage);
          setTimeout(askStep, 700);
        }
      };
      document.getElementById("lq-close").onclick = function () { panel.style.display = "none"; };

      var msgs = document.getElementById("lq-messages");
      var quick = document.getElementById("lq-quick");
      var input = document.getElementById("lq-input");
      var sendBtn = document.getElementById("lq-send");

      function scrollDown() { msgs.scrollTop = msgs.scrollHeight; }

      function botSay(text) {
        var d = document.createElement("div");
        d.className = "lq-msg lq-bot";
        d.textContent = text;
        msgs.appendChild(d); scrollDown();
      }
      function userSay(text) {
        var d = document.createElement("div");
        d.className = "lq-msg lq-user";
        d.textContent = text;
        msgs.appendChild(d); scrollDown();
      }
      function typing(cb, delay) {
        var d = document.createElement("div");
        d.className = "lq-msg lq-bot lq-typing";
        d.textContent = "…";
        msgs.appendChild(d); scrollDown();
        setTimeout(function () { d.remove(); cb(); }, delay || 600);
      }

      function askStep() {
        if (state.step >= steps.length) return finish();
        var s = steps[state.step];
        typing(function () {
          botSay(s.prompt);
          quick.innerHTML = "";
          if (s.type === "choice") {
            input.disabled = true;
            s.options.forEach(function (opt) {
              var label = typeof opt === "string" ? opt : opt.label;
              var value = typeof opt === "string" ? opt : opt.value;
              var b = document.createElement("button");
              b.className = "lq-chip";
              b.textContent = label;
              b.onclick = function () { answer(value, label); };
              quick.appendChild(b);
            });
          } else {
            input.disabled = false;
            input.focus();
          }
        });
      }

      function answer(value, label) {
        var s = steps[state.step];
        var display = label || value;
        if (s.type === "text") {
          value = String(value).trim();
          if (value.length < 2) { botSay("Could you give me just a little more detail?"); return; }
          display = value;
        }
        userSay(display);
        state.answers[s.id] = value;
        quick.innerHTML = "";
        input.value = "";
        state.step++;
        setTimeout(askStep, 400);
      }

      sendBtn.onclick = function () { if (!input.disabled && input.value.trim()) answer(input.value, null); };
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && !input.disabled && input.value.trim()) answer(input.value, null);
      });

      function finish() {
        state.done = true;
        var result = scoreLead(state.answers, config);
        var lead = {
          id: "lead_" + Date.now().toString(36),
          createdAt: new Date().toISOString(),
          business: config.businessName,
          afterHours: !state.open,
          answers: state.answers,
          score: result.score,
          tier: result.tier,
          reasons: result.reasons
        };
        persistLead(config, lead);
        typing(function () {
          var badge = result.tier === "hot" ? "🔥" : result.tier === "warm" ? "🟡" : "🔵";
          var msg = (state.open ? config.doneMessage : config.doneAfterHours)
            .replace("{name}", (state.answers.name || "there").split(" ")[0]);
          botSay(msg);
          var card = document.createElement("div");
          card.className = "lq-msg lq-bot";
          card.innerHTML = "";
          var t = document.createElement("div");
          t.innerHTML = "<strong>" + badge + " " + result.tier.toUpperCase() + " lead</strong> (" + result.score + "/100)";
          card.appendChild(t);
          var ul = document.createElement("ul");
          ul.className = "lq-reasons";
          result.reasons.forEach(function (r) {
            var li = document.createElement("li");
            li.textContent = r;
            ul.appendChild(li);
          });
          card.appendChild(ul);
          msgs.appendChild(card); scrollDown();
          var again = document.createElement("button");
          again.className = "lq-chip";
          again.textContent = "↺ Start over";
          again.onclick = function () {
            state.step = 0; state.answers = {}; state.done = false; state.started = true;
            msgs.innerHTML = ""; quick.innerHTML = "";
            botSay(state.open ? config.openMessage : config.afterHoursMessage);
            setTimeout(askStep, 700);
          };
          quick.innerHTML = "";
          quick.appendChild(again);
        }, 900);
      }

      function persistLead(config, lead) {
        var base = (config.apiBase || "").replace(/\/$/, "");
        if (base || window.location.protocol.indexOf("http") === 0) {
          try {
            var xhr = new XMLHttpRequest();
            xhr.open("POST", base + "/api/lead", true);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(JSON.stringify(lead));
          } catch (e) { saveLocal(lead); }
        } else {
          saveLocal(lead);
        }
      }
      function saveLocal(lead) {
        try {
          var arr = JSON.parse(localStorage.getItem("lq_leads") || "[]");
          arr.push(lead);
          localStorage.setItem("lq_leads", JSON.stringify(arr));
        } catch (e) { /* ignore */ }
      }
    }

    function injectCss(config) {
      if (document.getElementById("lq-style")) return;
      var css =
        "#lq-root{position:fixed;bottom:20px;right:20px;z-index:99999;font-family:system-ui,-apple-system,sans-serif}" +
        "#lq-bubble{width:60px;height:60px;border-radius:50%;border:none;font-size:26px;cursor:pointer;color:#fff;box-shadow:0 4px 14px rgba(0,0,0,.25)}" +
        "#lq-panel{position:absolute;bottom:72px;right:0;width:340px;max-width:calc(100vw - 40px);height:480px;max-height:70vh;background:#fff;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,.25);display:flex;flex-direction:column;overflow:hidden}" +
        "#lq-header{background:" + config.primaryColor + ";color:#fff;padding:12px 14px;display:flex;justify-content:space-between;align-items:center}" +
        "#lq-header strong{font-size:15px}#lq-status{font-size:11px;opacity:.9}" +
        "#lq-close{background:none;border:none;color:#fff;font-size:16px;cursor:pointer}" +
        "#lq-messages{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px;background:#f8fafc}" +
        ".lq-msg{max-width:85%;padding:9px 12px;border-radius:14px;font-size:14px;line-height:1.4}" +
        ".lq-bot{background:#fff;border:1px solid #e2e8f0;align-self:flex-start;border-bottom-left-radius:4px}" +
        ".lq-user{background:" + config.primaryColor + ";color:#fff;align-self:flex-end;border-bottom-right-radius:4px}" +
        ".lq-typing{opacity:.6}" +
        ".lq-reasons{margin:6px 0 0;padding-left:18px;font-size:13px}" +
        "#lq-quick{display:flex;flex-wrap:wrap;gap:6px;padding:8px 12px;background:#fff;border-top:1px solid #e2e8f0}" +
        ".lq-chip{background:#eef2ff;border:1px solid #c7d2fe;color:#3730a3;border-radius:20px;padding:7px 12px;font-size:13px;cursor:pointer}" +
        ".lq-chip:hover{background:#e0e7ff}" +
        "#lq-inputrow{display:flex;border-top:1px solid #e2e8f0;background:#fff}" +
        "#lq-input{flex:1;border:none;padding:12px;font-size:14px;outline:none}" +
        "#lq-input:disabled{background:#f1f5f9}" +
        "#lq-send{border:none;background:" + config.primaryColor + ";color:#fff;padding:0 16px;font-size:16px;cursor:pointer}";
      var st = document.createElement("style");
      st.id = "lq-style";
      st.textContent = css;
      document.head.appendChild(st);
    }
  }

  return api;
});
