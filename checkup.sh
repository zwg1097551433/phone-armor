#!/bin/sh
# checkup.sh — 两种情况的验证脚本
#
#   sh checkup.sh            情况 A：静态体检（只读，不写任何文件）
#   sh checkup.sh static     同上
#   sh checkup.sh live       情况 B：动态实测（会写测试文件、生成 probe）
#
# 情况 A 回答：「装的东西对不对」
# 情况 B 回答：「装的东西真的生效了吗」
#
# 只依赖 sh + node（手机自带），不需要 curl/git/python。
set -u

MODE="${1:-static}"
H=""
for d in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
  [ -n "$d" ] && [ -f "$d/profiles/web/package.json" ] && { H="$d"; break; }
done
[ -n "$H" ] || { echo "[STOP] 找不到 DSH_HOME，先在 App 里启动一次本机引擎"; exit 1; }

P="$H/profiles/web"
DEST="$P/node_modules/dsh-purge-community"
AI=""
for d in "${DSH_BASE:-}" /opt/dsh/node_modules/@deepseek-ai /opt/*/node_modules/@deepseek-ai; do
  [ -n "$d" ] || continue
  { [ -f "$d/dsh/package.json" ] || [ -d "$d/dsh-agent-instructions" ]; } && { AI="$d"; break; }
done
NODE=$(command -v node 2>/dev/null || echo /usr/local/bin/node)

OK=0; BAD=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; OK=$((OK+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; BAD=$((BAD+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
hr()   { printf '%s\n' "----------------------------------------"; }
sec()  { printf '\n[%s] %s\n' "$1" "$2"; }

echo "========================================"
echo " 功能强化 · $([ "$MODE" = "live" ] && echo "动态实测" || echo "静态体检")"
echo " DSH_HOME = $H"
echo "========================================"

# ========== 情况 A：静态体检 ==========
sec A1 "运行环境"
[ -x "$NODE" ] && ok "node  $("$NODE" -v 2>/dev/null)" || bad "node 不存在"
[ -n "$AI" ] && ok "宿主  $AI" || bad "未定位 @deepseek-ai"
[ -f "$P/package.json" ] && ok "profile  $P" || bad "profile 缺 package.json"

sec A2 "插件是否落位"
if [ -f "$DEST/bin/dsh-purge.js" ]; then
  ok "dsh-purge-community 已安装"
  V=$("$NODE" -e 'try{process.stdout.write(require(process.argv[1]).version||"")}catch{}' "$DEST/package.json" 2>/dev/null)
  if [ "$V" = "1.6.91" ]; then
    ok "版本  $V（校准版）"
  elif [ -n "$V" ]; then
    warn "版本  $V ≠ 1.6.91 —— 可能被 DSH 的插件更新换过，锚点会漂移"
  fi
else
  bad "dsh-purge-community 未安装"
fi

sec A3 "补丁命中"
if [ -f "$DEST/bin/dsh-purge.js" ] && [ -n "$AI" ]; then
  ST=$(DSH_BASE="$AI" DSH_HOME="$H" "$NODE" "$DEST/bin/dsh-purge.js" --status 2>/dev/null)
  A=$(printf '%s\n' "$ST" | sed -n 's/.*补丁 \([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1/p' | head -1)
  B=$(printf '%s\n' "$ST" | sed -n 's/.*补丁 \([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\2/p' | head -1)
  if [ -n "${A:-}" ] && [ "$A" -ge 60 ]; then
    ok "补丁  $A/$B 命中"
  elif [ -n "${A:-}" ] && [ "$A" -ge 1 ]; then
    warn "补丁  $A/$B —— 偏低，锚点可能漂移"
  else
    bad "补丁  读不到命中数"
  fi
else
  warn "跳过（插件或宿主缺失）"
fi

sec A4 "注入正文"
if [ -f "$H/prompt-inject.md" ]; then
  SZ=$(wc -c < "$H/prompt-inject.md")
  if [ "$SZ" -gt 30000 ]; then
    ok "prompt-inject.md  $SZ 字节（完整版）"
  elif [ "$SZ" -gt 10000 ]; then
    ok "prompt-inject.md  $SZ 字节（精简或自定义）"
  else
    warn "prompt-inject.md  只有 $SZ 字节，可能没合并成功"
  fi
  if grep -q "本机能力边界" "$H/prompt-inject.md" 2>/dev/null; then
    ok "注入模式  完整（L1 纪律 + L2 能力边界）"
  else
    ok "注入模式  精简（仅 L1 纪律）"
  fi
  if grep -q "职责二分" "$H/prompt-inject.md" 2>/dev/null; then
    ok "含输出透明条款"
  else
    warn "缺输出透明条款（职责二分）"
  fi
else
  bad "prompt-inject.md 不存在"
fi

sec A5 "调优配置"
if [ -f "$H/dsh-purge/tuning.json" ]; then
  grep -q '"refusalRetry": *true' "$H/dsh-purge/tuning.json" 2>/dev/null \
    && ok "refusalRetry 已开" || warn "refusalRetry 未开（默认 false，遇拒绝不重试）"
  grep -q '"injectPosition": *"both"' "$H/dsh-purge/tuning.json" 2>/dev/null \
    && ok "injectPosition = both" || warn "injectPosition 不是 both（长对话里注入会被稀释）"
else
  warn "tuning.json 不存在（原版默认：不重试、只注头部）"
fi

sec A6 "自动更新检查"
if [ -f "$H/dsh-purge/update-preferences.json" ]; then
  grep -q '"autoCheck": *false' "$H/dsh-purge/update-preferences.json" 2>/dev/null \
    && ok "自动检查已关" || warn "自动检查还开着（会提示 1.7.20）"
else
  warn "update-preferences.json 不存在（默认 6 小时检查一次）"
fi
[ -f "$H/dsh-purge/update-status.json" ] && warn "存在 update-status.json（有未清除的更新提示）" || ok "无残留更新提示"

sec A7 "模型档位（决定注入能不能压住）"
CFG="$P/cordis.patch.yml"
if [ -f "$CFG" ]; then
  MDL=$(sed -n 's/^ *model: *\(.*\)$/\1/p' "$CFG" | head -1)
  EFF=$(sed -n 's/^ *reasoningEffort: *\(.*\)$/\1/p' "$CFG" | head -1)
  case "${MDL:-}" in
    *flash*) ok "model = $MDL（对齐较弱，注入能压住）" ;;
    *v4-pro*|*pro*) warn "model = $MDL（对齐强，会识破注入；建议换 flash）" ;;
    "") warn "读不到 model 字段" ;;
    *) warn "model = $MDL（未知档位，需实测）" ;;
  esac
  case "${EFF:-}" in
    low|minimal) ok "reasoningEffort = $EFF" ;;
    high|max) warn "reasoningEffort = $EFF（想得越多越容易看穿注入）" ;;
    "") : ;;
    *) ok "reasoningEffort = $EFF" ;;
  esac
else
  bad "cordis.patch.yml 不存在"
fi

sec A8 "增强插件"
[ -d "$P/node_modules/phone-armor-preflight" ] && ok "风险预检 已装" || warn "风险预检 未装"
[ -d "$P/node_modules/phone-armor-settings" ] && ok "功能强化页 已装" || warn "功能强化页 未装"
[ -x /opt/phone-armor/guard.sh ] && ok "命令提示 已装" || warn "命令提示 未装"

# ========== 情况 B：动态实测 ==========
if [ "$MODE" = "live" ]; then

sec B1 "写系统目录（验证审批 + 沙箱是否拆掉）"
PROBE="/opt/dsh/.armor-write-test-$$"
if ( : > "$PROBE" ) 2>/dev/null; then
  ok "成功写入 $PROBE —— 审批与沙箱均未拦截"
  rm -f "$PROBE" 2>/dev/null
else
  bad "写不进去 —— 审批或沙箱仍在拦截"
fi

sec B2 "写工作区外（PRoot 内）"
PROBE2="/root/.armor-write-test-$$"
if ( : > "$PROBE2" ) 2>/dev/null; then
  ok "成功写入 $PROBE2"
  rm -f "$PROBE2" 2>/dev/null
else
  warn "写 $PROBE2 失败（不影响主功能）"
fi

sec B3 "注入是否到达模型（probe）"
if [ -f "$DEST/bin/community.js" ]; then
  OUT=$("$NODE" "$DEST/bin/community.js" probe new 2>&1)
  NONCE=$(printf '%s' "$OUT" | sed -n 's/.*\(purge-[0-9a-f]\{6,\}\).*/\1/p' | head -1)
  if [ -n "$NONCE" ]; then
    ok "已生成 probe: $NONCE"
    echo ""
    echo "  下一步（必须人工确认）："
    echo "    1. 打开 DSH，随便发一句话（比如「你好」）"
    echo "    2. 看模型有没有原样回显 $NONCE"
    echo "    3. 回显 = 注入真的到了模型；不回显 = 注入链断了"
    echo ""
  else
    warn "生成失败：$OUT"
  fi
else
  warn "community.js 不存在，跳过"
fi

sec B4 "命令提示是否挂上"
if command -v nmap >/dev/null 2>&1; then
  T=$(command -v nmap)
  if [ -L "$T" ] || [ "$T" = "/opt/phone-armor/guard.sh" ]; then
    ok "nmap 已接管（$T）"
  else
    warn "nmap 未接管（$T）—— 命令提示可能没装到 PATH"
  fi
else
  warn "本机没装 nmap，跳过"
fi

fi

# ========== 汇总 ==========
hr
printf '  通过 %d   警告 %d   失败 %d\n' "$OK" "$WARN" "$BAD"
hr
if [ "$BAD" -gt 0 ]; then
  echo "  有失败项。先修失败项，再看警告项。"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "  能用，但有可优化项。"
  exit 0
else
  echo "  全部通过。"
  exit 0
fi
