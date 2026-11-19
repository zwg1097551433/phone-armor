#!/bin/sh
# bootstrap.sh — 远程自举：在 DSH Go 的本机引擎里一条命令把破甲装好
#
# 用法（手机 PRoot 里）：
#   node -e "..."         # 下载本文件（见 INSTALL-PROMPT.txt）
#   sh bootstrap.sh
#
# 环境变量：
#   ARMOR_MIRROR   自定义镜像前缀（优先使用）
#   ARMOR_DIR      工作目录，默认 /root/phone-armor
#   DSH_NODE       指定 node
#   PURGE_PROFILE  profile 名，默认 web
#
# 设计：不依赖 curl/wget/git —— 只用 node 内建 fetch 下载，node 算 SHA256。
set -u

OWNER="${ARMOR_OWNER:-zwg1097551433}"
REPO="${ARMOR_REPO:-phone-armor}"
BRANCH="${ARMOR_BRANCH:-main}"
WORK="${ARMOR_DIR:-/root/phone-armor}"
TGZ_NAME="dsh-purge-community-1.6.91.tgz"
SHA_TGZ="ae22bb7d1ac1e055102c8fbd24cf2eedc282a94bfa3fb09e7ab91226fc033058"

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

hr
say "phone-armor bootstrap  ($OWNER/$REPO@$BRANCH)"
hr

[ -n "$OWNER" ] && [ -n "$REPO" ] || die "缺少仓库信息。用 ARMOR_OWNER=用户名 ARMOR_REPO=仓库名 sh bootstrap.sh 重跑"

# ---------------------------------------------------------------- 1. node
N="${DSH_NODE:-$(command -v node 2>/dev/null)}"
if [ -z "${N:-}" ]; then
  for c in /opt/dsh-app/node/bin/node /opt/dsh-app/*/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$c" ] && { N="$c"; break; }
  done
fi
[ -n "${N:-}" ] && [ -x "$N" ] || die "找不到 node。DSH Go 本机引擎自带，先在 App 里启动一次引擎再试"
MAJ=$("$N" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$MAJ" -ge 18 ] || die "node $("$N" -v 2>/dev/null) 过低，需要 >=18（fetch 依赖）"
say "[1] node = $N ($("$N" -v 2>/dev/null))"

# ---------------------------------------------------------------- 2. 下载器
dl() { # $1=url $2=out
  "$N" -e '
    const [u, o] = process.argv.slice(1);
    fetch(u)
      .then(async (r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        const b = Buffer.from(await r.arrayBuffer());
        if (!b.length) throw new Error("empty body");
        require("fs").writeFileSync(o, b);
      })
      .catch((e) => { console.error("    " + e.message); process.exit(1); });
  ' "$1" "$2"
}

BASE_CDN="https://cdn.jsdelivr.net/gh/$OWNER/$REPO@$BRANCH"
BASE_RAW="https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH"
BASE_GHQ="https://gh-proxy.com/https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH"
# raw 排第一：jsDelivr 的 @main 有缓存，会把旧版发过来（BUGS #11）。
# CDN 留作兜底，配合 get_checked 的内容校验，两条路都拿不到新版才会失败。
SOURCES="${ARMOR_MIRROR:-} $BASE_RAW $BASE_CDN $BASE_GHQ"

get() { # $1=仓库内相对路径 $2=本地落点
  for base in $SOURCES; do
    [ -n "$base" ] || continue
    say "  ← $base/$1"
    if dl "$base/$1" "$2"; then return 0; fi
  done
  return 1
}

# 带内容校验的下载：CDN（尤其 jsDelivr 的 @main）会缓存旧版本，
# 拿到旧文件比下载失败更糟 —— 装上去的是几小时前的逻辑。
# $2 是只有新版才有的标记串，命中才算下载成功。
get_checked() { # $1=仓库内相对路径 $2=版本标记 $3=本地落点
  for base in $SOURCES; do
    [ -n "$base" ] || continue
    say "  ← $base/$1"
    if dl "$base/$1" "$3"; then
      if [ -z "${2:-}" ] || grep -q "$2" "$3" 2>/dev/null; then
        return 0
      fi
      say "    [!] 这份缺标记 [$2]，是旧版本，换下一个源"
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 3. 准备目录
mkdir -p "$WORK/payload" || die "无法创建 $WORK"
cd "$WORK" || die "进不去 $WORK"

NEED_TGZ=1
if [ -f "payload/$TGZ_NAME" ]; then
  GOT=$("$N" -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "payload/$TGZ_NAME" 2>/dev/null)
  if [ "$GOT" = "$SHA_TGZ" ]; then
    say "[2] 本地已有 tgz 且校验通过，跳过下载"
    NEED_TGZ=0
  fi
fi

# ---------------------------------------------------------------- 4. 拉文件
hr
say "[3] 下载组件"
SMALL="preflight/package.json preflight/lib/index.js preflight/install-preflight.sh phone-armor-settings/package.json phone-armor-settings/lib/index.js phone-armor-settings/lib/client.js phone-armor-settings/install-settings.sh tier-gate/package.json tier-gate/lib/index.js tier-gate/lib/client.js tier-gate/install-tier-gate.sh guard/guard.sh guard/guard.conf guard/guard-install.sh payload/prompt-inject.md prompt/boost-nsfw.md"

# armor.sh 必须先装且必须是新版：用内容标记校验，挡住 CDN 缓存的旧文件
get_checked armor.sh "is_aibase" armor.sh || die "armor.sh 下载失败或拿到的一直是旧版本。换源：ARMOR_MIRROR=https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH sh bootstrap.sh"

for f in $SMALL; do
  mkdir -p "$(dirname "$f")"
  get "$f" "$f" || die "$f 下载失败。换镜像：ARMOR_MIRROR=<前缀> sh bootstrap.sh"
done
if [ "$NEED_TGZ" = 1 ]; then
  get "payload/$TGZ_NAME" "payload/$TGZ_NAME" || die "tgz 下载失败（2.1 MB）。换镜像：ARMOR_MIRROR=<前缀> sh bootstrap.sh"
fi

# ---------------------------------------------------------------- 5. 校验
GOT=$("$N" -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "payload/$TGZ_NAME" 2>/dev/null)
[ "$GOT" = "$SHA_TGZ" ] || die "tgz SHA256 不匹配
  期望 $SHA_TGZ
  实际 ${GOT:-读取失败}
  下载可能被截断/篡改 —— 删掉 payload/$TGZ_NAME 重跑"
say "[4] SHA256 校验通过"

# ---------------------------------------------------------------- 6. 交给 armor.sh
hr
say "[5] A 层 · 破甲本体"
chmod +x armor.sh 2>/dev/null
PURGE_PROFILE="${PURGE_PROFILE:-web}" DSH_NODE="$N" sh armor.sh install
RC=$?

# 破甲本体是地基：它没成，后面几层不装，避免留下悬空插件（上次就是这里漏了检查）
if [ "$RC" != 0 ]; then
  hr
  say "armor.sh 失败（rc=$RC）—— 后续几层不再安装，避免留下半套东西。"
  say ""
  say "如果报的是「未定位 @deepseek-ai」，先确认宿主真实位置再重跑："
  say "  sh armor.sh check"
  say "  DSH_BASE=/opt/dsh/node_modules/@deepseek-ai sh armor.sh install"
  hr
  exit $RC
fi

if [ "${ARMOR_SKIP_PREFLIGHT:-0}" != "1" ]; then
  hr
  say "[6] 预检 · agent 思考前做三档评级，二/三档弹窗"
  chmod +x preflight/install-preflight.sh 2>/dev/null
  PURGE_PROFILE="${PURGE_PROFILE:-web}" DSH_NODE="$N" sh preflight/install-preflight.sh install
  RC2=$?
  [ "$RC2" = 0 ] || say "  [!] 预检没装成（rc=$RC2），破甲本体不受影响"
else
  say "[6] 预检 · 跳过（ARMOR_SKIP_PREFLIGHT=1）"
fi

if [ "${ARMOR_SKIP_SETTINGS_UI:-0}" != "1" ]; then
  hr
  say "[6.5] 设置页 · 在 DSH 设置面板里加「手机强化」开关"
  chmod +x phone-armor-settings/install-settings.sh 2>/dev/null
  # 强化包正文由安装脚本从 ../prompt/boost-nsfw.md 拷过去，这里先铺好目录结构
  mkdir -p phone-armor-settings/prompt 2>/dev/null
  [ -f prompt/boost-nsfw.md ] && cp -f prompt/boost-nsfw.md phone-armor-settings/prompt/boost-nsfw.md 2>/dev/null
  PURGE_PROFILE="${PURGE_PROFILE:-web}" DSH_NODE="$N" sh phone-armor-settings/install-settings.sh install
  RC4=$?
  [ "$RC4" = 0 ] || say "  [!] 设置页没装成（rc=$RC4），不影响核心功能"
else
  say "[6.5] 设置页 · 跳过（ARMOR_SKIP_SETTINGS_UI=1）"
fi

if [ "${ARMOR_WITH_TIER_GATE:-0}" = "1" ]; then
  hr
  say "[7] 静态闸门 · 进会话弹出三档总表（可选）"
  chmod +x tier-gate/install-tier-gate.sh 2>/dev/null
  PURGE_PROFILE="${PURGE_PROFILE:-web}" DSH_NODE="$N" sh tier-gate/install-tier-gate.sh install
else
  say "[7] 静态闸门 · 跳过（默认不装；要装用 ARMOR_WITH_TIER_GATE=1）"
fi

if [ "${ARMOR_SKIP_GUARD:-0}" != "1" ]; then
  hr
  say "[8] 命令提示 · masscan/hashcat/大网段扫描/4K 转码 执行前提示"
  chmod +x guard/guard-install.sh 2>/dev/null
  sh guard/guard-install.sh install
  sh guard/guard-install.sh test
else
  say "[8] 命令提示 · 跳过（ARMOR_SKIP_GUARD=1）"
fi

hr
say "bootstrap 完成。回 App：设置 → 本机引擎 → 停止 → 启动。"
say ""
say "  A 破甲本体   已装（补丁数见上方）"
say "  预检         每次发工作指令先做三档评级；二/三档弹窗，点「我已知悉」只停下，"
say "               你自己再发一条指令才会真的执行"
say "  命令提示     配置在 /etc/phone-armor/guard.conf：0 只提示 / 1 拦截 / 2 放行"
say ""
say "装完按仓库里的 VERIFY.md 走七步验收。"
exit 0
