#!/bin/sh
# vanilla.sh — 装「原作者方案」（裸插件，不含本仓库的任何增强）
#
# 用途：和 deploy.sh 做 A/B 对比。装在另一台手机上，只装 dsh-purge 本体。
#
#   sh vanilla.sh              装 1.6.91（与我们的版本一致，便于公平对比）
#   sh vanilla.sh --latest     装最新 release（当前 1.7.20，可能不适配 rc.1）
#   sh vanilla.sh --with-inject 装完后额外放入本仓库的 prompt-inject.md
#                                （否则原版没有注入正文，apply 会报「提示词为空」）
#   sh vanilla.sh --no-apply   只装插件，不执行 apply
#
# 与 deploy.sh 的差别：不装预检、不装命令提示、不装设置页、不改 tuning、
# 不关自动更新检查、不做版本哨兵。保持原版行为，用于对照。
set -u

REPO="dsh-purge"
VER="1.6.91"
WORK="${WORK:-/tmp/vanilla-purge}"
MODE_APPLY=1
MODE_INJECT=0

for a in "$@"; do
  case "$a" in
    --latest)      VER="latest" ;;
    --no-apply)    MODE_APPLY=0 ;;
    --with-inject) MODE_INJECT=1 ;;
    -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
  esac
done

OWNER="kingcharleslzy-ai"

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

find_home() {
  for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
    [ -n "$h" ] && [ -f "$h/profiles/web/package.json" ] && { printf '%s' "$h"; return 0; }
  done
  return 1
}
find_node() {
  for c in "$(command -v node 2>/dev/null)" /opt/dsh/node/bin/node /opt/dsh-app/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

H=$(find_home) || die "找不到 DSH_HOME。先在 App 里启动一次本机引擎。"
N="${DSH_NODE:-$(find_node)}"
[ -n "$N" ] || die "找不到 node"
PJ="$H/profiles/web/package.json"
DEST="$H/profiles/web/node_modules/dsh-purge-community"

hr
say "vanilla dsh-purge 安装（原作者方案，不含本仓库增强）"
say "版本：$VER"
hr

# ---- 1. 解析下载地址 ----
if [ "$VER" = "latest" ]; then
  say "[1] 查询最新 release ..."
  URL=$("$N" -e '
    fetch("https://api.github.com/repos/kingcharleslzy-ai/dsh-purge/releases/latest", {
      headers: { "User-Agent": "vanilla-installer", "Accept": "application/vnd.github+json" }
    })
      .then(r => r.json())
      .then(j => {
        const v = String(j.tag_name || "").replace(/^v/, "");
        if (!v) { console.error("拿不到版本号"); process.exit(1); }
        process.stdout.write("https://github.com/kingcharleslzy-ai/dsh-purge/releases/download/v" + v + "/dsh-purge-community-" + v + ".tgz");
      })
      .catch(e => { console.error(e.message); process.exit(1); });
  ' 2>&1) || die "查最新版失败：$URL"
else
  URL="https://github.com/$OWNER/$REPO/releases/download/v$VER/dsh-purge-community-$VER.tgz"
fi
say "    $URL"

# ---- 2. 下载 ----
say "[2] 下载 tgz"
rm -rf "$WORK"; mkdir -p "$WORK" || die "无法创建 $WORK"
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --connect-timeout 20 -o "$WORK/p.tgz" "$URL" || die "curl 下载失败"
else
  "$N" -e '
    const [u, o] = process.argv.slice(1);
    fetch(u).then(async r => { if (!r.ok) throw new Error("HTTP " + r.status);
      require("fs").writeFileSync(o, Buffer.from(await r.arrayBuffer())); })
      .catch(e => { console.error(e.message); process.exit(1); });
  ' "$URL" "$WORK/p.tgz" || die "下载失败"
fi
say "    $(wc -c < "$WORK/p.tgz") 字节"

# ---- 3. 解包 ----
say "[3] 解包"
tar -xzf "$WORK/p.tgz" -C "$WORK" || die "解包失败"
[ -f "$WORK/package/bin/dsh-purge.js" ] || die "包结构异常"

# ---- 4. 官方路径：先试 dsh plugin add ----
say "[4] 尝试官方安装路径（dsh plugin add）"
PJ_BAK="$WORK/package.json.orig"
cp -f "$PJ" "$PJ_BAK"
USED_OFFICIAL=0
if command -v dsh >/dev/null 2>&1; then
  if dsh plugin --profile web add "$WORK/p.tgz" 2>&1 | tail -3; then
    if [ -d "$DEST" ]; then
      USED_OFFICIAL=1
      say "    ✓ 官方 CLI 安装成功"
    fi
  fi
fi
[ "$USED_OFFICIAL" = 1 ] || say "    官方路径不可用，降级为手动装配"

# ---- 5. 手动装配（官方失败时） ----
if [ "$USED_OFFICIAL" = 0 ]; then
  say "[5] 手动装配"
  mkdir -p "$H/profiles/web/node_modules"
  rm -rf "$DEST"
  cp -a "$WORK/package" "$DEST" || die "复制失败"
  "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    const o = JSON.parse(fs.readFileSync(p, "utf8"));
    o.dsh = o.dsh || {}; o.dsh.profile = o.dsh.profile || {};
    const b = o.dsh.profile.bundles = o.dsh.profile.bundles || [];
    if (!b.includes("dsh-purge-community")) b.push("dsh-purge-community");
    fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
  ' "$PJ" || { cp -f "$PJ_BAK" "$PJ"; die "写 package.json 失败，已还原"; }
  say "    ✓ 已落位到 $DEST 并登记 bundles"
fi

# ---- 6. 注入正文（可选） ----
if [ "$MODE_INJECT" = 1 ]; then
  say "[6] 放入本仓库的 prompt-inject.md（用于公平对比）"
  SRC=""
  for c in ./payload/prompt-inject.md ./prompt-inject.md; do
    [ -f "$c" ] && { SRC="$c"; break; }
  done
  if [ -n "$SRC" ]; then
    cp -f "$SRC" "$H/prompt-inject.md"
    say "    ✓ $(wc -c < "$H/prompt-inject.md") 字节"
  else
    say "    ! 当前目录下没有 prompt-inject.md，跳过"
    say "      需要的话：把本仓库的 payload/prompt-inject.md 放到这里再跑"
  fi
else
  say "[6] 未放注入正文（原版行为：没有 prompt-inject.md 时 apply 会提示「提示词为空」）"
fi

# ---- 7. apply ----
if [ "$MODE_APPLY" = 1 ]; then
  say "[7] 执行 apply 打补丁"
  AI=""
  for d in "${DSH_BASE:-}" /opt/dsh/node_modules/@deepseek-ai /opt/*/node_modules/@deepseek-ai; do
    [ -n "$d" ] && { [ -f "$d/dsh/package.json" ] || [ -d "$d/dsh-agent-instructions" ]; } && { AI="$d"; break; }
  done
  [ -n "$AI" ] || say "    ! 未定位 @deepseek-ai，apply 可能报缺宿主"
  DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --apply
  RC=$?
else
  say "[7] 跳过 apply（--no-apply）"
  RC=0
fi

hr
say "原版安装完成。回 App：设置 → 本机引擎 → 停止 → 启动。"
say ""
say "注意：原版不含以下能力（本仓库 deploy.sh 才有）"
say "  · 风险预检（三档评级 + 弹窗）"
say "  · 命令提示（masscan/hashcat 等）"
say "  · 可视化设置页"
say "  · tuning.json（refusalRetry / injectPosition=both）"
say "  · 关闭自动更新检查"
say "  · 版本哨兵"
hr
exit $RC
