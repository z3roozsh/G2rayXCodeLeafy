const GITHUB_API_VERSION = "2022-11-28";
const DEFAULT_CODESPACE_PORT = 443;
const GITHUB_STATE_WAIT_MS = 120000;
const GITHUB_STATE_POLL_INTERVAL_MS = 5000;
const ROUTE_WAIT_MS = 35000;
const ROUTE_POLL_INTERVAL_MS = 3000;
const HISTORY_KEY = "history";
const HISTORY_LIMIT = 50;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if ((url.pathname === "/" || url.pathname === "/wake") && request.method === "GET") {
      return html(renderDashboard());
    }

    if (url.pathname === "/api/wake" && request.method === "POST") {
      return handleWake(request, env);
    }

    if (url.pathname === "/api/health" && request.method === "POST") {
      return handleHealth(request, env);
    }

    if (url.pathname === "/api/history" && request.method === "POST") {
      return handleHistory(request, env);
    }

    if (url.pathname === "/wake" && request.method === "POST") {
      return handleWake(request, env);
    }

    if (url.pathname === "/wake" || url.pathname.startsWith("/api/")) {
      return json({ ok: false, error: "method_not_allowed" }, 405);
    }

    return json({ ok: false, error: "not_found" }, 404);
  }
};

async function handleWake(request, env) {
  const context = await requireAuthorizedContext(request, env);
  if (!context.ok) return json(context.body, context.status);

  const data = await startCodespaceData(context.codespaceName, context.token, env);
  const event = eventFromResult("wake", context.codespaceName, data);
  const historyRecorded = await recordHistory(env, {
    ...event,
    history_recorded_at: new Date().toISOString()
  });
  const notificationErrors = await sendNotifications(env, event);

  return json({
    ...data,
    history_enabled: Boolean(env.WAKER_KV),
    history_recorded: historyRecorded,
    notification_errors: notificationErrors
  }, responseStatusFor(data));
}

async function handleHealth(request, env) {
  const context = await requireAuthorizedContext(request, env);
  if (!context.ok) return json(context.body, context.status);

  const codespaceName = context.codespaceName;
  const status = await getCodespaceStatus(codespaceName, env.GITHUB_TOKEN);
  const routeProbe = await probeXhttpRoute(codespaceName, codespacePort(env));
  const data = {
    ...status,
    route_ready: routeProbe.usable,
    route_probe: routeProbe,
    next_action: nextActionForWake(status, routeProbe),
    message: healthMessage(status, routeProbe)
  };
  const event = eventFromResult("health", codespaceName, data);
  const historyRecorded = await recordHistory(env, {
    ...event,
    history_recorded_at: new Date().toISOString()
  });
  const notificationErrors = await sendNotifications(env, event);

  return json({
    ...data,
    history_enabled: Boolean(env.WAKER_KV),
    history_recorded: historyRecorded,
    notification_errors: notificationErrors
  }, responseStatusFor(data));
}

async function handleHistory(request, env) {
  const context = await requireAuthorizedContext(request, env);
  if (!context.ok) return json(context.body, context.status);

  const history = await readHistory(env);
  return json({
    ok: true,
    codespace: context.codespaceName,
    history_enabled: Boolean(env.WAKER_KV),
    history
  }, 200);
}

async function requireAuthorizedContext(request, env) {
  const suppliedSecret = await readSuppliedSecret(request);

  if (!env.WAKE_SECRET || suppliedSecret !== env.WAKE_SECRET) {
    return { ok: false, status: 401, body: { ok: false, error: "unauthorized" } };
  }

  const codespaceName = String(env.CODESPACE_NAME || "").trim();
  if (!codespaceName) {
    return { ok: false, status: 500, body: { ok: false, error: "missing_codespace_name" } };
  }

  if (!env.GITHUB_TOKEN) {
    return { ok: false, status: 500, body: { ok: false, error: "missing_github_token" } };
  }

  return {
    ok: true,
    codespaceName,
    token: env.GITHUB_TOKEN
  };
}

async function startCodespaceData(name, token, env) {
  const endpoint = `https://api.github.com/user/codespaces/${encodeURIComponent(name)}/start`;
  const res = await fetch(endpoint, {
    method: "POST",
    headers: githubHeaders(token)
  });

  const text = await res.text();
  const body = parseBody(text);

  if (res.status === 402) {
    return {
      ok: false,
      status: res.status,
      codespace: name,
      reason: "quota_or_billing_blocked",
      detail: githubErrorDetail(body),
      message: "GitHub quota or billing blocked the Codespace start request."
    };
  }

  if (res.status === 401 || res.status === 403) {
    return {
      ok: false,
      status: res.status,
      codespace: name,
      reason: "github_token_rejected_or_missing_scope",
      detail: githubErrorDetail(body),
      token_warning: "GitHub token rejected or expired",
      message: "GitHub token rejected or expired. Rotate the token or add the codespace scope."
    };
  }

  if (res.status === 404) {
    return {
      ok: false,
      status: res.status,
      codespace: name,
      reason: "codespace_not_found_or_token_cannot_access_it",
      detail: githubErrorDetail(body),
      message: "Codespace not found, or the token cannot access it."
    };
  }

  const accepted = res.ok || res.status === 202 || res.status === 304 || res.status === 409;
  if (!accepted) {
    return {
      ok: false,
      status: res.status,
      codespace: name,
      reason: "github_start_request_failed",
      detail: githubErrorDetail(body),
      message: "GitHub did not accept the Codespace start request."
    };
  }

  const readyState = await waitForCodespaceAvailable(name, token);
  if (!readyState.ok) return readyState;

  const routeProbe = await waitForXhttpRoute(name, codespacePort(env));

  return {
    ok: true,
    status: res.status,
    start_accepted: true,
    codespace: name,
    state: readyState.state || (body && typeof body === "object" ? body.state || null : null),
    pending_operation: readyState.pending_operation,
    last_used_at: readyState.last_used_at || (body && typeof body === "object" ? body.last_used_at || null : null),
    idle_timeout_minutes: readyState.idle_timeout_minutes || (body && typeof body === "object" ? body.idle_timeout_minutes || null : null),
    github_wait_ms: readyState.waited_ms,
    github_wait_attempts: readyState.attempts,
    route_ready: routeProbe.usable,
    route_probe: routeProbe,
    next_action: nextActionForWake(readyState, routeProbe),
    message: routeProbe.usable
      ? "Codespace start request accepted and the XHTTP route is usable."
      : "Codespace start request accepted, but the XHTTP route is still settling. Wait and try again; if it stays 404, open the panel and use option 6."
  };
}

async function waitForCodespaceAvailable(name, token) {
  const startedAt = Date.now();
  const deadline = startedAt + GITHUB_STATE_WAIT_MS;
  let attempts = 0;
  let last = {
    ok: false,
    status: 0,
    codespace: name,
    state: null,
    pending_operation: null,
    attempts,
    waited_ms: 0,
    reason: "not_checked",
    message: "Codespace state has not been checked yet."
  };

  while (Date.now() <= deadline) {
    attempts += 1;
    last = await getCodespaceStatus(name, token);
    last.attempts = attempts;
    last.waited_ms = Date.now() - startedAt;
    if (!last.ok) return last;
    if (isCodespaceAvailable(last)) return last;
    if (Date.now() + GITHUB_STATE_POLL_INTERVAL_MS > deadline) break;
    await sleep(GITHUB_STATE_POLL_INTERVAL_MS);
  }

  return {
    ...last,
    ok: false,
    reason: "codespace_state_not_ready",
    message: "GitHub accepted the start request, but the Codespace did not become Available before the wait timeout."
  };
}

async function getCodespaceStatus(codespaceName, token) {
  const endpoint = `https://api.github.com/user/codespaces/${encodeURIComponent(codespaceName)}`;
  const res = await fetch(endpoint, {
    method: "GET",
    headers: githubHeaders(token)
  });

  const body = parseBody(await res.text());

  if (res.status === 401 || res.status === 403) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: "github_token_rejected_or_missing_scope",
      detail: githubErrorDetail(body),
      token_warning: "GitHub token rejected or expired",
      message: "GitHub token rejected or expired. Rotate the token or add the codespace scope."
    };
  }

  if (!res.ok) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: res.status === 404
        ? "codespace_not_found_or_token_cannot_access_it"
        : "github_status_request_failed",
      detail: githubErrorDetail(body),
      message: "GitHub status request failed."
    };
  }

  return {
    ok: true,
    status: res.status,
    codespace: codespaceName,
    state: body && typeof body === "object" ? body.state || null : null,
    pending_operation: body && typeof body === "object" ? Boolean(body.pending_operation) : null,
    last_used_at: body && typeof body === "object" ? body.last_used_at || null : null,
    idle_timeout_minutes: body && typeof body === "object" ? body.idle_timeout_minutes || null : null,
    location: body && typeof body === "object" ? body.location || null : null,
    message: "Codespace status loaded."
  };
}

function githubHeaders(token) {
  return {
    accept: "application/vnd.github+json",
    authorization: `Bearer ${token}`,
    "x-github-api-version": GITHUB_API_VERSION,
    "user-agent": "g2ray-codespace-waker"
  };
}

function responseStatusFor(data) {
  if (data.ok) return 200;
  if ([401, 402, 403, 404].includes(data.status)) return data.status;
  return 502;
}

function isCodespaceAvailable(status) {
  const state = String(status && status.state || "").toLowerCase();
  return Boolean(status && status.ok && (state === "available" || state === "running") && status.pending_operation !== true);
}

function nextActionForWake(status, routeProbe) {
  if (!status.ok) return "Open GitHub Codespaces or rotate the GitHub token, then try the Worker again.";
  if (!isCodespaceAvailable(status)) return "Wait for GitHub to finish starting the Codespace, then press Check Health.";
  if (routeProbe.usable) return "Try the same VLESS config again.";
  if (routeProbe.http_status === 404) return "Open the panel, check option 14 Diagnostics, then use option 6 Force Reconnect if the route stays 404.";
  if (routeProbe.http_status === 0) return "The app.github.dev route did not resolve or answer. Open the Codespace once, then check port 443 visibility and panel diagnostics.";
  return "Check panel option 14 Diagnostics; if XHTTP is not usable, use option 6 Force Reconnect.";
}

function healthMessage(status, routeProbe) {
  if (status.token_warning) return status.message;
  if (!status.ok) return status.message || "GitHub status is not available.";
  if (routeProbe.usable) return "Codespace is available and the XHTTP route is usable.";
  if (routeProbe.http_status === 404) {
    return "Codespace exists, but the app.github.dev route is still settling or not routed.";
  }
  if (routeProbe.http_status === 0) {
    return "Codespace status loaded, but the app.github.dev route did not answer.";
  }
  return "Codespace status loaded, but the XHTTP route is not usable yet.";
}

function eventFromResult(kind, codespace, data) {
  return {
    ts: new Date().toISOString(),
    kind,
    ok: Boolean(data.ok),
    codespace,
    github_status: data.status || null,
    state: data.state || null,
    route_ready: data.route_ready === true,
    route_http_status: data.route_probe ? data.route_probe.http_status : null,
    route_latency_ms: data.route_probe ? data.route_probe.latency_ms : null,
    reason: data.reason || null,
    token_warning: data.token_warning || null,
    message: data.message || null
  };
}

async function recordHistory(env, event) {
  if (!env.WAKER_KV) return false;

  try {
    const existing = await readHistory(env);
    const next = [event, ...existing].slice(0, HISTORY_LIMIT);
    await env.WAKER_KV.put(HISTORY_KEY, JSON.stringify(next));
    return true;
  } catch {
    return false;
  }
}

async function readHistory(env) {
  if (!env.WAKER_KV) return [];

  try {
    const text = await env.WAKER_KV.get(HISTORY_KEY);
    const parsed = text ? JSON.parse(text) : [];
    return Array.isArray(parsed) ? parsed.slice(0, HISTORY_LIMIT) : [];
  } catch {
    return [];
  }
}

async function sendNotifications(env, event) {
  if (!shouldNotify(event)) return [];

  const text = notificationText(event);
  const tasks = [];

  if (env.DISCORD_WEBHOOK_URL) {
    tasks.push(
      fetch(env.DISCORD_WEBHOOK_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ content: text })
      }).then((res) => res.ok ? null : `discord_http_${res.status}`)
        .catch((error) => `discord_${shortError(error)}`)
    );
  }

  if (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID) {
    const endpoint = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`;
    tasks.push(
      fetch(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chat_id: env.TELEGRAM_CHAT_ID,
          text,
          disable_web_page_preview: true
        })
      }).then((res) => res.ok ? null : `telegram_http_${res.status}`)
        .catch((error) => `telegram_${shortError(error)}`)
    );
  }

  const results = await Promise.all(tasks);
  return results.filter(Boolean);
}

function shouldNotify(event) {
  if (event.reason === "github_token_rejected_or_missing_scope") return true;
  if (event.kind !== "wake") return false;
  if (event.route_ready) return true;
  return event.route_http_status === 404 || !event.ok;
}

function notificationText(event) {
  const route = event.route_http_status
    ? `route HTTP ${event.route_http_status}${event.route_latency_ms === null ? "" : `, ${event.route_latency_ms}ms`}`
    : "route not checked";
  return [
    `G2ray Codespace Waker: ${event.kind}`,
    `codespace=${event.codespace}`,
    `ok=${event.ok}`,
    `state=${event.state || "unknown"}`,
    `route_ready=${event.route_ready}`,
    route,
    event.reason ? `reason=${event.reason}` : null,
    event.token_warning ? `warning=${event.token_warning}` : null,
    event.message ? `message=${event.message}` : null
  ].filter(Boolean).join("\n");
}

function shortError(error) {
  return error && error.message ? String(error.message).slice(0, 80) : "failed";
}

async function readSuppliedSecret(request) {
  const auth = bearerSecret(request);
  if (auth) return auth;

  const contentType = request.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    try {
      const body = await request.json();
      return body && typeof body === "object" ? String(body.wake_secret || "") : "";
    } catch {
      return "";
    }
  }

  if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
    try {
      const form = await request.formData();
      return String(form.get("wake_secret") || "");
    } catch {
      return "";
    }
  }

  return "";
}

function bearerSecret(request) {
  const auth = request.headers.get("authorization") || "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

function parseBody(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text.slice(0, 1000);
  }
}

function githubErrorDetail(body) {
  if (!body || typeof body !== "object") return null;
  return {
    message: body.message || null,
    documentation_url: body.documentation_url || null
  };
}

function codespacePort(env) {
  const value = Number.parseInt(String(env.CODESPACE_PORT || DEFAULT_CODESPACE_PORT), 10);
  return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_CODESPACE_PORT;
}

async function waitForXhttpRoute(name, port) {
  const startedAt = Date.now();
  const deadline = startedAt + ROUTE_WAIT_MS;
  let attempts = 0;
  let last = {
    url: routeUrl(name, port),
    usable: false,
    http_status: 0,
    latency_ms: null,
    attempts,
    waited_ms: 0,
    error: "not_checked"
  };

  while (Date.now() <= deadline) {
    attempts += 1;
    last = await probeXhttpRoute(name, port, attempts, startedAt);
    if (last.usable) return last;

    if (Date.now() + ROUTE_POLL_INTERVAL_MS > deadline) break;
    await sleep(ROUTE_POLL_INTERVAL_MS);
  }

  return last;
}

async function probeXhttpRoute(name, port, attempts = 1, startedAt = Date.now()) {
  const url = routeUrl(name, port);
  const probeStartedAt = Date.now();
  try {
    const res = await fetch(url, { method: "OPTIONS", redirect: "manual" });
    return {
      url,
      usable: isRouteStatusUsable(res.status),
      http_status: res.status,
      latency_ms: Date.now() - probeStartedAt,
      attempts,
      waited_ms: Date.now() - startedAt,
      error: null
    };
  } catch (error) {
    return {
      url,
      usable: false,
      http_status: 0,
      latency_ms: Date.now() - probeStartedAt,
      attempts,
      waited_ms: Date.now() - startedAt,
      error: shortError(error)
    };
  }
}

function routeUrl(name, port) {
  return `https://${name}-${port}.app.github.dev/`;
}

function isRouteStatusUsable(status) {
  return status === 200 || status === 400;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function html(markup, status = 200) {
  return new Response(markup, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function renderDashboard() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>G2ray Codespace Waker</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #101214;
    --panel: #181c20;
    --panel-2: #20262c;
    --text: #eef2f4;
    --muted: #9ca8b3;
    --good: #22c55e;
    --warn: #f59e0b;
    --bad: #ef4444;
    --line: #303842;
    --accent: #38bdf8;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    line-height: 1.45;
  }
  main {
    width: min(900px, 100%);
    margin: 0 auto;
    padding: 20px;
  }
  h1 { margin: 0 0 6px; font-size: 30px; letter-spacing: 0; }
  h2 { margin: 0 0 12px; font-size: 18px; letter-spacing: 0; }
  p { margin: 0 0 14px; color: var(--muted); }
  .card {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 16px;
    margin: 14px 0;
  }
  label { display: block; color: var(--muted); font-size: 14px; margin-bottom: 8px; }
  input {
    width: 100%;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #0b0d0f;
    color: var(--text);
    font: inherit;
    padding: 12px;
  }
  .actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    margin-top: 12px;
  }
  button {
    min-height: 46px;
    border: 0;
    border-radius: 6px;
    background: var(--panel-2);
    color: var(--text);
    font: inherit;
    font-weight: 700;
    cursor: pointer;
  }
  button.primary { background: var(--accent); color: #061017; }
  button:disabled { cursor: wait; opacity: .6; }
  .grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
  }
  .metric {
    background: var(--panel-2);
    border-radius: 6px;
    padding: 12px;
    min-height: 78px;
  }
  .metric span { display: block; color: var(--muted); font-size: 12px; }
  .metric strong { display: block; margin-top: 6px; font-size: 18px; word-break: break-word; }
  .good { color: var(--good); }
  .warn { color: var(--warn); }
  .bad { color: var(--bad); }
  ol { margin: 0; padding-left: 22px; color: var(--muted); }
  li.active { color: var(--accent); }
  li.done { color: var(--good); }
  pre {
    white-space: pre-wrap;
    word-break: break-word;
    background: #0b0d0f;
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 12px;
    overflow: auto;
  }
  .history {
    display: grid;
    gap: 8px;
  }
  .event {
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 10px;
    color: var(--muted);
  }
  @media (max-width: 640px) {
    main { padding: 14px; }
    h1 { font-size: 25px; }
    .actions, .grid { grid-template-columns: 1fr; }
    button { min-height: 52px; }
  }
</style>
</head>
<body>
<main>
  <h1>G2ray Codespace Waker</h1>
  <p>Private mobile wake UI for one GitHub Codespace. It starts the Codespace, checks the app.github.dev XHTTP route, and shows whether configs should be usable.</p>

  <section class="card">
    <h2>Start</h2>
    <label for="secret">Wake secret</label>
    <input id="secret" type="password" autocomplete="off" placeholder="Paste WAKE_SECRET">
    <div class="actions">
      <button id="start" class="primary" type="button">Start Codespace</button>
      <button id="health" type="button">Check Health</button>
      <button id="history" type="button">Load History</button>
      <button id="copy" type="button">Copy Status</button>
    </div>
  </section>

  <section class="card">
    <h2>Health dashboard</h2>
    <div class="grid">
      <div class="metric"><span>GitHub state</span><strong id="githubState">Not checked</strong></div>
      <div class="metric"><span>Route</span><strong id="routeState">Not checked</strong></div>
      <div class="metric"><span>Latency</span><strong id="latency">Not checked</strong></div>
      <div class="metric"><span>Idle timeout</span><strong id="idleTimeout">Not checked</strong></div>
      <div class="metric"><span>Last used</span><strong id="lastUsed">Not checked</strong></div>
      <div class="metric"><span>Last failure</span><strong id="lastFailure">None seen</strong></div>
      <div class="metric"><span>Next action</span><strong id="nextAction">Not checked</strong></div>
    </div>
  </section>

  <section class="card">
    <h2>Progress</h2>
    <ol id="progress">
      <li>Waiting for a wake or health check</li>
    </ol>
  </section>

  <section class="card">
    <h2>Result</h2>
    <pre id="result">No result yet.</pre>
  </section>

  <section class="card">
    <h2>History</h2>
    <p id="historyNote">History appears when WAKER_KV is configured.</p>
    <div id="historyList" class="history"></div>
  </section>
</main>

<script>
const secretInput = document.getElementById("secret");
const resultEl = document.getElementById("result");
const progressEl = document.getElementById("progress");
const historyList = document.getElementById("historyList");
const historyNote = document.getElementById("historyNote");
let lastStatusText = "";
let polling = false;

document.getElementById("start").addEventListener("click", startWake);
document.getElementById("health").addEventListener("click", checkHealth);
document.getElementById("history").addEventListener("click", loadHistory);
document.getElementById("copy").addEventListener("click", copyStatus);

function wakeSecret() {
  return secretInput.value.trim();
}

function setButtons(disabled) {
  for (const id of ["start", "health", "history", "copy"]) {
    document.getElementById(id).disabled = disabled;
  }
}

function setProgress(items, activeIndex) {
  progressEl.innerHTML = "";
  items.forEach((item, index) => {
    const li = document.createElement("li");
    li.textContent = item;
    if (index < activeIndex) li.className = "done";
    if (index === activeIndex) li.className = "active";
    progressEl.appendChild(li);
  });
}

async function callApi(path) {
  const secret = wakeSecret();
  if (!secret) throw new Error("Wake secret is required.");
  const res = await fetch(path, {
    method: "POST",
    headers: {
      "authorization": "Bearer " + secret,
      "accept": "application/json"
    }
  });
  const data = await res.json().catch(() => ({ ok: false, error: "invalid_json_response" }));
  if (!res.ok && !data.status) data.status = res.status;
  return data;
}

async function startWake() {
  polling = true;
  setButtons(true);
  const steps = ["Authenticating wake secret", "Calling GitHub start API", "Codespace started", "Checking XHTTP route", "Route ready or settling"];
  setProgress(steps, 0);
  try {
    setProgress(steps, 1);
    const data = await callApi("/api/wake");
    setProgress(steps, data.ok ? 4 : 1);
    renderResult(data);
    if (shouldPollRoute(data)) {
      setTimeout(checkHealth, 5000);
    }
  } catch (error) {
    renderError(error);
  } finally {
    setButtons(false);
  }
}

async function checkHealth() {
  setButtons(true);
  setProgress(["Authenticating wake secret", "Checking GitHub state", "Probing XHTTP route", "Showing result"], 1);
  try {
    const data = await callApi("/api/health");
    setProgress(["Authenticating wake secret", "Checking GitHub state", "Probing XHTTP route", "Showing result"], 3);
    renderResult(data);
    if (polling && shouldPollRoute(data)) {
      setTimeout(checkHealth, 5000);
    }
  } catch (error) {
    renderError(error);
  } finally {
    setButtons(false);
  }
}

async function loadHistory() {
  setButtons(true);
  try {
    const data = await callApi("/api/history");
    renderHistory(data);
  } catch (error) {
    renderError(error);
  } finally {
    setButtons(false);
  }
}

async function copyStatus() {
  if (!lastStatusText) return;
  try {
    await navigator.clipboard.writeText(lastStatusText);
  } catch (error) {
    renderError(error);
  }
}

function shouldPollRoute(data) {
  return Boolean(data && data.ok && data.route_ready !== true && data.route_probe);
}

function renderResult(data) {
  const route = data.route_probe || {};
  const routeReady = data.route_ready === true;
  const tokenRejected = data.token_warning || data.reason === "github_token_rejected_or_missing_scope";
  document.getElementById("githubState").textContent = data.state || (data.ok ? "Available" : "Problem");
  document.getElementById("routeState").textContent = routeReady ? "Route ready" : route.http_status ? "HTTP " + route.http_status : "Not reachable";
  document.getElementById("routeState").className = routeReady ? "good" : route.http_status === 404 ? "warn" : "bad";
  document.getElementById("latency").textContent = route.latency_ms == null ? "Unknown" : route.latency_ms + "ms";
  document.getElementById("idleTimeout").textContent = data.idle_timeout_minutes ? data.idle_timeout_minutes + " minutes" : "Unknown";
  document.getElementById("lastUsed").textContent = data.last_used_at || "Unknown";
  document.getElementById("lastFailure").textContent = tokenRejected
    ? "GitHub token rejected or expired"
    : data.ok ? "None seen" : (data.reason || data.error || "Unknown failure");
  document.getElementById("nextAction").textContent = data.next_action || "No action suggested";
  resultEl.textContent = JSON.stringify(data, null, 2);
  lastStatusText = [
    "G2ray Codespace Waker",
    "ok=" + Boolean(data.ok),
    "codespace=" + (data.codespace || "unknown"),
    "state=" + (data.state || "unknown"),
    "route_ready=" + routeReady,
    "route_http_status=" + (route.http_status || "unknown"),
    "latency_ms=" + (route.latency_ms == null ? "unknown" : route.latency_ms),
    "next_action=" + (data.next_action || ""),
    "message=" + (data.message || data.error || "")
  ].join("\\n");
  if (routeReady) polling = false;
}

function renderHistory(data) {
  historyList.innerHTML = "";
  historyNote.textContent = data.history_enabled
    ? "Recent wake and health events."
    : "History is disabled because WAKER_KV is not configured.";
  for (const event of data.history || []) {
    const item = document.createElement("div");
    item.className = "event";
    item.textContent = [
      event.ts,
      event.kind,
      "ok=" + event.ok,
      "route_ready=" + event.route_ready,
      "http=" + (event.route_http_status || "unknown"),
      event.reason || ""
    ].filter(Boolean).join(" | ");
    historyList.appendChild(item);
  }
}

function renderError(error) {
  resultEl.textContent = JSON.stringify({
    ok: false,
    error: error && error.message ? error.message : "request_failed"
  }, null, 2);
}
</script>
</body>
</html>`;
}
