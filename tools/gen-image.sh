#!/bin/sh
# gen-image.sh — 调云端生图 API（手机端，不依赖本机 GPU）
#
# 三种取配置的方式，优先级从高到低：
#   1. 命令行参数（-u -e -m）
#   2. 环境变量（GEN_KEY / GEN_ENDPOINT / GEN_FORMAT / GEN_MODEL）
#   3. 配置页保存的文件 ~/.phone-armor/gen.conf（用 tools/gen-config.mjs 生成）
#
# 用法：
#   sh gen-image.sh "提示词"
#   sh gen-image.sh "提示词" -o /root/workspace/a.png
#   sh gen-image.sh "提示词" -t art          # 套用艺术化模板（路2）
#   sh gen-image.sh "提示词" -e novelai
#   GEN_KEY=xxx sh gen-image.sh "提示词" -u https://api.xxx.com/v1 -m flux
#
# 参数：
#   -o  输出路径（默认 /root/workspace/gen-<时间戳>.png）
#   -s  尺寸（默认 1024x1024）
#   -e  格式：openai | novelai
#   -u  baseURL
#   -m  模型名
#   -n  数量
#   -t  提示词模板：art（艺术化/人体写生）| photo（写实摄影）| anime（动漫）| 自定义字符串
set -u

PROMPT=""
OUT=""
SIZE="1024x1024"
FMT=""
BASE=""
MODEL=""
NUM="1"
TPL=""
CONF="$HOME/.phone-armor/gen.conf"

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -s) SIZE="$2"; shift 2 ;;
    -e) FMT="$2"; shift 2 ;;
    -u) BASE="$2"; shift 2 ;;
    -m) MODEL="$2"; shift 2 ;;
    -n) NUM="$2"; shift 2 ;;
    -t) TPL="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) PROMPT="$1"; shift ;;
  esac
done

[ -n "$PROMPT" ] || { printf '缺少提示词。例：sh gen-image.sh "写实人像，柔光"\n' >&2; exit 1; }

NODE="${DSH_NODE:-$(command -v node)}"
[ -n "$NODE" ] || { printf '找不到 node\n' >&2; exit 1; }

[ -n "$OUT" ] || OUT="/root/workspace/gen-$(date +%s).png"
mkdir -p "$(dirname "$OUT")" 2>/dev/null

"$NODE" - "$CONF" "$PROMPT" "$OUT" "$SIZE" "$FMT" "$BASE" "$MODEL" "$NUM" "$TPL" <<'JSEOF'
const [confPath, rawPrompt, out, size, aFmt, aBase, aModel, aNum, tpl] = process.argv.slice(2);
const fs = require("fs");

// ---- 配置：参数 > 环境变量 > 配置文件 ----
let conf = {};
try { conf = JSON.parse(fs.readFileSync(confPath, "utf8")) || {}; } catch {}

const fmt    = aFmt   || process.env.GEN_FORMAT   || conf.format   || "openai";
const base   = aBase  || process.env.GEN_ENDPOINT || conf.endpoint || (fmt === "novelai" ? "https://image.novelai.net" : "");
const key    = process.env.GEN_KEY || conf.key || "";
const model  = aModel || process.env.GEN_MODEL    || conf.model    || "";
const [w, h] = size.split("x").map(Number);

if (!key) {
  console.error("缺少 API Key。三种填法：");
  console.error("  ① 跑 node tools/gen-config.mjs，在浏览器里填（推荐）");
  console.error("  ② GEN_KEY=xxx sh gen-image.sh ...");
  console.error("  ③ 编辑 ~/.phone-armor/gen.conf");
  process.exit(1);
}
if (fmt === "openai" && !base) {
  console.error("openai 格式需要 API 地址：-u 或在配置页里填 endpoint");
  process.exit(1);
}

// ---- 路2：提示词模板 ----
const TEMPLATES = {
  art:   "academic figure study, classical oil painting style, natural side light, realistic skin texture, fine art, masterpiece",
  photo: "photorealistic, 85mm lens, soft studio lighting, shallow depth of field, detailed skin texture",
  anime: "anime style, clean line art, soft shading, high detail"
};
let prompt = rawPrompt;
if (tpl) {
  const t = TEMPLATES[tpl] || (tpl.includes(",") ? tpl : "");
  if (!t) { console.error("未知模板：" + tpl + "（可选 art / photo / anime，或直接给一段逗号分隔的修饰词）"); process.exit(1); }
  prompt = t + ", " + rawPrompt;
}

function die(msg) { console.error(msg); process.exit(1); }

async function openai() {
  const url = base.replace(/\/+$/, "") + "/images/generations";
  const payload = { prompt, n: Number(aNum), size, response_format: "b64_json" };
  if (model) payload.model = model;
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  const text = await r.text();
  if (!r.ok) die("HTTP " + r.status + "  " + text.slice(0, 300));
  let j;
  try { j = JSON.parse(text); } catch { die("返回不是 JSON：" + text.slice(0, 200)); }
  const item = j?.data?.[0];
  if (!item) die("返回里没有 data[0]：" + text.slice(0, 300));
  if (item.b64_json) {
    fs.writeFileSync(out, Buffer.from(item.b64_json, "base64"));
  } else if (item.url) {
    const img = await fetch(item.url);
    if (!img.ok) die("下载图片失败 HTTP " + img.status);
    fs.writeFileSync(out, Buffer.from(await img.arrayBuffer()));
  } else {
    die("data[0] 里既没有 b64_json 也没有 url");
  }
}

async function novelai() {
  const url = base.replace(/\/+$/, "") + "/ai/generate-image";
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({
      input: prompt,
      model: model || "nai-diffusion-3",
      action: "generate",
      parameters: {
        width: w, height: h, scale: 5, sampler: "k_euler_ancestral",
        steps: 28, n_samples: Number(aNum), ucPreset: 0, qualityToggle: true,
        negative_prompt: "lowres, bad anatomy, bad hands, watermark, text"
      }
    })
  });
  if (!r.ok) die("HTTP " + r.status + "  " + (await r.text()).slice(0, 300));
  fs.writeFileSync(out + ".zip", Buffer.from(await r.arrayBuffer()));
}

(fmt === "novelai" ? novelai() : openai())
  .then(() => {
    if (fmt === "novelai") { console.log("ZIP:" + out); return; }
    const s = fs.statSync(out).size;
    if (s < 1024) { console.error("生成的文件只有 " + s + " 字节，可能是错误占位图"); process.exit(1); }
    console.log("OK:" + out + ":" + s);
  })
  .catch(e => die(e.message));
JSEOF

rc=$?

# NovelAI 的 ZIP 解出 PNG
if [ "$FMT" = "novelai" ] || { [ -z "$FMT" ] && [ -f "$OUT.zip" ]; }; then
  if [ -f "$OUT.zip" ]; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -o -q "$OUT.zip" -d "$(dirname "$OUT")"
      found=$(ls -t "$(dirname "$OUT")"/*.png 2>/dev/null | head -1)
      if [ -n "$found" ]; then [ "$found" != "$OUT" ] && mv -f "$found" "$OUT"; fi
    elif command -v python3 >/dev/null 2>&1; then
      python3 - "$OUT.zip" "$OUT" <<'PY'
import sys, zipfile, shutil
z, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(z) as zf:
    name = [n for n in zf.namelist() if n.lower().endswith(".png")][0]
    with zf.open(name) as src, open(out, "wb") as dst:
        shutil.copyfileobj(src, dst)
PY
    else
      printf '收到 ZIP 但缺 unzip/python3 解不开：%s\n' "$OUT.zip" >&2
      exit 1
    fi
    rm -f "$OUT.zip"
  fi
fi

[ "$rc" -eq 0 ] || exit $rc

if [ -f "$OUT" ]; then
  printf '已保存：%s (%s 字节)\n' "$OUT" "$(wc -c < "$OUT")"
else
  printf '没有生成文件，检查上面的报错\n' >&2
  exit 1
fi
