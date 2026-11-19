#!/bin/sh
# gen-image.sh — 调云端生图 API（手机端，不依赖本机 GPU）
#
# 支持两种返回格式：
#   openai   标准的 /v1/images/generations，返回 {data:[{b64_json|url}]}
#   novelai  返回 ZIP（内含 PNG），端点 https://image.novelai.net/ai/generate-image
#
# 用法：
#   GEN_KEY=xxx sh gen-image.sh "提示词"
#   GEN_KEY=xxx sh gen-image.sh "提示词" -o /root/workspace/a.png
#   GEN_KEY=xxx sh gen-image.sh "提示词" -e novelai
#   GEN_KEY=xxx sh gen-image.sh "提示词" -u https://api.example.com/v1 -m some-model
#
# 参数：
#   -o  输出路径（默认 /root/workspace/gen-<时间戳>.png）
#   -s  尺寸（默认 1024x1024）
#   -e  格式：openai | novelai（默认读 GEN_FORMAT，否则 openai）
#   -u  baseURL（默认读 GEN_ENDPOINT）
#   -m  模型名（默认读 GEN_MODEL，可空）
#   -n  数量（默认 1）
#
# 环境变量：
#   GEN_KEY       API key（必填）
#   GEN_ENDPOINT  默认 baseURL
#   GEN_FORMAT    默认格式
#   GEN_MODEL     默认模型
set -u

PROMPT=""
OUT=""
SIZE="1024x1024"
FMT="${GEN_FORMAT:-openai}"
BASE="${GEN_ENDPOINT:-}"
MODEL="${GEN_MODEL:-}"
NUM="1"

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -s) SIZE="$2"; shift 2 ;;
    -e) FMT="$2"; shift 2 ;;
    -u) BASE="$2"; shift 2 ;;
    -m) MODEL="$2"; shift 2 ;;
    -n) NUM="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) PROMPT="$1"; shift ;;
  esac
done

[ -n "$PROMPT" ] || { printf '缺少提示词。用法：GEN_KEY=xxx sh gen-image.sh "提示词"\n' >&2; exit 1; }
[ -n "${GEN_KEY:-}" ] || { printf '缺少 GEN_KEY。先去服务商申请，再：GEN_KEY=xxx sh gen-image.sh ...\n' >&2; exit 1; }

case "$FMT" in
  openai)
    [ -n "$BASE" ] || { printf 'openai 格式需要 -u 指定 baseURL（例如 https://api.xxx.com/v1）\n' >&2; exit 1; }
    [ -n "$OUT" ] || OUT="/root/workspace/gen-$(date +%s).png"
    ;;
  novelai)
    BASE="${BASE:-https://image.novelai.net}"
    [ -n "$OUT" ] || OUT="/root/workspace/gen-$(date +%s).png"
    ;;
  *) printf '未知格式：%s（可选 openai / novelai）\n' "$FMT" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$OUT")" 2>/dev/null

NODE="${DSH_NODE:-$(command -v node)}"
[ -n "$NODE" ] || { printf '找不到 node\n' >&2; exit 1; }

"$NODE" - "$FMT" "$BASE" "$GEN_KEY" "$MODEL" "$PROMPT" "$SIZE" "$NUM" "$OUT" <<'JSEOF'
const [fmt, base, key, model, prompt, size, num, out] = process.argv.slice(2);
const fs = require("fs");
const [w, h] = size.split("x").map(Number);

function die(msg) { console.error(msg); process.exit(1); }

async function openai() {
  const url = base.replace(/\/+$/, "") + "/images/generations";
  const body = { prompt, n: Number(num), size, response_format: "b64_json" };
  if (model) body.model = model;
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  const text = await r.text();
  if (!r.ok) die("HTTP " + r.status + "  " + text.slice(0, 300));
  let j;
  try { j = JSON.parse(text); } catch { die("返回不是 JSON：" + text.slice(0, 200)); }
  const item = j?.data?.[0];
  if (!item) die("返回里没有 data[0]：" + text.slice(0, 300));
  if (item.b64_json) {
    fs.writeFileSync(out, Buffer.from(item.b64_json, "base64"));
    return out;
  }
  if (item.url) {
    const img = await fetch(item.url);
    if (!img.ok) die("下载图片失败 HTTP " + img.status);
    fs.writeFileSync(out, Buffer.from(await img.arrayBuffer()));
    return out;
  }
  die("data[0] 里既没有 b64_json 也没有 url");
}

async function novelai() {
  const url = base.replace(/\/+$/, "") + "/ai/generate-image";
  const body = {
    input: prompt,
    model: model || "nai-diffusion-3",
    action: "generate",
    parameters: {
      width: w, height: h, scale: 5, sampler: "k_euler_ancestral",
      steps: 28, n_samples: Number(num), ucPreset: 0, qualityToggle: true,
      negative_prompt: "nsfw, lowres, bad anatomy, bad hands, watermark, text"
    }
  };
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  if (!r.ok) die("HTTP " + r.status + "  " + (await r.text()).slice(0, 300));
  const buf = Buffer.from(await r.arrayBuffer());
  // NovelAI 返回 ZIP，写到临时文件交给外面的解压步骤
  const tmp = out + ".zip";
  fs.writeFileSync(tmp, buf);
  console.log("ZIP:" + tmp);
  process.exit(0);
}

(fmt === "novelai" ? novelai() : openai())
  .then(p => { if (p) console.log("OK:" + p); })
  .catch(e => die(e.message));
JSEOF

rc=$?
# NovelAI 的 ZIP 需要解出来
case "$FMT" in
  novelai)
    [ -f "$OUT.zip" ] || exit $rc
    if command -v unzip >/dev/null 2>&1; then
      unzip -o -q "$OUT.zip" -d "$(dirname "$OUT")"
      found=$(ls -t "$(dirname "$OUT")"/*.png 2>/dev/null | head -1)
      [ -n "$found" ] && { [ "$found" != "$OUT" ] && mv -f "$found" "$OUT"; }
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
      printf '收到 ZIP 但没有 unzip/python3 解不开：%s\n' "$OUT.zip" >&2
      exit 1
    fi
    rm -f "$OUT.zip"
    ;;
esac

if [ -f "$OUT" ]; then
  printf '已保存：%s (%s 字节)\n' "$OUT" "$(wc -c < "$OUT")"
else
  printf '没有生成文件，检查上面的报错\n' >&2
  exit 1
fi
