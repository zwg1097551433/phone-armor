#!/usr/bin/env node
/**
 * gen-config.mjs — 生图配置页（手机浏览器里填 API key，点保存即生效）
 *
 *   node tools/gen-config.mjs            默认 127.0.0.1:8899
 *   node tools/gen-config.mjs --port 8899
 *
 * 只监听回环地址，不暴露到局域网。配置写到 ~/.phone-armor/gen.conf（权限 600）。
 * 页面里能填：API 地址 / Key / 模型名 / 格式，还能一键试生成一张图。
 */
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const args = process.argv.slice(2);
const portArg = args.indexOf("--port");
const PORT = portArg >= 0 ? Number(args[portArg + 1]) : 8899;

const CONF_DIR = path.join(os.homedir(), ".phone-armor");
const CONF = path.join(CONF_DIR, "gen.conf");

function readConf() {
  try {
    return JSON.parse(fs.readFileSync(CONF, "utf8"));
  } catch {
    return {};
  }
}

function writeConf(c) {
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(CONF, JSON.stringify(c, null, 2), { mode: 0o600 });
  fs.chmodSync(CONF, 0o600);
}

function mask(key) {
  if (!key) return "";
  if (key.length <= 8) return "*".repeat(key.length);
  return key.slice(0, 4) + "*".repeat(Math.max(4, key.length - 8)) + key.slice(-4);
}

function json(res, code, obj) {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(obj));
}

function body(req) {
  return new Promise((resolve, reject) => {
    let b = "";
    req.on("data", (c) => { b += c; if (b.length > 1e6) reject(new Error("too large")); });
    req.on("end", () => resolve(b));
    req.on("error", reject);
  });
}

async function testGenerate(c) {
  if (!c.key) return { ok: false, msg: "还没填 API Key" };
  const prompt = c.testPrompt || "a serene mountain lake at sunset, soft golden light";
  const size = c.size || "1024x1024";
  const [w, h] = size.split("x").map(Number);

  try {
    if (c.format === "novelai") {
      const base = (c.endpoint || "https://image.novelai.net").replace(/\/+$/, "");
      const r = await fetch(base + "/ai/generate-image", {
        method: "POST",
        headers: { Authorization: "Bearer " + c.key, "Content-Type": "application/json" },
        body: JSON.stringify({
          input: prompt,
          model: c.model || "nai-diffusion-3",
          action: "generate",
          parameters: {
            width: w, height: h, scale: 5, sampler: "k_euler_ancestral",
            steps: 28, n_samples: 1, ucPreset: 0, qualityToggle: true,
            negative_prompt: "lowres, bad anatomy, watermark, text"
          }
        })
      });
      if (!r.ok) return { ok: false, msg: "HTTP " + r.status + " " + (await r.text()).slice(0, 200) };
      const buf = Buffer.from(await r.arrayBuffer());
      return { ok: true, msg: "成功，返回 ZIP " + buf.length + " 字节（格式正确）" };
    }

    const base = (c.endpoint || "").replace(/\/+$/, "");
    if (!base) return { ok: false, msg: "还没填 API 地址" };
    const payload = { prompt, n: 1, size, response_format: "b64_json" };
    if (c.model) payload.model = c.model;
    const r = await fetch(base + "/images/generations", {
      method: "POST",
      headers: { Authorization: "Bearer " + c.key, "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const text = await r.text();
    if (!r.ok) return { ok: false, msg: "HTTP " + r.status + " " + text.slice(0, 240) };
    let j;
    try { j = JSON.parse(text); } catch { return { ok: false, msg: "返回不是 JSON：" + text.slice(0, 200) }; }
    const item = j?.data?.[0];
    if (!item) return { ok: false, msg: "返回里没有 data[0]：" + text.slice(0, 240) };
    const kind = item.b64_json ? "b64_json" : item.url ? "url" : "未知";
    return { ok: true, msg: "成功，收到 " + kind };
  } catch (e) {
    return { ok: false, msg: "连不上：" + e.message };
  }
}

const PAGE = String.raw`<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>生图 API 配置</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { margin:0; padding:18px 16px 40px; background:#0e1015; color:#e6e8ec;
         font:15px/1.55 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif; }
  h1 { font-size:19px; margin:4px 0 4px; }
  .sub { color:#8b9199; font-size:12.5px; margin-bottom:18px; }
  .card { background:#161922; border:1px solid #262b36; border-radius:12px; padding:14px; margin-bottom:14px; }
  .card h2 { font-size:14px; margin:0 0 12px; color:#9aa3b0; font-weight:600; letter-spacing:.02em; }
  label { display:block; font-size:13px; color:#b9bec7; margin:12px 0 6px; }
  label:first-of-type { margin-top:0; }
  input, select, textarea { width:100%; padding:11px 12px; font-size:15px; color:#e6e8ec;
    background:#0b0d12; border:1px solid #2c313a; border-radius:9px; outline:none; font-family:inherit; }
  input:focus, select, textarea:focus { border-color:#3d6ef5; }
  .hint { font-size:12px; color:#71787f; margin-top:5px; line-height:1.5; }
  .row { display:flex; gap:9px; margin-top:18px; }
  button { flex:1; padding:13px; font-size:15px; font-weight:600; border-radius:10px;
    border:none; cursor:pointer; font-family:inherit; }
  .primary { background:#3d6ef5; color:#fff; }
  .ghost { background:transparent; color:#b9bec7; border:1px solid #333a44; }
  .msg { margin-top:12px; padding:11px 13px; border-radius:9px; font-size:13.5px; display:none; line-height:1.5; word-break:break-all; }
  .ok { display:block; background:#12261a; border:1px solid #2e7d32; color:#8fe6a3; }
  .err { display:block; background:#2a1114; border:1px solid #d32f2f; color:#ff9d9d; }
  .badge { display:inline-block; font-size:11px; padding:2px 8px; border-radius:6px;
    background:#1e2430; color:#8b9199; margin-left:6px; vertical-align:middle; }
  .badge.on { background:#14301c; color:#7bd88f; }
  a { color:#5b8cff; }
</style></head><body>

<h1>生图 API 配置 <span id="st" class="badge">读取中</span></h1>
<div class="sub">填好点保存，之后用 tools/gen-image.sh 出图 —— 不经过模型判断，直接调接口。</div>

<div class="card">
  <h2>① 接口</h2>

  <label>格式</label>
  <select id="format">
    <option value="openai">OpenAI 兼容（/v1/images/generations）</option>
    <option value="novelai">NovelAI（/ai/generate-image）</option>
  </select>

  <label>API 地址 <span style="color:#71787f">（NovelAI 可留空）</span></label>
  <input id="endpoint" placeholder="https://api.example.com/v1" autocomplete="off" spellcheck="false">
  <div class="hint">文档里能看到 <code>/v1/images/generations</code> 就是 OpenAI 兼容格式。</div>

  <label>API Key</label>
  <input id="key" type="password" placeholder="sk-..." autocomplete="off" spellcheck="false">
  <div class="hint">只存在手机本地 <code>~/.phone-armor/gen.conf</code>（权限 600），不会上传。</div>

  <label>模型名 <span style="color:#71787f">（可留空，用服务商默认）</span></label>
  <input id="model" placeholder="例如 flux / nai-diffusion-3" autocomplete="off" spellcheck="false">
</div>

<div class="card">
  <h2>② 测试</h2>
  <label>测试用提示词</label>
  <textarea id="testPrompt" rows="2" placeholder="a serene mountain lake at sunset">a serene mountain lake at sunset, soft golden light</textarea>
  <div class="row">
    <button class="ghost" onclick="test()">试生成一张</button>
  </div>
  <div id="msg" class="msg"></div>
</div>

<div class="row">
  <button class="primary" onclick="save()">保存配置</button>
</div>

<script>
const $ = id => document.getElementById(id);
function show(ok, text) {
  const m = $('msg');
  m.className = 'msg ' + (ok ? 'ok' : 'err');
  m.textContent = text;
}
async function load() {
  try {
    const r = await fetch('/api/conf');
    const c = await r.json();
    $('format').value = c.format || 'openai';
    $('endpoint').value = c.endpoint || '';
    $('key').value = c.key || '';
    $('model').value = c.model || '';
    $('st').textContent = c.key ? '已配置' : '未配置';
    $('st').className = 'badge' + (c.key ? ' on' : '');
  } catch (e) {
    $('st').textContent = '读取失败';
  }
}
async function save() {
  const body = {
    format: $('format').value,
    endpoint: $('endpoint').value.trim(),
    key: $('key').value.trim(),
    model: $('model').value.trim()
  };
  try {
    const r = await fetch('/api/conf', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
    const j = await r.json();
    if (j.ok) { show(true, '已保存到 ~/.phone-armor/gen.conf'); $('st').textContent='已配置'; $('st').className='badge on'; }
    else show(false, j.msg || '保存失败');
  } catch (e) { show(false, '保存失败：' + e.message); }
}
async function test() {
  show(true, '正在请求接口…');
  $('msg').className = 'msg';
  $('msg').style.display = 'block';
  $('msg').textContent = '正在请求接口…';
  const body = {
    format: $('format').value,
    endpoint: $('endpoint').value.trim(),
    key: $('key').value.trim(),
    model: $('model').value.trim(),
    testPrompt: $('testPrompt').value.trim()
  };
  try {
    const r = await fetch('/api/test', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
    const j = await r.json();
    show(j.ok, j.msg);
  } catch (e) { show(false, '测试失败：' + e.message); }
}
load();
</script>
</body></html>`;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");

  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    res.end(PAGE);
    return;
  }

  if (url.pathname === "/api/conf") {
    if (req.method === "GET") {
      const c = readConf();
      return json(res, 200, { ...c, key: c.key ? c.key : "" });
    }
    if (req.method === "POST") {
      try {
        const incoming = JSON.parse((await body(req)) || "{}");
        const c = readConf();
        const next = {
          ...c,
          format: incoming.format === "novelai" ? "novelai" : "openai",
          endpoint: String(incoming.endpoint || ""),
          key: String(incoming.key || ""),
          model: String(incoming.model || ""),
          updatedAt: new Date().toISOString()
        };
        writeConf(next);
        return json(res, 200, { ok: true });
      } catch (e) {
        return json(res, 400, { ok: false, msg: e.message });
      }
    }
  }

  if (req.method === "POST" && url.pathname === "/api/test") {
    try {
      const incoming = JSON.parse((await body(req)) || "{}");
      const c = { ...readConf(), ...incoming };
      const r = await testGenerate(c);
      return json(res, 200, r);
    } catch (e) {
      return json(res, 500, { ok: false, msg: e.message });
    }
  }

  res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("not found");
});

server.listen(PORT, "127.0.0.1", () => {
  console.log("");
  console.log("  生图配置页已启动");
  console.log("  手机浏览器打开：  http://127.0.0.1:" + PORT);
  console.log("  配置文件：       " + CONF);
  console.log("  按 Ctrl-C 停止");
  console.log("");
});
