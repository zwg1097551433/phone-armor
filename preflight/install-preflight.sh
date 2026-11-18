#!/bin/sh
# install-preflight.sh — 预检插件的安装 / 卸载 / 状态
#
#   sh install-preflight.sh install     装（拷插件 + 在 cordis.patch.yml 注册）
#   sh install-preflight.sh uninstall   卸（摘注册 + 删插件目录）
#   sh install-preflight.sh status      看状态
#
# 这是个 host 侧插件：挂在 agent/pre-step，用 ctx.llm 做判定、ctx.userQuestions 弹窗。
# 任何异常都会放行，所以它挂了最多是「不弹窗」，不会让用户干不了活。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="${PURGE_PROFILE:-web}"
CMD="${1:-status}"
PKG="phone-armor-preflight"

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

find_home() {
  for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
    [ -n "$h" ] && [ -f "$h/profiles/$PROFILE/package.json" ] && { printf '%s' "$h"; return 0; }
  done
  return 1
}
find_node() {
  for c in "$(command -v node 2>/dev/null)" /opt/dsh-app/node/bin/node /opt/dsh-app/*/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

H=$(find_home) || die "找不到 DSH_HOME。先在 App 里启动一次本机引擎。"
N="${DSH_NODE:-$(find_node)}"
[ -n "$N" ] || die "找不到 node"
PATCH="$H/profiles/$PROFILE/cordis.patch.yml"
DEST="$H/profiles/$PROFILE/node_modules/$PKG"

yaml_check() {
  NODE_PATH="$H/profiles/$PROFILE/node_modules" "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    let YAML;
    try { YAML = require("yaml"); } catch (e) { console.log("SKIP(no yaml)"); process.exit(0); }
    const doc = YAML.parse(fs.readFileSync(p, "utf8"));
    if (!Array.isArray(doc)) { console.error("NOT_ARRAY"); process.exit(1); }
    console.log("OK(" + doc.length + ")");
  ' "$PATCH" 2>&1
}

do_install() {
  hr; say "phone-armor 预检插件 · 安装"; hr
  [ -f "$PATCH" ] || die "没有 $PATCH —— profile 没初始化过"
  [ -f "$DIR/lib/index.js" ] || die "找不到 $DIR/lib/index.js"

  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
  BAK="$H/armor-backup-$STAMP"
  mkdir -p "$BAK" || die "无法创建备份目录"
  cp -f "$PATCH" "$BAK/cordis.patch.yml.orig" || die "备份失败，中止"
  say "[1] 备份 → $BAK/cordis.patch.yml.orig"

  mkdir -p "$DEST/lib" || die "无法创建 $DEST"
  cp -f "$DIR/package.json" "$DEST/" || die "复制 package.json 失败"
  cp -f "$DIR/lib/index.js" "$DEST/lib/" || die "复制 index.js 失败"
  say "[2] 插件 → $DEST"

  if grep -q "$PKG" "$PATCH" 2>/dev/null; then
    say "[3] cordis.patch.yml 里已有注册，跳过"
  else
    {
      printf '\n# phone-armor 工作指令预检（卸载：sh install-preflight.sh uninstall）\n'
      printf -- '- insert:\n'
      printf '    - id: %s\n' "$PKG"
      printf '      name: %s\n' "$PKG"
      printf '      config:\n'
      printf '        enabled: true\n'
      printf '        askAtOrAbove: 2\n'
      printf '        secondSendAtOrAbove: 2\n'
    } >> "$PATCH" || { cp -f "$BAK/cordis.patch.yml.orig" "$PATCH"; die "写 cordis.patch.yml 失败，已还原"; }
    say "[3] 已写入 cordis.patch.yml 的 insert 条目"
  fi

  R=$(yaml_check)
  case "$R" in
    OK*) say "[4] YAML 校验通过 $R" ;;
    SKIP*) say "[4] 环境里没有 yaml 包，跳过结构校验" ;;
    *)
      say "[4] YAML 校验失败：$R"
      cp -f "$BAK/cordis.patch.yml.orig" "$PATCH"
      rm -rf "$DEST"
      die "已还原，App 不受影响"
      ;;
  esac

  hr
  say "装好了。回 App：设置 → 本机引擎 → 停止 → 启动。"
  say ""
  say "之后每次你发出工作指令："
  say "  1. 主 agent 先不开始思考"
  say "  2. 预检用一次短 LLM 调用（约 200 token）把指令归入三档"
  say "  3. 第二/三档弹出风险卡片，你选「继续执行」才放行，「取消」则这一轮不执行"
  say "  4. 第一档静默通过，不打扰"
}

do_uninstall() {
  hr; say "phone-armor 预检插件 · 卸载"; hr
  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
  BAK="$H/armor-backup-$STAMP"
  mkdir -p "$BAK"; cp -f "$PATCH" "$BAK/cordis.patch.yml.orig" 2>/dev/null

  if [ -f "$PATCH" ]; then
    "$N" -e '
      const fs = require("fs"), p = process.argv[1], marker = process.argv[2];
      const lines = fs.readFileSync(p, "utf8").split("\n");
      const out = [];
      for (let i = 0; i < lines.length; i++) {
        if (/^- /.test(lines[i])) {
          let j = i + 1;
          while (j < lines.length && !/^- /.test(lines[j])) j++;
          if (lines.slice(i, j).join("\n").includes(marker)) { i = j - 1; continue; }
        }
        out.push(lines[i]);
      }
      fs.writeFileSync(p, out.join("\n"));
    ' "$PATCH" "$PKG" || die "改 cordis.patch.yml 失败"
    say "[1] 已从 cordis.patch.yml 摘除"
  fi
  rm -rf "$DEST" && say "[2] 已删除 $DEST"
  say ""
  say "卸载完成。回 App 停止再启动引擎生效。"
}

do_status() {
  hr; say "phone-armor 预检插件 · 状态"; hr
  say "DSH_HOME   $H"
  say "插件目录   $([ -d "$DEST" ] && echo "已安装 ✓" || echo "未安装")"
  if [ -f "$PATCH" ]; then
    if grep -q "$PKG" "$PATCH" 2>/dev/null; then say "注册状态   已注册 ✓"; else say "注册状态   未注册"; fi
  fi
  say ""
  say "cordis.patch.yml 末尾："
  tail -10 "$PATCH" 2>/dev/null | sed 's/^/    /'
}

case "$CMD" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) say "用法：sh install-preflight.sh [install|uninstall|status]"; exit 1 ;;
esac
