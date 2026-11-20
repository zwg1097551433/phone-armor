/**
 * phone-armor-settings — host 半边
 *
 * 职责：
 *   1. 读写 ~/.dsh/phone-armor/modules.json（三个模块的开关状态）
 *   2. 处理 boost 开关：把 prompt/boost-nsfw.md 合并进 prompt-inject.md，或整段移除
 *   3. 给浏览器半边提供一条 HTTP 接口 POST/GET /phone-armor/modules
 *
 * 为什么走 webServer 而不是 Remote service：和 dsh-purge 同一口径 ——
 * 本包刻意保持零外部依赖，具名路由是最小且稳定的接缝。
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const BOOST_BEGIN = "<!-- BOOST:BEGIN -->";
const BOOST_END = "<!-- BOOST:END -->";

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
}
function paDir() {
  return path.join(dshHome(), "phone-armor");
}
function modulesFile() {
  return path.join(paDir(), "modules.json");
}
function injectFile() {
  return path.join(dshHome(), "prompt-inject.md");
}
function boostSource() {
  return path.join(paDir(), "boost.md");
}

/** 生图 API 凭据：和 tools/gen-config.mjs 用同一个文件，两边互通。 */
function genConfPath() {
  return path.join(os.homedir(), ".phone-armor", "gen.conf");
}

function readGenConf() {
  try {
    return JSON.parse(fs.readFileSync(genConfPath(), "utf8")) || {};
  } catch {
    return {};
  }
}

function writeGenConf(next) {
  const p = genConfPath();
  fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
  fs.writeFileSync(p, JSON.stringify(next, null, 2), { mode: 0o600 });
  try { fs.chmodSync(p, 0o600); } catch {}
}

/** 对外只暴露"有没有配"，不回显 key 明文。 */
function publicGenConf() {
  const c = readGenConf();
  return {
    endpoint: c.endpoint || "",
    model: c.model || "",
    format: c.format === "novelai" ? "novelai" : "openai",
    hasKey: !!c.key,
    keyHint: c.key ? String(c.key).slice(0, 4) + "…" + String(c.key).slice(-4) : ""
  };
}

const DEFAULTS = { core: true, ext: false, boost: false };

function readModules() {
  try {
    const raw = JSON.parse(fs.readFileSync(modulesFile(), "utf8"));
    return { ...DEFAULTS, ...raw };
  } catch {
    return { ...DEFAULTS };
  }
}

function writeModules(next) {
  fs.mkdirSync(paDir(), { recursive: true, mode: 0o700 });
  fs.writeFileSync(modulesFile(), JSON.stringify(next, null, 2), { mode: 0o600 });
  try { fs.chmodSync(modulesFile(), 0o600); } catch {}
}

/** 把强化包合并进 prompt-inject.md（幂等），或整段移除。 */
function applyBoost(on) {
  const target = injectFile();
  let cur = "";
  try {
    cur = fs.readFileSync(target, "utf8");
  } catch {
    return { ok: false, msg: "找不到 prompt-inject.md，先跑一次 armor.sh install" };
  }

  const i = cur.indexOf(BOOST_BEGIN);
  const j = cur.indexOf(BOOST_END);

  if (on) {
    let block;
    try {
      block = fs.readFileSync(boostSource(), "utf8");
    } catch {
      return { ok: false, msg: "找不到强化包 boost.md，重新跑安装脚本" };
    }
    let out;
    if (i >= 0 && j > i) {
      out = cur.slice(0, i) + block.trim() + cur.slice(j + BOOST_END.length);
    } else {
      out = block.trim() + "\n\n" + cur;
    }
    fs.writeFileSync(target, out);
    return { ok: true, size: out.length, msg: "已合并进 prompt-inject.md" };
  }

  if (i < 0 || j <= i) return { ok: true, size: cur.length, msg: "当前未开启" };
  const out = (cur.slice(0, i) + cur.slice(j + BOOST_END.length)).replace(/^\s+/, "");
  fs.writeFileSync(target, out);
  return { ok: true, size: out.length, msg: "已从 prompt-inject.md 移除" };
}

/** 检测各模块在磁盘上的真实状态，而不只是配置里写的。 */
function detect() {
  const home = dshHome();
  const profileDir = path.join(home, "profiles", "web");
  const has = (p) => {
    try { return fs.existsSync(p); } catch { return false; }
  };
  let injectSize = 0;
  try { injectSize = fs.statSync(injectFile()).size; } catch {}
  let boostMerged = false;
  let injectMode = "unknown";
  try {
    const text = fs.readFileSync(injectFile(), "utf8");
    boostMerged = text.includes(BOOST_BEGIN);
    // full 版含「本机能力边界」整段；core 版只有执行纪律
    injectMode = text.includes("本机能力边界") ? "full" : "core";
  } catch {}

  return {
    purgeInstalled: has(path.join(profileDir, "node_modules", "dsh-purge-community")),
    preflightInstalled: has(path.join(profileDir, "node_modules", "phone-armor-preflight")),
    guardInstalled: has("/opt/phone-armor/guard.sh"),
    genConfigExists: has(path.join(home, "..", ".phone-armor", "gen.conf")) || has(path.join(paDir(), "gen.conf")),
    injectSize,
    injectMode,
    boostMerged,
    dshHome: home
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = "";
    req.on("data", (c) => {
      b += c;
      if (b.length > 65536) reject(new Error("body too large"));
    });
    req.on("end", () => resolve(b));
    req.on("error", reject);
  });
}

function send(res, code, obj) {
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(JSON.stringify(obj));
}

/** 只接受本机回环请求，避免把开关接口暴露到局域网。 */
function localOnly(req) {
  const h = String(req.headers.host || "");
  return /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(h);
}

export function apply(ctx) {
  ctx.inject(["webServer"], (host) => host.effect(() => {
    // ---- 模块开关 ----
    const offModules = host.webServer.register({
      kind: "exact",
      path: "/phone-armor/modules",
      handler: async (req, res) => {
        if (!localOnly(req)) {
          return send(res, 403, { ok: false, msg: "只允许本机访问" });
        }

        if (req.method === "GET") {
          return send(res, 200, { ok: true, modules: readModules(), detect: detect() });
        }

        if (req.method === "POST") {
          let body;
          try {
            body = JSON.parse((await readBody(req)) || "{}");
          } catch (e) {
            return send(res, 400, { ok: false, msg: "请求体不是 JSON：" + e.message });
          }

          const cur = readModules();
          const next = { ...cur };

          if (typeof body.ext === "boolean") next.ext = body.ext;

          let boostResult = null;
          if (typeof body.boost === "boolean") {
            boostResult = applyBoost(body.boost);
            if (!boostResult.ok) return send(res, 500, { ok: false, msg: boostResult.msg });
            next.boost = body.boost;
          }

          next.core = true;
          writeModules(next);

          return send(res, 200, {
            ok: true,
            modules: next,
            detect: detect(),
            boost: boostResult,
            note: boostResult ? "提示词变化需重启引擎才生效" : undefined
          });
        }

        return send(res, 405, { ok: false, msg: "只支持 GET / POST" });
      }
    });

    // ---- 生图 API 凭据 ----
    const offGenConf = host.webServer.register({
      kind: "exact",
      path: "/phone-armor/genconf",
      handler: async (req, res) => {
        if (!localOnly(req)) {
          return send(res, 403, { ok: false, msg: "只允许本机访问" });
        }

        if (req.method === "GET") {
          return send(res, 200, { ok: true, conf: publicGenConf() });
        }

        if (req.method === "POST") {
          let body;
          try {
            body = JSON.parse((await readBody(req)) || "{}");
          } catch (e) {
            return send(res, 400, { ok: false, msg: "请求体不是 JSON：" + e.message });
          }

          const cur = readGenConf();
          const next = {
            format: body.format === "novelai" ? "novelai" : "openai",
            endpoint: String(body.endpoint ?? cur.endpoint ?? "").trim(),
            model: String(body.model ?? cur.model ?? "").trim(),
            // 空字符串表示"不改"，保留原来保存的 key
            key: body.key ? String(body.key).trim() : (cur.key || ""),
            updatedAt: new Date().toISOString()
          };

          try {
            writeGenConf(next);
          } catch (e) {
            return send(res, 500, { ok: false, msg: "写入失败：" + e.message });
          }

          return send(res, 200, { ok: true, conf: publicGenConf() });
        }

        return send(res, 405, { ok: false, msg: "只支持 GET / POST" });
      }
    });

    return () => {
      try { offModules(); } catch {}
      try { offGenConf(); } catch {}
    };
  }));
}
