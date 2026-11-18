#!/bin/sh
# cleanup.sh — 清理失败安装留下的半套东西
#
#   sh cleanup.sh            清掉插件注册与插件目录、卸掉命令提示（保留 prompt-inject.md）
#   sh cleanup.sh --all      连 prompt-inject.md 里的 TIER-RULES 段一起抹掉
#
# 背景：上一次 bootstrap 在 apply 阶段停下，但后面几层已经装上了，
#       留下悬空目录和注册项。这个脚本把它们收干净。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="${PURGE_PROFILE:-web}"
MODE="${1:-}"

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }

find_home() {
  for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
    [ -n "$h" ] && [ -f "$h/profiles/$PROFILE/package.json" ] && { printf '%s' "$h"; return 0; }
  done
  return 1
}

H=$(find_home) || { say "找不到 DSH_HOME，没什么可清的"; exit 0; }
say "DSH_HOME = $H"
hr

# 1. 预检插件
if [ -f "$DIR/preflight/install-preflight.sh" ]; then
  say "[1] 预检插件"
  DSH_HOME="$H" PURGE_PROFILE="$PROFILE" sh "$DIR/preflight/install-preflight.sh" uninstall 2>&1 | sed 's/^/    /'
else
  say "[1] 预检插件：脚本不在，手动删 $H/profiles/$PROFILE/node_modules/phone-armor-preflight"
fi
hr

# 2. 命令提示
if [ -f "$DIR/guard/guard-install.sh" ]; then
  say "[2] 命令提示"
  sh "$DIR/guard/guard-install.sh" uninstall 2>&1 | sed 's/^/    /'
else
  say "[2] 命令提示：脚本不在，手动还原 /usr/bin 下 *.phone-armor-real"
fi
hr

# 3. 破甲插件目录（apply 失败时 armor.sh 会删，这里兜一次）
say "[3] 破甲插件目录"
for d in "$H/profiles/$PROFILE/node_modules/dsh-purge-community"; do
  if [ -d "$d" ]; then
    rm -rf "$d" && say "    已删除 $d"
  else
    say "    不存在（已回滚）"
  fi
done
hr

# 4. profile.bundles 里的残留
say "[4] profile.bundles"
N="${DSH_NODE:-$(command -v node 2>/dev/null)}"
if [ -n "${N:-}" ] && [ -x "$N" ]; then
  "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    const o = JSON.parse(fs.readFileSync(p, "utf8"));
    const b = o?.dsh?.profile?.bundles;
    if (!Array.isArray(b)) { console.log("    没有 bundles 字段"); process.exit(0); }
    const keep = b.filter((x) => x !== "dsh-purge-community");
    if (keep.length === b.length) { console.log("    干净"); process.exit(0); }
    o.dsh.profile.bundles = keep;
    fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
    console.log("    已摘除 dsh-purge-community");
  ' "$H/profiles/$PROFILE/package.json"
else
  say "    找不到 node，跳过"
fi
hr

# 5. prompt-inject.md
say "[5] prompt-inject.md"
TARGET="$H/prompt-inject.md"
if [ -f "$TARGET" ]; then
  if [ "$MODE" = "--all" ]; then
    "$N" -e '
      const fs = require("fs"), p = process.argv[1];
      const B = "<!-- TIER-RULES:BEGIN -->", E = "<!-- TIER-RULES:END -->";
      let t = fs.readFileSync(p, "utf8");
      const i = t.indexOf(B), j = t.indexOf(E);
      if (i < 0 || j <= i) { console.log("    没有 TIER-RULES 段"); process.exit(0); }
      t = (t.slice(0, i) + t.slice(j + E.length)).replace(/^\s+/, "");
      fs.writeFileSync(p, t);
      console.log("    已抹掉 TIER-RULES 段，剩 " + t.length + " 字节");
    ' "$TARGET"
  else
    say "    保留（$(wc -c < "$TARGET") 字节）。它只在 dsh-purge 插件加载时才被读取，"
    say "    现在插件已撤，它就是个普通文件。要一并抹掉：sh cleanup.sh --all"
  fi
else
  say "    不存在"
fi
hr

say "清理完成。"
say ""
say "⚠ 重要：引擎进程还活着，插件可能把 prompt-inject.md 再写回来（BUGS.md #10）。"
say "   正确顺序是「先停 → 再删 → 再启动」："
say ""
say "     1. App → 设置 → 本机引擎 → 停止     ← 先杀掉进程，回写源才消失"
say "     2. rm -f $H/prompt-inject.md"
say "     3. App → 设置 → 本机引擎 → 启动"
say ""
say "   删完立刻重启会失败：重启过程中旧进程还活着，可能又写一次。"
hr
say ""
say "重跑（二选一）："
say "  完整：DSH_BASE=/opt/dsh/node_modules/@deepseek-ai sh armor.sh install"
say "  只上规则不动源码：DSH_BASE=/opt/dsh/node_modules/@deepseek-ai ARMOR_SKIP_APPLY=1 sh armor.sh install"
