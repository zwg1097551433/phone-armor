#!/bin/sh
# guard-install.sh — 命令闸门的安装/卸载/状态
#
#   sh guard-install.sh install     装（替换二进制为包装器，真程序改名保留）
#   sh guard-install.sh uninstall   卸（改回原名）
#   sh guard-install.sh status      看当前拦了哪些
#   sh guard-install.sh test        自测几条规则
#
# 原理：把 /usr/bin/nmap 这类真程序改名成 nmap.phone-armor-real，
#       在原位置放一个同名的 shell 包装器，转发给 guard.sh 判定。
#       所以无论用 PATH 还是绝对路径调用，都会先过闸门。
# 回滚：uninstall 把原名改回去；真程序从未被删除。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX="${GUARD_PREFIX:-/opt/phone-armor}"
CONF_DIR="${GUARD_CONF_DIR:-/etc/phone-armor}"
TARGETS="masscan nmap hashcat fscan gogo docker ffmpeg"
CMD="${1:-status}"

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

find_real() { # $1=name → 真程序路径（排除已包装的）
  for d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin; do
    p="$d/$1"
    if [ -f "$p" ] && [ ! -f "$p.phone-armor-real" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

do_install() {
  hr; say "phone-armor 命令闸门 · 安装"; hr
  [ -f "$DIR/guard.sh" ] || die "找不到 $DIR/guard.sh"
  [ -f "$DIR/guard.conf" ] || die "找不到 $DIR/guard.conf"

  mkdir -p "$PREFIX" "$CONF_DIR" || die "无法创建目录"
  cp -f "$DIR/guard.sh" "$PREFIX/guard.sh" || die "复制 guard.sh 失败"
  chmod +x "$PREFIX/guard.sh"
  [ -f "$CONF_DIR/guard.conf" ] || cp -f "$DIR/guard.conf" "$CONF_DIR/guard.conf"
  say "[1] 闸门 → $PREFIX/guard.sh"
  say "    配置 → $CONF_DIR/guard.conf"

  n_ok=0; n_skip=0
  for name in $TARGETS; do
    real=$(find_real "$name") || { n_skip=$((n_skip+1)); continue; }
    mv "$real" "$real.phone-armor-real" || { say "  [!] $name 改名失败，跳过"; n_skip=$((n_skip+1)); continue; }
    {
      printf '#!/bin/sh\n'
      printf '# phone-armor guard wrapper — 真程序: %s.phone-armor-real\n' "$real"
      printf 'exec %s/guard.sh %s %s.phone-armor-real "$@"\n' "$PREFIX" "$name" "$real"
    } > "$real" || { mv "$real.phone-armor-real" "$real"; say "  [!] $name 写包装器失败，已还原"; continue; }
    chmod +x "$real"
    say "  [$name] 已拦截 → $real"
    n_ok=$((n_ok+1))
  done

  hr
  say "已包装 $n_ok 个程序，跳过 $n_skip 个（未安装）"
  say "验证：sh $DIR/guard-install.sh test"
  say "放开某项：编辑 $CONF_DIR/guard.conf，把对应 key 改成 1 或 2"
}

do_uninstall() {
  hr; say "phone-armor 命令闸门 · 卸载"; hr
  n=0
  for name in $TARGETS; do
    for d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin; do
      real="$d/$name"
      if [ -f "$real.phone-armor-real" ]; then
        mv -f "$real.phone-armor-real" "$real" && { say "  [$name] 已还原 → $real"; n=$((n+1)); }
      fi
    done
  done
  say "还原 $n 个程序。配置保留在 $CONF_DIR/guard.conf（要清就手动删目录）"
}

do_status() {
  hr; say "phone-armor 命令闸门 · 状态"; hr
  say "闸门脚本: $([ -x "$PREFIX/guard.sh" ] && echo "$PREFIX/guard.sh ✓" || echo '未安装')"
  say "配置文件: $([ -f "$CONF_DIR/guard.conf" ] && echo "$CONF_DIR/guard.conf ✓" || echo '未安装（默认全部拦截）')"
  say ""
  for name in $TARGETS; do
    line="  $name: "
    found=0
    for d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin; do
      [ -f "$d/$name.phone-armor-real" ] && { line="$line 已拦截 ($d/$name)"; found=1; break; }
    done
    [ "$found" = 0 ] && line="$line 未安装或未包装"
    say "$line"
  done
  say ""
  if [ -f "$CONF_DIR/guard.conf" ]; then
    say "当前配置："
    grep -v '^[[:space:]]*#' "$CONF_DIR/guard.conf" | grep '=' | sed 's/^/    /'
  fi
}

do_test() {
  hr; say "phone-armor 命令闸门 · 自测"; hr
  [ -x "$PREFIX/guard.sh" ] || die "闸门未安装，先跑 install"

  t() { # $1=描述 $2...=命令
    desc="$1"; shift
    out=$("$@" 2>&1); rc=$?
    case "$rc" in
      126) say "  ⛔ 拦截：$desc" ;;
      *)
        case "$out" in
          *"风险提示"*) say "  ⚠ 提示后放行：$desc" ;;
          *) say "  - 放行：$desc" ;;
        esac
        ;;
    esac
  }

  # 只测判定逻辑，不真的跑危险程序：用不存在的真路径，被拦时不会执行，放行时会报 127
  t "masscan 全量" "$PREFIX/guard.sh" masscan /nonexistent "0.0.0.0/0"
  t "nmap -sS"     "$PREFIX/guard.sh" nmap    /nonexistent "-sS" "10.0.0.1"
  t "nmap /16"     "$PREFIX/guard.sh" nmap    /nonexistent "-sT" "10.0.0.0/16"
  t "nmap -sT 单 IP" "$PREFIX/guard.sh" nmap  /nonexistent "-sT" "10.0.0.1"
  t "hashcat 真实" "$PREFIX/guard.sh" hashcat /nonexistent "-m" "1000" "h.txt"
  t "hashcat bench" "$PREFIX/guard.sh" hashcat /nonexistent "--benchmark"
  t "docker"       "$PREFIX/guard.sh" docker  /nonexistent "ps"
  t "fscan /16"    "$PREFIX/guard.sh" fscan   /nonexistent "-h" "10.0.0.0/16"
  t "ffmpeg 4K"    "$PREFIX/guard.sh" ffmpeg  /nonexistent "-s" "3840x2160" "out.mp4"
  say ""
  say "注：标「放行」的会去找真程序，/nonexistent 不存在所以返回 127/2，属预期。"
}

case "$CMD" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  test)      do_test ;;
  *) say "用法：sh guard-install.sh [install|uninstall|status|test]"; exit 1 ;;
esac
