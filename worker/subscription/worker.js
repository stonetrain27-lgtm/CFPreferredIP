/**
 * CFPreferredIP standalone plain-text subscription Worker.
 * Required bindings:
 *   SUBSCRIPTION_KV: KV namespace
 *   SUB_PATH_KEY: secret text, random 32+ characters, the public GET path
 *   UPDATE_SECRET: secret text, independent random secret for authenticated PUT
 *   SUBSCRIPTION_KV_KEY: plain text key name, e.g. "subscription-content"
 */
const MAX_BODY_BYTES = 512 * 1024;

const noStore = {
  "Cache-Control": "no-store, private, max-age=0",
  "Pragma": "no-cache",
  "X-Content-Type-Options": "nosniff",
};

function constantTimeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) return false;
  let mismatch = 0;
  for (let i = 0; i < left.length; i++) mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return mismatch === 0;
}

const notFound = () => new Response("Not Found", {
  status: 404,
  headers: { ...noStore, "Content-Type": "text/plain; charset=utf-8" },
});


// ---------------------------------------------------------------------------
// Multi-client output. KV always stores one node link per line; the format is
// chosen per request: ?target=clash|singbox|surge|base64|plain, or by User-Agent.
// ---------------------------------------------------------------------------
const b64enc = (s) => {
  let bin = "";
  for (const b of new TextEncoder().encode(s)) bin += String.fromCharCode(b);
  return btoa(bin);
};
const b64dec = (s) => {
  let t = s.trim().replace(/-/g, "+").replace(/_/g, "/");
  while (t.length % 4) t += "=";
  return new TextDecoder().decode(Uint8Array.from(atob(t), (c) => c.charCodeAt(0)));
};
const unesc = (s) => { try { return decodeURIComponent(s); } catch { return s; } };

function parseLink(line) {
  const m = line.trim().match(/^([a-z0-9]+):\/\/(.*)$/i);
  if (!m) return null;
  const scheme = m[1].toLowerCase();
  let rest = m[2];
  if (scheme === "vmess") {
    try {
      const o = JSON.parse(b64dec(rest.split("#")[0]));
      return {
        type: "vmess", name: String(o.ps || "vmess"), server: String(o.add), port: Number(o.port),
        uuid: o.id, aid: Number(o.aid || 0), cipher: o.scy || "auto",
        network: String(o.net || "tcp").toLowerCase(), tls: o.tls === "tls",
        sni: o.sni || "", host: o.host || "", path: o.path || "/", alpn: o.alpn || "", fp: o.fp || "",
      };
    } catch { return null; }
  }
  if (!["vless", "trojan", "ss", "hysteria2", "hy2"].includes(scheme)) return null;
  let name = "";
  const h = rest.indexOf("#");
  if (h >= 0) { name = unesc(rest.slice(h + 1)); rest = rest.slice(0, h); }
  let query = "";
  const q = rest.indexOf("?");
  if (q >= 0) { query = rest.slice(q + 1); rest = rest.slice(0, q); }
  const slash = rest.indexOf("/");
  if (slash >= 0) rest = rest.slice(0, slash);
  if (scheme === "ss" && !rest.includes("@")) { // legacy ss://BASE64(method:pw@host:port)
    try { rest = b64dec(rest); } catch { return null; }
  }
  const at = rest.lastIndexOf("@");
  const userinfo = at >= 0 ? rest.slice(0, at) : "";
  const hostport = at >= 0 ? rest.slice(at + 1) : rest;
  const hp = hostport.match(/^\[(.+)\]:(\d+)$/) || hostport.match(/^([^:]+):(\d+)$/);
  if (!hp) return null;
  const params = new URLSearchParams(query);
  const p = { name: name || scheme, server: hp[1], port: Number(hp[2]) };
  if (scheme === "ss") {
    let u = unesc(userinfo);
    if (!u.includes(":")) { try { u = b64dec(u); } catch { return null; } }
    const i = u.indexOf(":");
    if (i < 0) return null;
    return { ...p, type: "ss", cipher: u.slice(0, i), password: u.slice(i + 1) };
  }
  if (scheme === "hysteria2" || scheme === "hy2") {
    return { ...p, type: "hy2", password: unesc(userinfo), sni: params.get("sni") || "" };
  }
  const security = (params.get("security") || (scheme === "trojan" ? "tls" : "none")).toLowerCase();
  if (security === "reality") return null;
  return {
    ...p, type: scheme, [scheme === "vless" ? "uuid" : "password"]: unesc(userinfo),
    network: (params.get("type") || "tcp").toLowerCase(), tls: security === "tls",
    sni: params.get("sni") || params.get("peer") || "", host: params.get("host") || "",
    path: params.get("path") || "/", alpn: params.get("alpn") || "", fp: params.get("fp") || "",
    flow: params.get("flow") || "", serviceName: params.get("serviceName") || "",
  };
}

function parseAll(content) {
  const seen = new Set();
  const out = [];
  for (const line of content.split(/\r?\n/)) {
    const p = parseLink(line);
    if (!p || !p.server || !p.port) continue;
    let n = p.name, i = 1;
    while (seen.has(n)) n = `${p.name}-${++i}`;
    seen.add(n);
    out.push({ ...p, name: n });
  }
  return out;
}

function clashNode(p) {
  const n = { name: p.name, type: p.type === "hy2" ? "hysteria2" : p.type, server: p.server, port: p.port, udp: true };
  if (p.type === "ss") return { ...n, cipher: p.cipher, password: p.password };
  if (p.type === "hy2") { n.password = p.password; if (p.sni) n.sni = p.sni; return n; }
  if (p.type === "vless") { n.uuid = p.uuid; if (p.flow) n.flow = p.flow; }
  else if (p.type === "vmess") { n.uuid = p.uuid; n.alterId = p.aid || 0; n.cipher = p.cipher || "auto"; }
  else n.password = p.password;
  if (p.tls) {
    n.tls = true;
    if (p.sni) n[p.type === "trojan" ? "sni" : "servername"] = p.sni;
    if (p.fp) n["client-fingerprint"] = p.fp;
    if (p.alpn) n.alpn = p.alpn.split(",");
  }
  const host = p.host || p.sni;
  if (p.network === "ws" || p.network === "httpupgrade") {
    n.network = "ws";
    n["ws-opts"] = { path: p.path, ...(host ? { headers: { Host: host } } : {}),
      ...(p.network === "httpupgrade" ? { "v2ray-http-upgrade": true } : {}) };
  } else if (p.network === "grpc") {
    n.network = "grpc";
    n["grpc-opts"] = { "grpc-service-name": p.serviceName };
  } else if (p.network !== "tcp") return null; // xhttp etc. are not supported by Clash
  return n;
}

function toClash(proxies) {
  const nodes = proxies.map(clashNode).filter(Boolean);
  const names = nodes.map((n) => n.name);
  const L = ["mixed-port: 7890", "allow-lan: false", "mode: rule", "log-level: info", "proxies:"];
  for (const n of nodes) L.push("  - " + JSON.stringify(n));
  L.push("proxy-groups:",
    "  - " + JSON.stringify({ name: "优选", type: "select", proxies: ["自动选择", ...names] }),
    "  - " + JSON.stringify({ name: "自动选择", type: "url-test", proxies: names,
      url: "https://www.gstatic.com/generate_204", interval: 300 }),
    "rules:", '  - "MATCH,优选"');
  return L.join("\n") + "\n";
}

function singboxNode(p) {
  const o = { tag: p.name, server: p.server, server_port: p.port };
  if (p.type === "ss") return { type: "shadowsocks", ...o, method: p.cipher, password: p.password };
  if (p.type === "hy2") return { type: "hysteria2", ...o, password: p.password,
    tls: { enabled: true, ...(p.sni ? { server_name: p.sni } : {}) } };
  o.type = p.type;
  if (p.type === "vless") { o.uuid = p.uuid; if (p.flow) o.flow = p.flow; }
  else if (p.type === "vmess") { o.uuid = p.uuid; o.alter_id = p.aid || 0; o.security = p.cipher || "auto"; }
  else o.password = p.password;
  if (p.tls) {
    o.tls = { enabled: true, ...(p.sni ? { server_name: p.sni } : {}),
      ...(p.fp ? { utls: { enabled: true, fingerprint: p.fp } } : {}),
      ...(p.alpn ? { alpn: p.alpn.split(",") } : {}) };
  }
  const host = p.host || p.sni;
  if (p.network === "ws") {
    o.transport = { type: "ws", path: p.path, ...(host ? { headers: { Host: host } } : {}) };
  } else if (p.network === "httpupgrade") {
    o.transport = { type: "httpupgrade", path: p.path, ...(host ? { host } : {}) };
  } else if (p.network === "grpc") {
    o.transport = { type: "grpc", service_name: p.serviceName };
  } else if (p.network !== "tcp") return null; // xhttp is not supported by sing-box
  return o;
}

function toSingbox(proxies) {
  const nodes = proxies.map(singboxNode).filter(Boolean);
  const tags = nodes.map((n) => n.tag);
  return JSON.stringify({
    log: { level: "info" },
    outbounds: [
      { type: "selector", tag: "优选", outbounds: ["自动选择", ...tags], default: "自动选择" },
      { type: "urltest", tag: "自动选择", outbounds: tags, url: "https://www.gstatic.com/generate_204", interval: "5m" },
      ...nodes,
      { type: "direct", tag: "direct" },
    ],
    route: { final: "优选" },
  }, null, 2) + "\n";
}

function surgeNode(p) {
  const nm = p.name.replace(/[,=]/g, "-");
  if (p.type === "ss") return `${nm} = ss, ${p.server}, ${p.port}, encrypt-method=${p.cipher}, password=${p.password}`;
  if (p.type !== "vmess" && p.type !== "trojan") return null; // Surge has no VLESS
  if (p.network !== "tcp" && p.network !== "ws") return null;
  const a = [nm + " = " + p.type, p.server, String(p.port)];
  a.push(p.type === "vmess" ? `username=${p.uuid}` : `password=${p.password}`);
  if (p.tls || p.type === "trojan") { if (p.sni) a.push(`sni=${p.sni}`); }
  if (p.type === "vmess" && p.tls) a.push("tls=true");
  if (p.network === "ws") {
    a.push("ws=true", `ws-path=${p.path}`);
    const host = p.host || p.sni;
    if (host) a.push(`ws-headers=Host:${host}`);
  }
  return a.join(", ");
}

function toSurge(proxies) {
  const lines = proxies.map(surgeNode).filter(Boolean);
  const names = lines.map((l) => l.split(" = ")[0]);
  return ["[General]", "loglevel = notify", "", "[Proxy]", ...lines, "",
    "[Proxy Group]", `优选 = select, 自动选择, ${names.join(", ")}`,
    `自动选择 = url-test, ${names.join(", ")}, url=http://www.gstatic.com/generate_204, interval=300`, "",
    "[Rule]", "FINAL,优选"].join("\n") + "\n";
}

function pickTarget(url, request) {
  const map = { clash: "clash", mihomo: "clash", meta: "clash", stash: "clash",
    singbox: "singbox", "sing-box": "singbox", surge: "surge",
    base64: "base64", v2ray: "base64", plain: "plain" };
  const t = map[(url.searchParams.get("target") || "").toLowerCase()];
  if (t) return t;
  const ua = (request.headers.get("User-Agent") || "").toLowerCase();
  if (/clash|mihomo|stash|flclash/.test(ua)) return "clash";
  if (/sing-box|sfa\/|sfi\/|sfm\//.test(ua)) return "singbox";
  if (/surge/.test(ua)) return "surge";
  return "plain";
}

function render(content, target) {
  if (target === "plain") return { body: content, type: "text/plain; charset=utf-8" };
  if (target === "base64") return { body: b64enc(content), type: "text/plain; charset=utf-8" };
  const proxies = parseAll(content);
  if (target === "clash") return { body: toClash(proxies), type: "text/yaml; charset=utf-8" };
  if (target === "singbox") return { body: toSingbox(proxies), type: "application/json; charset=utf-8" };
  return { body: toSurge(proxies), type: "text/plain; charset=utf-8" };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const keyName = env.SUBSCRIPTION_KV_KEY || "subscription-content";

    // Private write endpoint: never accept writes through the public read path.
    if (request.method === "PUT" && url.pathname === "/_update") {
      const auth = request.headers.get("Authorization") || "";
      if (!env.UPDATE_SECRET || !constantTimeEqual(auth, `Bearer ${env.UPDATE_SECRET}`)) return notFound();
      const rawLength = request.headers.get("Content-Length");
      if (rawLength !== null) {
        // Reject malformed/negative lengths instead of treating them as zero.
        if (!/^\d+$/.test(rawLength)) {
          return new Response("Invalid Content-Length", { status: 400, headers: noStore });
        }
        if (Number(rawLength) > MAX_BODY_BYTES) {
          return new Response("Payload Too Large", { status: 413, headers: noStore });
        }
      }
      if (!request.body) return new Response("Empty Body", { status: 400, headers: noStore });
      // Bound memory even when the client omits Content-Length or uses streaming transfer.
      const reader = request.body.getReader();
      const chunks = [];
      let total = 0;
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          total += value.byteLength;
          if (total > MAX_BODY_BYTES) {
            try { await reader.cancel(); } catch {}
            return new Response("Payload Too Large", { status: 413, headers: noStore });
          }
          chunks.push(value);
        }
      } catch {
        try { await reader.cancel(); } catch {}
        return new Response("Invalid Body", { status: 400, headers: noStore });
      }
      if (rawLength !== null && Number(rawLength) !== total) {
        return new Response("Content-Length Mismatch", { status: 400, headers: noStore });
      }
      const body = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) {
        body.set(chunk, offset);
        offset += chunk.byteLength;
      }
      if (!env.SUBSCRIPTION_KV || typeof env.SUBSCRIPTION_KV.put !== "function") {
        return new Response("Service Unavailable", { status: 503, headers: noStore });
      }
      if (total === 0) return new Response("Empty Body", { status: 400, headers: noStore });
      try {
        await env.SUBSCRIPTION_KV.put(keyName, body);
      } catch {
        return new Response("Service Unavailable", { status: 503, headers: noStore });
      }
      return new Response(null, { status: 204, headers: noStore });
    }

    // Only the exact secret path is readable. No redirects, listing, or metadata leaks.
    if (request.method !== "GET" || !env.SUB_PATH_KEY || !constantTimeEqual(url.pathname, `/${env.SUB_PATH_KEY}`)) {
      return notFound();
    }
    if (!env.SUBSCRIPTION_KV || typeof env.SUBSCRIPTION_KV.get !== "function") {
      return new Response("Service Unavailable", { status: 503, headers: noStore });
    }
    let content;
    try {
      content = await env.SUBSCRIPTION_KV.get(keyName);
    } catch {
      return new Response("Service Unavailable", { status: 503, headers: noStore });
    }
    if (content === null) return new Response("Not Found", { status: 404, headers: noStore });
    const out = render(content, pickTarget(url, request));
    return new Response(out.body, {
      status: 200,
      headers: {
        ...noStore,
        "Content-Type": out.type,
        "X-Content-Type-Options": "nosniff",
        "Profile-Update-Interval": "6",
      },
    });
  },
};
