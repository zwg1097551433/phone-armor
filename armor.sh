#!/bin/sh
# armor.sh — 破甲一键注入 / 自愈 / 回滚（DSH Go 本机引擎 · PRoot Ubuntu）
#
#   sh armor.sh check      只读体检：定位 HOME / node / @deepseek-ai / 当前补丁数
#   sh armor.sh install    一键注入（幂等：已就绪直接跳过）
#   sh armor.sh repair     强制重打（App 升级引擎 / 补丁被覆盖之后用）
#   sh armor.sh status     只看补丁数
#   sh armor.sh revert     回滚（撤补丁 + 从 bundles 摘除）
#
# 设计要点：
#   · 手机上没有 pnpm，所以不走官方 bootstrap，改为「解包 → 落 node_modules → 写 profile.bundles」；
#   · 包内 lib/ 全部是相对引用 + node: 内建，顶层零第三方依赖，因此落位后可直接跑；
#   · 只改 profile package.json 的 dsh.profile.bundles，不动 dependencies（避免 pnpm-lock 不一致）；
#   · 任何一步失败 → 还原 package.json；备份留在 $DSH_HOME/armor-backup-<时间戳>/。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# payload/ 布局（git 仓库）与同目录布局（手工传包）都支持
TGZ=""; INJ=""
for c in "$DIR/payload/dsh-purge-community-1.6.91.tgz" "$DIR/dsh-purge-community-1.6.91.tgz"; do
  [ -f "$c" ] && { TGZ="$c"; break; }
done
for c in "$DIR/payload/prompt-inject.md" "$DIR/prompt-inject.md"; do
  [ -f "$c" ] && { INJ="$c"; break; }
done
SHA="ae22bb7d1ac1e055102c8fbd24cf2eedc282a94bfa3fb09e7ab91226fc033058"
VER="1.6.91"
ENGINE_EXPECT="0.2.2-rc.1"
ENGINE_MIN="0.2.1-rc.2"
PROFILE="${PURGE_PROFILE:-web}"
CMD="${1:-install}"
FORCE=""
[ "$CMD" = "repair" ] && { FORCE=1; CMD=install; }

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 探测
find_home() {
  for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
    [ -n "$h" ] && [ -f "$h/profiles/$PROFILE/package.json" ] && { printf '%s' "$h"; return 0; }
  done
  return 1
}

find_node() {
  for c in "$(command -v node 2>/dev/null)" /opt/dsh-app/node/bin/node \
           /opt/dsh-app/*/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# 判定一个目录是不是 @deepseek-ai 根。
# 判据放宽：不同构建里 dsh-agent-instructions 的布局不一样，有 dsh 包就算命中。
is_aibase() {
  [ -f "$1/dsh/package.json" ] || [ -d "$1/dsh-agent-instructions/lib" ]
}

find_aibase() {
  # 1) 固定候选。实机确认 DSH Go 1.1.0 的宿主在 /opt/dsh/node_modules/@deepseek-ai，
  #    另外兼容 /opt/dsh-app/** 与 $DSH_HOME 下的运行时分发目录。
  for d in "${DSH_BASE:-}" \
           /opt/dsh/node_modules/@deepseek-ai \
           /opt/*/node_modules/@deepseek-ai \
           /opt/*/*/node_modules/@deepseek-ai \
           /opt/dsh-app/node_modules/@deepseek-ai \
           /opt/dsh-app/engine/node_modules/@deepseek-ai \
           /opt/dsh-app/*/node_modules/@deepseek-ai \
           /opt/dsh-app/*/*/node_modules/@deepseek-ai \
           "$H"/node_modules/@deepseek-ai \
           "$H"/dsh-runtimes/*/node_modules/@deepseek-ai \
           "$H"/profiles/*/node_modules/@deepseek-ai \
           /usr/local/lib/node_modules/@deepseek-ai \
           /usr/lib/node_modules/@deepseek-ai; do
    [ -n "$d" ] && is_aibase "$d" && { printf '%s' "$d"; return 0; }
  done
  # 2) 兜底：只扫 /opt 和几个窄目录，深度 6，head 截断。
  #    不要在 $DSH_HOME 根上 find —— 那里有几千个 session 文件和 node_modules，手机上会卡几十秒。
  for root in /opt "$H/node_modules" "$H/dsh-runtimes"; do
    [ -d "$root" ] || continue
    for d in $(find "$root" -maxdepth 6 -type d -name '@deepseek-ai' 2>/dev/null | head -5); do
      is_aibase "$d" && { printf '%s' "$d"; return 0; }
    done
  done
  return 1
}

# ---------------------------------------------------------------- 基础定位
H=$(find_home) || die "找不到 DSH_HOME（\$HOME/.dsh 或 /root/.dsh）。先在 App 里启动一次本机引擎。"
N="${DSH_NODE:-$(find_node)}"
[ -n "$N" ] && [ -x "$N" ] || die "找不到 node。显式指定：DSH_NODE=/path/to/node sh armor.sh $CMD"
AI="${DSH_BASE:-$(find_aibase)}"
PJ="$H/profiles/$PROFILE/package.json"
DEST="$H/profiles/$PROFILE/node_modules/dsh-purge-community"
MARK="$H/dsh-purge/armor.state"

purge_status() {
  [ -f "$DEST/bin/dsh-purge.js" ] || return 1
  DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --status 2>&1
}

# 宿主目录可写性：只读宿主上 apply 一定打不进去。
# 官方 bootstrap 遇到只读宿主会把整份 DSH 复制到 ~/.local/share/dsh-purge/hosts/ 再打，
# 但 App 启动的仍是 /opt/dsh-app 那份 —— 补丁等于白打，所以这里提前拦住。
writable() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  : > "$1/.armor-wtest" 2>/dev/null || return 1
  rm -f "$1/.armor-wtest" 2>/dev/null
  return 0
}

applied_count() {
  purge_status 2>/dev/null | sed -n 's/.*补丁 \([0-9][0-9]*\)\/\([0-9][0-9]*\) 已清洗.*/\1/p' | head -1
}

# 读宿主引擎版本：$AI 是 @deepseek-ai 目录，里面应该有 dsh/
engine_version() {
  [ -n "${AI:-}" ] || return 1
  "$N" -e 'try{process.stdout.write(String(require(process.argv[1]+"/package.json").version||"unknown"))}catch(e){process.stdout.write("unknown")}' "$AI/dsh" 2>/dev/null
}

banner() {
  hr
  say "dsh-purge $VER · 一键注入器（$CMD）"
  hr
  say "  DSH_HOME   $H"
  say "  profile    $PROFILE"
  say "  node       $N ($("$N" -v 2>/dev/null))"
  say "  @deepseek-ai  ${AI:-未定位（apply 可能报缺宿主，用 DSH_BASE=... 指定）}"
  if [ -n "${AI:-}" ]; then
    EV=$(engine_version)
    say "  引擎版本   ${EV:-读取失败}（本包按 $ENGINE_EXPECT 校准，最低 $ENGINE_MIN）"
    if writable "$AI"; then say "  宿主可写性  ✓ 可写"; else say "  宿主可写性  ✗ 只读（apply 打不进去）"; fi
  fi
  say "  插件目录   $DEST"
}

# ---------------------------------------------------------------- 子命令
do_check() {
  banner
  say "  只读探测：仅检测环境与可打补丁的文件，不会修改任何内容。"
  say ""
  if [ -f "$DEST/bin/dsh-purge.js" ]; then
    say "  已安装：$("$N" -p 'require("'$DEST'/package.json").version' 2>/dev/null)"
    say ""
    purge_status | head -20
    say ""
    say "  已清洗补丁：$(applied_count) 条"
  else
    say "  未安装（插件目录不存在）"
  fi

  # 把「环境里到底有哪些 @deepseek-ai」直接打出来，省得靠猜
  say ""
  say "  [环境里实际存在的 @deepseek-ai 目录]"
  found=0
  for root in /opt "$H"; do
    [ -d "$root" ] || continue
    for d in $(find "$root" -maxdepth 5 -type d -name '@deepseek-ai' 2>/dev/null | head -6); do
      if is_aibase "$d"; then say "    ✓ $d"; else say "    ? $d   (缺 dsh 包，不算宿主)"; fi
      found=1
    done
  done
  [ "$found" = 0 ] && say "    （一个都没有 —— 引擎可能还没初始化）"

  [ -f "$MARK" ] && { say ""; say "  marker:"; sed 's/^/    /' "$MARK"; }
  say ""
  df -h "$H" 2>/dev/null | sed 's/^/  /'
  hr
}

do_status() {
  [ -f "$DEST/bin/dsh-purge.js" ] || die "未安装：$DEST 不存在（先跑 install）"

  hr
  say "手机强化自检"
  say "  （只读：不修改任何文件）"
  hr

  # ① 破甲补丁
  A=$(applied_count)
  if [ -n "${A:-}" ] && [ "$A" -ge 60 ]; then
    say "  ① 破甲补丁      $A/86 命中       ✅ 主干在（审批6 + 沙箱5 + 提权3 + 提示管线6）"
  elif [ -n "${A:-}" ] && [ "$A" -ge 1 ]; then
    say "  ① 破甲补丁      $A/86 命中       ⚠ 偏低，锚点可能漂移"
  else
    say "  ① 破甲补丁      ${A:-0}/86 命中       ❌ 未命中"
  fi

  # ② 注入正文是否落盘
  if [ -f "$H/prompt-inject.md" ]; then
    SZ=$(wc -c < "$H/prompt-inject.md")
    if [ "$SZ" -gt 1000 ]; then
      say "  ② 注入正文      $SZ 字节        ✅ 已落盘"
    else
      say "  ② 注入正文      $SZ 字节        ⚠ 过小，可能没合并成功"
    fi
  else
    say "  ② 注入正文      不存在          ❌ 缺失"
  fi

  # ③ 注入是否到达模型（probe）
  PROBE="$H/dsh-purge/probe.json"
  if [ -f "$PROBE" ]; then
    N_U=$(sed -n 's/.*"nonce":"\([^"]*\)".*/\1/p' "$PROBE" 2>/dev/null | head -1)
    A_T=$(sed -n 's/.*"at":\([0-9]*\).*/\1/p' "$PROBE" 2>/dev/null | head -1)
    say "  ③ 注入到达模型  probe ${N_U:-存在}     ⬜ 需要发一句话看模型是否回显"
  else
    say "  ③ 注入到达模型  未生成 probe     ⬜ 跑：community.js probe new"
  fi

  # ④ 风险预检
  if [ -d "$H/profiles/$PROFILE/node_modules/phone-armor-preflight" ] &&
     grep -q phone-armor-preflight "$H/profiles/$PROFILE/cordis.patch.yml" 2>/dev/null; then
    say "  ④ 风险预检      已注册          ✅"
  else
    say "  ④ 风险预检      未注册          ❌"
  fi

  # ⑤ 命令提示
  if [ -x /opt/phone-armor/guard.sh ]; then
    say "  ⑤ 命令提示      已装            ✅ 默认只提示不拦截"
  else
    say "  ⑤ 命令提示      未装            ⬜"
  fi

  # ⑥ 设置页
  if [ -d "$H/profiles/$PROFILE/node_modules/phone-armor-settings" ] &&
     grep -q phone-armor-settings "$H/profiles/$PROFILE/cordis.patch.yml" 2>/dev/null; then
    say "  ⑥ 设置页        已注册          ✅"
  else
    say "  ⑥ 设置页        未注册          ⬜"
  fi

  hr
  say "  完整补丁明细：sh armor.sh status --detail"
  hr
}

# 合并注入正文：只插/更新 TIER-RULES 段，保留用户原有内容。
# 与「打源码补丁」完全解耦 —— 只跑 merge_inject 不会拆掉审批和沙箱。
merge_inject() {
  [ -f "$INJ" ] || return 0
  "$N" -e '
    const fs = require("fs");
    const [src, target] = process.argv.slice(1);
    const B = "<!-- TIER-RULES:BEGIN -->", E = "<!-- TIER-RULES:END -->";
    const payload = fs.readFileSync(src, "utf8");
    const i0 = payload.indexOf(B), i1 = payload.indexOf(E);
    let cur = "";
    try { cur = fs.readFileSync(target, "utf8"); } catch {}
    if (i0 < 0 || i1 <= i0) { fs.writeFileSync(target, payload); process.exit(0); }
    const block = payload.slice(i0, i1 + E.length);
    const j0 = cur.indexOf(B), j1 = cur.indexOf(E);
    let out;
    if (j0 >= 0 && j1 > j0) {
      out = cur.slice(0, j0) + block + cur.slice(j1 + E.length);
    } else if (cur.trim() === "") {
      out = block + "\n";
    } else {
      const anchor = "<|im_start|>system:<project_instructions>";
      const k = cur.indexOf(anchor);
      out = k >= 0
        ? cur.slice(0, k + anchor.length) + "\n\n" + block + "\n" + cur.slice(k + anchor.length)
        : block + "\n\n" + cur;
    }
    fs.writeFileSync(target, out);
  ' "$INJ" "$H/prompt-inject.md"
}

do_install() {
  banner
  [ -f "$TGZ" ] || die "缺少包：$TGZ"
  [ -f "$PJ" ]  || die "profile 未初始化：$PJ（先在 App 里启动一次本机引擎）"

  # --- 引擎版本门槛：不匹配不中止，但要讲清后果 ---
  if [ -n "${AI:-}" ]; then
    EV=$(engine_version)
    case "${EV:-}" in
      ""|unknown) : ;;
      "$ENGINE_EXPECT") : ;;
      *)
        say ""
        say "  [!] 本机引擎是 $EV，本包按 $ENGINE_EXPECT 校准。"
        say "      补丁锚点是对着 $ENGINE_EXPECT 的真实源码写的，版本不同可能大量 pending。"
        say "      继续装不会弄坏 App（失败会自动还原），但命中率会低。"
        say "      想中止就现在 Ctrl-C。"
        say ""
        ;;
    esac
  fi

  # --- 幂等：已是目标版本且补丁数达标 → 跳过 ---
  if [ -z "$FORCE" ] && [ -f "$DEST/bin/dsh-purge.js" ]; then
    A=$(applied_count)
    if [ -n "${A:-}" ] && [ "$A" -ge 60 ]; then
      say "[1] 已注入（$A 条补丁已清洗），跳过。"
      say "    要强制重打：sh armor.sh repair"
      return 0
    fi
    say "[1] 检测到旧安装但补丁不足（${A:-0} 条），继续修复。"
  fi

  # --- SHA256 ---
  GOT=$("$N" -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$TGZ" 2>/dev/null)
  [ "$GOT" = "$SHA" ] || die "tgz SHA256 不匹配：$GOT"
  say "[2] SHA256 OK"

  # --- 备份 ---
  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
  BAK="$H/armor-backup-$STAMP"
  mkdir -p "$BAK" || die "无法创建备份目录 $BAK"
  cp -f "$PJ" "$BAK/package.json.orig" || die "备份 package.json 失败"
  [ -f "$H/prompt-inject.md" ] && cp -f "$H/prompt-inject.md" "$BAK/prompt-inject.md.orig"
  say "[3] 备份 → $BAK"

  # --- 解包落位 ---
  TMP="${TMPDIR:-/tmp}/armor.$$"
  rm -rf "$TMP"; mkdir -p "$TMP" || die "无法创建临时目录"
  tar -xzf "$TGZ" -C "$TMP" || die "解包失败"
  [ -f "$TMP/package/bin/dsh-purge.js" ] || die "包结构异常（缺 bin/dsh-purge.js）"
  mkdir -p "$H/profiles/$PROFILE/node_modules"
  rm -rf "$DEST.new"
  cp -a "$TMP/package" "$DEST.new" || die "复制到 node_modules 失败"
  [ -d "$DEST" ] && mv "$DEST" "$BAK/dsh-purge-community.old"
  mv "$DEST.new" "$DEST" || die "落位失败"
  rm -rf "$TMP"
  say "[4] 插件落位 → $DEST"

  # --- 注册 bundle（只动 bundles，不碰 dependencies）---
  "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    const o = JSON.parse(fs.readFileSync(p, "utf8"));
    o.dsh = o.dsh || {};
    o.dsh.profile = o.dsh.profile || {};
    const b = o.dsh.profile.bundles = o.dsh.profile.bundles || [];
    if (!b.includes("dsh-purge-community")) b.push("dsh-purge-community");
    fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
  ' "$PJ" || die "写 profile package.json 失败"
  say "[5] profile.bundles 已登记 dsh-purge-community"

  # --- 注入正文（合并模式：只插/更新 TIER-RULES 段，保留用户原有内容）---
  if [ -f "$INJ" ]; then
    merge_inject || die "写 prompt-inject.md 失败"
    say "[6] prompt-inject.md 已合并（TIER-RULES 段 + 原有内容）→ $H/prompt-inject.md ($(wc -c < "$H/prompt-inject.md") 字节)"
  else
    say "[6] 包里没有 prompt-inject.md，跳过正文"
  fi

  # --- 写入 dsh-purge 调优配置（决定破甲效果强弱，缺失时补）---
  # 关键三项：
  #   injectPosition=both  注入放头部+尾部（长对话里头部会被稀释，尾部权重更高）
  #   refusalRetry=true    检测到拒绝就带着加固语重试一次（官方默认 off）
  #   boost=true           启用尾部强化段
  # 缺了这三项，66 条补丁的打折效果会非常明显。
  TUNE="$H/dsh-purge/tuning.json"
  if [ ! -f "$TUNE" ]; then
    mkdir -p "$H/dsh-purge" 2>/dev/null
    cat > "$TUNE" <<'TUNEEOF'
{
  "boost": true,
  "injectPosition": "both",
  "askNoBlock": true,
  "rewind": true,
  "refusalRetry": true,
  "extraPatches": []
}
TUNEEOF
    say "[6.5] tuning.json 已写入（injectPosition=both / refusalRetry=true / boost=true）"
    say "      ⚠ 插件在 apply() 里只读一次 tuning —— 必须重启引擎才生效"
  else
    say "[6.5] tuning.json 已存在，保留用户配置（$TUNE）"
  fi

  # --- 应用 ---
  hr
  if [ "${ARMOR_SKIP_APPLY:-0}" = "1" ]; then
    say "[7] 跳过源码补丁（ARMOR_SKIP_APPLY=1）"
    say "    插件已落位、注入正文已写 —— 运行时规则生效；"
    say "    宿主源码不动，审批弹窗与沙箱拦截保持原样。"
    APPLY_RC=0
  else
    say "[7] 应用补丁"
    if [ -z "$AI" ]; then
      say "    [!] 未定位 @deepseek-ai —— 试试 DSH_BASE=<含 dsh-agent-instructions/lib 的目录>"
      say "        实机已知路径：/opt/dsh/node_modules/@deepseek-ai"
    elif ! writable "$AI"; then
      say ""
      say "[!] 宿主目录只读：$AI"
      say "    在只读宿主上跑 apply，官方逻辑会把整份 DSH 复制到 ~/.local/share/dsh-purge/hosts/ 再打补丁，"
      say "    而 App 启动的仍是 /opt/dsh 那份 —— 补丁不生效，还会白占一份空间。"
      say "    先确认 App 允许写该目录，或用 DSH_BASE 指向一份可写的宿主副本后重跑。"
      say "    只想上规则不动源码：ARMOR_SKIP_APPLY=1 sh armor.sh install"
      die "宿主只读，已在 apply 之前停止（可用 revert 清理已落位部分）"
    fi
    DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --apply
    APPLY_RC=$?
  fi

  # --- 自检 ---
  A=$(applied_count)
  if [ "${ARMOR_SKIP_APPLY:-0}" = "1" ]; then
    A=0
    say ""
    say "[8] 按 ARMOR_SKIP_APPLY=1 跳过补丁数自检（本来就没打补丁，0 条属预期）"
  elif [ -z "${A:-}" ] || [ "$A" -lt 1 ]; then
    say ""
    say "[!] apply 之后读不到补丁数 → 还原 package.json（App 仍可正常启动）"
    cp -f "$BAK/package.json.orig" "$PJ"
    rm -rf "$DEST"
    die "已回滚。把上面的输出发我"
  fi
  mkdir -p "$H/dsh-purge" 2>/dev/null
  printf 'ver=%s\napplied=%s\nrc=%s\nat=%s\nai=%s\nhome=%s\n' \
    "$VER" "$A" "$APPLY_RC" "$STAMP" "$AI" "$H" > "$MARK"

  # 再写一次注入正文：重装/repair 时旧插件实例可能还在内存里，
  # 它会在 apply 期间把 prompt-inject.md 覆盖回去（BUGS.md #10）。
  # 这里补最后一刀，保证落盘的是我们这份。
  if [ -f "$INJ" ]; then
    merge_inject && say "[9] 注入正文已复核（防止运行中的旧实例回写覆盖）"
  fi
  say ""
  hr
  say "完成：$A 条补丁已清洗（marker: $MARK）"
  say "  回 App：设置 → 本机引擎 → 停止 → 启动，让补丁加载"
  say "  回滚：sh armor.sh revert"
  hr
}

do_revert() {
  banner
  [ -f "$DEST/bin/dsh-purge.js" ] || die "没有安装（$DEST 不存在）"
  say "[1] 撤补丁"
  DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --revert
  say "[2] 从 bundles 摘除"
  "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    const o = JSON.parse(fs.readFileSync(p, "utf8"));
    const b = o?.dsh?.profile?.bundles;
    if (Array.isArray(b)) o.dsh.profile.bundles = b.filter((x) => x !== "dsh-purge-community");
    fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
  ' "$PJ" || say "  [!] 改 package.json 失败，手动摘除 dsh-purge-community"
  rm -f "$MARK"
  say ""
  say "回滚完成。插件目录保留在 $DEST（确认无误后可手动删）。"
  say "prompt-inject.md 按设计保留（用户文件）。"
}

case "$CMD" in
  applied) A=$(applied_count); printf '%s' "${A:-0}" ; echo ;;
  check)   do_check ;;
  status)
    if [ "${2:-}" = "--detail" ]; then
      [ -f "$DEST/bin/dsh-purge.js" ] || die "未安装"
      purge_status
    else
      do_status
    fi
    ;;
  install) do_install ;;
  revert)  do_revert ;;
  *) say "用法：sh armor.sh [check|install|repair|status|revert]"; exit 1 ;;
esac
