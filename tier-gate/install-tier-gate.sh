#!/bin/sh
# install-tier-gate.sh — 前端闸门的安装 / 卸载 / 状态
#
#   sh install-tier-gate.sh install     装（拷插件 + 在 cordis.patch.yml 注册）
#   sh install-tier-gate.sh uninstall   卸（摘注册 + 删插件目录）
#   sh install-tier-gate.sh status      看状态
#
# 安全性：改 cordis.patch.yml 之前先备份；写入后用 YAML 解析器校验；
#         校验失败自动还原。手机上起不来 App 是灾难，所以这一步必须稳。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="${PURGE_PROFILE:-web}"
CMD="${1:-status}"
PKG="phone-armor-tier-gate"

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

H=$(find_home) || die "找不到 DSH_HOME（\$HOME/.dsh 或 /root/.dsh）。先在 App 里启动一次本机引擎。"
N="${DSH_NODE:-$(find_node)}"
[ -n "$N" ] || die "找不到 node"
PATCH="$H/profiles/$PROFILE/cordis.patch.yml"
DEST="$H/profiles/$PROFILE/node_modules/$PKG"

# YAML 校验：优先用 profile 自带的 yaml 包
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
  hr; say "phone-armor 前端闸门 · 安装"; hr
  [ -f "$PATCH" ] || die "没有 $PATCH —— profile 没初始化过"

  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
  BAK="$H/armor-backup-$STAMP"
  mkdir -p "$BAK" || die "无法创建备份目录"
  cp -f "$PATCH" "$BAK/cordis.patch.yml.orig" || die "备份失败，中止"
  say "[1] 备份 → $BAK/cordis.patch.yml.orig"

  mkdir -p "$DEST/lib" || die "无法创建 $DEST"
  cp -f "$DIR/package.json" "$DEST/" || die "复制 package.json 失败"
  cp -f "$DIR/lib/index.js" "$DEST/lib/" || die "复制 index.js 失败"
  cp -f "$DIR/lib/client.js" "$DEST/lib/" || die "复制 client.js 失败"
  say "[2] 插件 → $DEST"

  if grep -q "$PKG" "$PATCH" 2>/dev/null; then
    say "[3] cordis.patch.yml 里已有注册，跳过"
  else
    {
      printf '\n# phone-armor 能力边界闸门（卸载：sh install-tier-gate.sh uninstall）\n'
      printf -- '- insert:\n'
      printf '    - id: %s\n' "$PKG"
      printf '      name: %s\n' "$PKG"
    } >> "$PATCH" || { cp -f "$BAK/cordis.patch.yml.orig" "$PATCH"; die "写 cordis.patch.yml 失败，已还原"; }
    say "[3] 已写入 cordis.patch.yml 的 insert 条目"
  fi

  R=$(yaml_check)
  case "$R" in
    OK*) say "[4] YAML 校验通过 $R" ;;
    SKIP*) say "[4] 环境里没有 yaml 包，跳过结构校验（请看上面有没有报错）" ;;
    *)
      say "[4] YAML 校验失败：$R"
      cp -f "$BAK/cordis.patch.yml.orig" "$PATCH"
      rm -rf "$DEST"
      die "已还原，App 不受影响"
      ;;
  esac

  hr
  say "装好了。回 App：设置 → 本机引擎 → 停止 → 启动。"
  say "进任意会话会弹「这台手机能做什么」，第三档红字。"
  say "想再看到：清掉浏览器 localStorage 的 phone-armor.tier-gate.ack，或点「每次启动都提醒」。"
}

do_uninstall() {
  hr; say "phone-armor 前端闸门 · 卸载"; hr
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
          const block = lines.slice(i, j).join("\n");
          if (block.includes(marker)) { i = j - 1; continue; }
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
  hr; say "phone-armor 前端闸门 · 状态"; hr
  say "DSH_HOME   $H"
  say "插件目录   $([ -d "$DEST" ] && echo "已安装 ✓" || echo "未安装")"
  if [ -f "$PATCH" ]; then
    if grep -q "$PKG" "$PATCH" 2>/dev/null; then say "注册状态   已注册 ✓"; else say "注册状态   未注册"; fi
  fi
  say ""
  say "cordis.patch.yml 末尾："
  tail -8 "$PATCH" 2>/dev/null | sed 's/^/    /'
}

case "$CMD" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) say "用法：sh install-tier-gate.sh [install|uninstall|status]"; exit 1 ;;
esac
