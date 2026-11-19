#!/bin/sh
# install-settings.sh — 设置页插件（手机强化）的安装 / 卸载 / 状态
#
#   sh install-settings.sh install     装（拷插件 + 放强化包 + 注册）
#   sh install-settings.sh uninstall   卸
#   sh install-settings.sh status      看状态
#
# 装完后：设置面板里会多一个「手机强化」分节，三个开关。
# 不想装也不影响核心功能 —— 这个插件只是给可选模块一个图形开关。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="${PURGE_PROFILE:-web}"
CMD="${1:-status}"
PKG="phone-armor-settings"

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
  for c in "$(command -v node 2>/dev/null)" /opt/dsh/node/bin/node /opt/dsh-app/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

H=$(find_home) || die "找不到 DSH_HOME。先在 App 里启动一次本机引擎。"
N="${DSH_NODE:-$(find_node)}"
[ -n "$N" ] || die "找不到 node"
PATCH="$H/profiles/$PROFILE/cordis.patch.yml"
DEST="$H/profiles/$PROFILE/node_modules/$PKG"
PA="$H/phone-armor"

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
  hr; say "phone-armor 设置页 · 安装"; hr
  [ -f "$PATCH" ] || die "没有 $PATCH —— profile 没初始化过"
  [ -f "$DIR/lib/client.js" ] || die "找不到 $DIR/lib/client.js"

  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
  BAK="$H/armor-backup-$STAMP"
  mkdir -p "$BAK" || die "无法创建备份目录"
  cp -f "$PATCH" "$BAK/cordis.patch.yml.orig" || die "备份失败，中止"
  say "[1] 备份 → $BAK/cordis.patch.yml.orig"

  # 插件本体
  mkdir -p "$DEST/lib" || die "无法创建 $DEST"
  cp -f "$DIR/package.json" "$DEST/" || die "复制 package.json 失败"
  cp -f "$DIR/lib/index.js" "$DEST/lib/" || die "复制 index.js 失败"
  cp -f "$DIR/lib/client.js" "$DEST/lib/" || die "复制 client.js 失败"
  say "[2] 插件 → $DEST"

  # 强化包正文（boost 开关时由 host 侧合并）
  mkdir -p "$PA" || die "无法创建 $PA"
  if [ -f "$DIR/../prompt/boost-nsfw.md" ]; then
    cp -f "$DIR/../prompt/boost-nsfw.md" "$PA/boost.md"
    say "[3] 强化包 → $PA/boost.md ($(wc -c < "$PA/boost.md") 字节)"
  else
    say "[3] 没找到 prompt/boost-nsfw.md，boost 开关会不可用"
  fi

  # 默认状态：核心开、两个可选关
  if [ -f "$PA/modules.json" ]; then
    say "[4] 已有 modules.json，保留"
  else
    cat > "$PA/modules.json" <<'JSONEOF'
{
  "core": true,
  "ext": false,
  "boost": false
}
JSONEOF
    chmod 600 "$PA/modules.json" 2>/dev/null
    say "[4] modules.json 已初始化（core 开，ext / boost 关）"
  fi

  # 注册
  if grep -q "$PKG" "$PATCH" 2>/dev/null; then
    say "[5] cordis.patch.yml 里已有注册，跳过"
  else
    {
      printf '\n# phone-armor 设置页（卸载：sh install-settings.sh uninstall）\n'
      printf -- '- insert:\n'
      printf '    - id: %s\n' "$PKG"
      printf '      name: %s\n' "$PKG"
    } >> "$PATCH" || { cp -f "$BAK/cordis.patch.yml.orig" "$PATCH"; die "写 cordis.patch.yml 失败，已还原"; }
    say "[5] 已写入 cordis.patch.yml 的 insert 条目"
  fi

  R=$(yaml_check)
  case "$R" in
    OK*) say "[6] YAML 校验通过 $R" ;;
    SKIP*) say "[6] 环境里没有 yaml 包，跳过结构校验" ;;
    *)
      say "[6] YAML 校验失败：$R"
      cp -f "$BAK/cordis.patch.yml.orig" "$PATCH"
      rm -rf "$DEST"
      die "已还原，App 不受影响"
      ;;
  esac

  hr
  say "装好了。回 App：设置 → 本机引擎 → 停止 → 启动。"
  say ""
  say "重启后进设置面板，会看到「手机强化」分节："
  say "  核心            ✅ 必装，不可关"
  say "  外部生图通道     ⬜ 默认关"
  say "  提示词强化包     ⬜ 默认关"
}

do_uninstall() {
  hr; say "phone-armor 设置页 · 卸载"; hr
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
  say "卸载完成（modules.json 与 boost.md 保留，重装后状态不丢）。"
  say "回 App 停止再启动引擎生效。"
}

do_status() {
  hr; say "phone-armor 设置页 · 状态"; hr
  say "DSH_HOME   $H"
  say "插件目录   $([ -d "$DEST" ] && echo "已安装 ✓" || echo "未安装")"
  if [ -f "$PATCH" ]; then
    if grep -q "$PKG" "$PATCH" 2>/dev/null; then say "注册状态   已注册 ✓"; else say "注册状态   未注册"; fi
  fi
  if [ -f "$PA/modules.json" ]; then
    say "模块状态："
    sed 's/^/    /' "$PA/modules.json"
  fi
  say ""
  say "cordis.patch.yml 末尾："
  tail -6 "$PATCH" 2>/dev/null | sed 's/^/    /'
}

case "$CMD" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) say "用法：sh install-settings.sh [install|uninstall|status]"; exit 1 ;;
esac
