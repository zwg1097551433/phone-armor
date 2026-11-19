#!/bin/sh
# deploy.sh — 自愈式一键部署
#
# 设计目标：让 agent 只跑一条命令。脚本自己完成
#   探测 → 安装 → 判定结果 → 失败时自动换方案重试 → 输出精简结论
#
# 输出刻意压到十几行：每步一行，失败才展开。完整日志留在 deploy.log。
#
# 用法：
#   sh deploy.sh            正常部署
#   sh deploy.sh --rules    只上规则层，不打宿主源码补丁（ARMOR_SKIP_APPLY=1）
#   sh deploy.sh --log      部署后看完整日志
set -u

OWNER="${ARMOR_OWNER:-zwg1097551433}"
REPO="${ARMOR_REPO:-phone-armor}"
BRANCH="${ARMOR_BRANCH:-main}"
WORK="${ARMOR_DIR:-/root/phone-armor}"
LOG="$WORK/deploy.log"
MODE="${1:-}"
RULES_ONLY=0
[ "$MODE" = "--rules" ] && RULES_ONLY=1

say()  { printf '%s\n' "$*"; }
hr()   { say "----------------------------------------"; }
step() { printf '[%s] %-10s ' "$1" "$2"; }
ok()   { printf '✓ %s\n' "$*"; }
bad()  { printf '✗ %s\n' "$*"; }
info() { printf '             %s\n' "$*"; }

if [ "$MODE" = "--log" ]; then
  [ -f "$LOG" ] || { say "还没有日志：$LOG"; exit 1; }
  exec less "$LOG" 2>/dev/null || exec cat "$LOG"
fi

mkdir -p "$WORK" 2>/dev/null || { say "无法创建 $WORK"; exit 1; }
cd "$WORK" || { say "进不去 $WORK"; exit 1; }
: > "$LOG"

hr
say "phone-armor 自愈式部署"
say "仓库 $OWNER/$REPO@$BRANCH   日志 $LOG"
hr

# ---------------------------------------------------------------- 1. node
step 1 "node"
N="${DSH_NODE:-$(command -v node 2>/dev/null)}"
if [ -z "${N:-}" ]; then
  for c in /opt/dsh/node/bin/node /opt/dsh-app/node/bin/node /opt/dsh-app/*/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$c" ] && { N="$c"; break; }
  done
fi
if [ -z "${N:-}" ] || [ ! -x "$N" ]; then
  bad "找不到 node"; info "先在 App 里启动一次本机引擎再重跑"; exit 1
fi
ok "$("$N" -v 2>/dev/null) @ $N"
export DSH_NODE="$N"

# ---------------------------------------------------------------- 2. bootstrap
step 2 "自举脚本"
if ! "$N" -e '
  const [u, o] = process.argv.slice(1);
  fetch(u).then(async (r) => {
    if (!r.ok) throw new Error("HTTP " + r.status);
    const b = Buffer.from(await r.arrayBuffer());
    if (!b.length) throw new Error("empty");
    require("fs").writeFileSync(o, b);
  }).catch((e) => { console.error(e.message); process.exit(1); });
' "https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/bootstrap.sh" bootstrap.sh 2>>"$LOG"; then
  bad "下载失败"
  info "换源重试：ARMOR_MIRROR=https://cdn.jsdelivr.net/gh/$OWNER/$REPO@$BRANCH sh deploy.sh"
  exit 1
fi
ok "$(wc -c < bootstrap.sh) 字节"

# ---------------------------------------------------------------- 3. 宿主探测
step 3 "宿主"
AI=""
for d in "${DSH_BASE:-}" /opt/dsh/node_modules/@deepseek-ai /opt/*/node_modules/@deepseek-ai \
         /opt/*/*/node_modules/@deepseek-ai "$HOME/.dsh"/dsh-runtimes/*/node_modules/@deepseek-ai \
         "$HOME/.dsh"/node_modules/@deepseek-ai; do
  [ -n "$d" ] && { [ -f "$d/dsh/package.json" ] || [ -d "$d/dsh-agent-instructions" ]; } && { AI="$d"; break; }
done
if [ -z "$AI" ]; then
  AI=$(find /opt "$HOME/.dsh/node_modules" -maxdepth 6 -type d -name '@deepseek-ai' 2>/dev/null | head -1)
fi
if [ -z "$AI" ]; then
  bad "未定位"
  info "跑 sh armor.sh check 看「环境里实际存在的 @deepseek-ai 目录」"
  info "或显式指定：DSH_BASE=<路径> sh deploy.sh"
  exit 1
fi
export DSH_BASE="$AI"
ok "$AI"

# ---------------------------------------------------------------- 4. 首次安装
step 4 "安装"
# root 下 [ -w ] 恒真，必须真写一次才知道
WRITABLE=0
if ( : > "$AI/.armor-wtest" ) 2>/dev/null; then
  rm -f "$AI/.armor-wtest" 2>/dev/null
  WRITABLE=1
fi

if [ "$RULES_ONLY" = 1 ] || [ "$WRITABLE" = 0 ]; then
  [ "$WRITABLE" = 0 ] && info "宿主只读，自动切到规则层模式"
  ARMOR_SKIP_APPLY=1 sh bootstrap.sh >>"$LOG" 2>&1
else
  sh bootstrap.sh >>"$LOG" 2>&1
fi
RC=$?
if [ "$RC" = 0 ]; then
  ok "完成（细节见 deploy.log）"
else
  bad "失败 rc=$RC（见 deploy.log）"
fi

# ---------------------------------------------------------------- 5. 判定 + 自愈
step 5 "补丁"
read_applied() {
  DSH_BASE="$AI" sh "$WORK/armor.sh" status 2>/dev/null |
    sed -n 's/.*补丁 \([0-9][0-9]*\)\/\([0-9][0-9]*\) 已清洗.*/\1/p' | head -1
}
A=$(read_applied)

if [ "$RULES_ONLY" = 1 ] || [ "$WRITABLE" = 0 ]; then
  ok "规则层模式（源码补丁未打，审批与沙箱保持原样）"
elif [ -z "${A:-}" ]; then
  bad "读不到状态"
  info "见日志：sh deploy.sh --log"
  RC=1
elif [ "$A" -ge 60 ]; then
  ok "$A/86 已清洗"
elif [ "$A" -ge 1 ]; then
  info "$A/86 命中偏低，自动 repair 一次"
  DSH_BASE="$AI" sh "$WORK/armor.sh" repair >>"$LOG" 2>&1
  A2=$(read_applied)
  if [ -n "${A2:-}" ] && [ "$A2" -gt "$A" ]; then
    ok "$A2/86 已清洗（repair 补齐）"
  else
    bad "$A/86（repair 无改善）"
    info "见 BUGS.md #6：锚点可能漂移"
    RC=1
  fi
else
  bad "0/86 —— 宿主定位到了但补丁没命中"
  info "见 BUGS.md #6 / #8；把 sh armor.sh status 的输出贴回来"
  RC=1
fi

# ---------------------------------------------------------------- 6. 预检 + 提示
step 6 "预检"
if [ -d "$HOME/.dsh/profiles/web/node_modules/phone-armor-preflight" ] &&
   grep -q phone-armor-preflight "$HOME/.dsh/profiles/web/cordis.patch.yml" 2>/dev/null; then
  ok "已注册"
else
  bad "未装成"; info "见日志：sh deploy.sh --log"
fi

step 7 "命令提示"
if [ -x /opt/phone-armor/guard.sh ]; then
  ok "已装（默认只提示不拦截）"
else
  bad "未装成"
fi

hr
if [ "$RC" = 0 ]; then
  say "部署完成"
  say ""
  say "下一步：回 App → 设置 → 本机引擎 → 停止 → 启动"
  say "重启后补丁和插件才会加载。"
else
  say "部署未完成，完整日志：$LOG"
  say "把上面几行和日志末尾 15 行一起贴回来："
  say "  tail -15 $LOG"
fi
hr
exit $RC
