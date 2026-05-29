const GITHUB_API_VERSION = "2022-11-28";
const DEFAULT_CODESPACE_PORT = 443;
const ROUTE_WAIT_MS = 35000;
const ROUTE_POLL_INTERVAL_MS = 3000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/" && request.method === "GET") {
      return new Response(renderForm(), {
        headers: { "content-type": "text/html; charset=utf-8" }
      });
    }

    if (url.pathname !== "/wake") {
      return json({ ok: false, error: "not_found" }, 404);
    }

    if (request.method === "GET") {
      return new Response(renderForm(), {
        headers: { "content-type": "text/html; charset=utf-8" }
      });
    }

    if (request.method !== "POST") {
      return json({ ok: false, error: "method_not_allowed" }, 405);
    }

    const form = await readForm(request);
    const suppliedSecret = bearerSecret(request) || form.get("wake_secret") || "";

    if (!env.WAKE_SECRET || suppliedSecret !== env.WAKE_SECRET) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    const codespaceName = String(env.CODESPACE_NAME || "").trim();
    if (!codespaceName) {
      return json({ ok: false, error: "missing_codespace_name" }, 500);
    }

    if (!env.GITHUB_TOKEN) {
      return json({ ok: false, error: "missing_github_token" }, 500);
    }

    return startCodespace(codespaceName, env.GITHUB_TOKEN, env);
  }
};

async function startCodespace(name, token, env) {
  const endpoint = `https://api.github.com/user/codespaces/${encodeURIComponent(name)}/start`;
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": GITHUB_API_VERSION,
      "user-agent": "g2ray-codespace-waker"
    }
  });

  const text = await res.text();
  const body = parseBody(text);

  if (res.status === 402) {
    return json({
      ok: false,
      status: res.status,
      reason: "quota_or_billing_blocked",
      detail: githubErrorDetail(body)
    }, 402);
  }

  if (res.status === 401 || res.status === 403) {
    return json({
      ok: false,
      status: res.status,
      reason: "github_token_rejected_or_missing_scope",
      detail: githubErrorDetail(body)
    }, res.status);
  }

  if (res.status === 404) {
    return json({
      ok: false,
      status: res.status,
      reason: "codespace_not_found_or_token_cannot_access_it",
      detail: githubErrorDetail(body)
    }, 404);
  }

  const accepted = res.ok || res.status === 202 || res.status === 304 || res.status === 409;
  if (!accepted) {
    return json({
      ok: false,
      status: res.status,
      codespace: name,
      reason: "github_start_request_failed",
      detail: githubErrorDetail(body)
    }, 502);
  }

  const routeProbe = await waitForXhttpRoute(name, codespacePort(env));

  return json({
    ok: true,
    status: res.status,
    codespace: name,
    state: body && typeof body === "object" ? body.state || null : null,
    last_used_at: body && typeof body === "object" ? body.last_used_at || null : null,
    idle_timeout_minutes: body && typeof body === "object" ? body.idle_timeout_minutes || null : null,
    route_ready: routeProbe.usable,
    route_probe: routeProbe,
    message: routeProbe.usable
      ? "Codespace start request accepted and the XHTTP route is usable."
      : "Codespace start request accepted, but the XHTTP route is still settling. Wait and try again; if it stays 404, open the panel and use option 6."
  }, 200);
}

function bearerSecret(request) {
  const auth = request.headers.get("authorization") || "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

async function readForm(request) {
  const contentType = request.headers.get("content-type") || "";
  if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
    return request.formData();
  }
  return new FormData();
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
  const url = `https://${name}-${port}.app.github.dev/`;
  const startedAt = Date.now();
  const deadline = startedAt + ROUTE_WAIT_MS;
  let attempts = 0;
  let last = {
    url,
    usable: false,
    http_status: 0,
    latency_ms: null,
    attempts,
    waited_ms: 0,
    error: "not_checked"
  };

  while (Date.now() <= deadline) {
    attempts += 1;
    const probeStartedAt = Date.now();
    try {
      const res = await fetch(url, { method: "OPTIONS", redirect: "manual" });
      const latencyMs = Date.now() - probeStartedAt;
      last = {
        url,
        usable: res.status === 200,
        http_status: res.status,
        latency_ms: latencyMs,
        attempts,
        waited_ms: Date.now() - startedAt,
        error: null
      };
      if (last.usable) return last;
    } catch (error) {
      last = {
        url,
        usable: false,
        http_status: 0,
        latency_ms: Date.now() - probeStartedAt,
        attempts,
        waited_ms: Date.now() - startedAt,
        error: error && error.message ? String(error.message).slice(0, 160) : "probe_failed"
      };
    }

    if (Date.now() + ROUTE_POLL_INTERVAL_MS > deadline) break;
    await sleep(ROUTE_POLL_INTERVAL_MS);
  }

  return last;
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

function renderForm() {
  return `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>G2ray Codespace Waker</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
  label, input, button { display: block; width: 100%; box-sizing: border-box; }
  input, button { font: inherit; padding: .7rem; margin-top: .4rem; }
  button { margin-top: 1rem; cursor: pointer; }
  code { background: #eee; padding: .1rem .3rem; }
</style>
<h1>G2ray Codespace Waker</h1>
<p>This privately starts the configured GitHub Codespace. It cannot bypass GitHub quota, billing, deletion, or account restrictions.</p>
<p>After GitHub accepts the start request, this page also waits briefly for the <code>app.github.dev</code> XHTTP route to become usable. If the result says <code>route_ready: false</code> with HTTP 404, wait and try again, or open the panel and use option 6.</p>
<form method="post" action="/wake">
  <label>
    Wake secret
    <input name="wake_secret" type="password" autocomplete="off" required>
  </label>
  <button type="submit">Start Codespace</button>
</form>
<p>Browser use is recommended so the wake secret stays out of shell history. For CLI use, prefer an environment variable over typing the secret directly into the command.</p>
<pre><code>read -rsp "Wake secret: " WAKE_SECRET; echo
curl -X POST -H "Authorization: Bearer \${WAKE_SECRET}" https://YOUR_WORKER/wake
unset WAKE_SECRET</code></pre>`;
}
