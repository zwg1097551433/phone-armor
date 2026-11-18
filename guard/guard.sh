#!/bin/sh
# guard.sh — 命令风险提示器（默认只提示，不拦截）
#
# 用法：guard.sh <程序名> <真程序路径> [参数...]
#   wrapper 里这样调：exec /opt/phone-armor/guard.sh nmap /usr/bin/nmap "$@"
#
# 退出码：0 = 已交给真程序；126 = 被拦截（只有配置成 1 才会出现）
# 配置：/etc/phone-armor/guard.conf
#   0 = 只提示，照常执行（默认）
#   1 = 拦截
#   2 = 完全放行
set -u

CONF="${GUARD_CONF:-/etc/phone-armor/guard.conf}"

[ $# -ge 2 ] || { printf 'guard.sh: 用法 guard.sh <prog> <realpath> [args...]\n' >&2; exit 2; }
PROG="$1"; shift
REAL="$1"; shift
CMD="$*"          # 原始参数按字符串留住，给提示用（函数内的 $@ 会被自己的参数顶掉）

flag() { # $1=key $2=默认值
  v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([0-9]\).*/\1/p" "$CONF" 2>/dev/null | tail -1)
  if [ -n "${v:-}" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

red() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
yel() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

# 总开关
[ "$(flag bypass_all 0)" = 2 ] && exec "$REAL" "$@"

# judge：$1=key $2=一句话 $3=原因 $4=换路径
# 返回 0 = 放行（可能已打印提示）；126 = 拦截
judge() {
  mode=$(flag "$1" 0)
  [ "$mode" = 2 ] && return 0

  if [ "$mode" = 1 ]; then
    red "⛔ 已拦截：$PROG $CMD"
    red ""
    red "  $2"
    red "  原因：$3"
    red "  换路径：$4"
    red "  放开：编辑 $CONF，把 $1 改成 0（只提示）或 2（放行）"
    return 126
  fi

  yel "⚠ 风险提示：$PROG $CMD"
  yel "  $2"
  yel "  原因：$3"
  yel "  换路径：$4"
  yel "  这条只是提示，命令继续执行。不再提示：$CONF 里把 $1 改成 2"
  return 0
}

is_wide() { # CIDR 是否 /16 及更大
  case "$1" in
    */[1-9]|*/1[0-6]) return 0 ;;
  esac
  return 1
}

case "$PROG" in
  masscan)
    judge masscan "masscan 做原始包扫描" \
      "PRoot 没有 raw socket 权限，大流量还会被运营商限速或封号" \
      "在电脑上跑 masscan（需要管理员/root 权限）" || exit 126
    exec "$REAL" "$@"
    ;;

  nmap)
    has_syn=0; wide=""
    for a in "$@"; do
      case "$a" in
        -sS|-sU|--scanflags*) has_syn=1 ;;
      esac
      is_wide "$a" && wide="$a"
    done
    if [ "$has_syn" = 1 ]; then
      judge nmap_syn "nmap 的 -sS/-sU 需要 raw socket" \
        "PRoot 是非特权环境，原始套接字多半建不起来，会报权限错误" \
        "改用 nmap -sT（connect 扫描），或到电脑上跑 -sS" || exit 126
    fi
    if [ -n "$wide" ]; then
      judge nmap_syn "目标是 $wide（/16 或更大）" \
        "大网段扫描要跑几十分钟，手机会持续发热，长任务可能被系统回收" \
        "单 C 段以内的 -sT 更稳；更大范围建议到电脑上跑" || exit 126
    fi
    exec "$REAL" "$@"
    ;;

  hashcat)
    for a in "$@"; do
      [ "$a" = "--benchmark" ] && exec "$REAL" "$@"
    done
    judge hashcat "hashcat 在本机没有 GPU" \
      "CPU 模式跑真实哈希，几小时也只覆盖极小字典" \
      "在带 GPU 的电脑上跑；只验证算法用 --benchmark" || exit 126
    exec "$REAL" "$@"
    ;;

  fscan|gogo)
    wide=""
    for a in "$@"; do is_wide "$a" && wide="$a"; done
    if [ -n "$wide" ]; then
      judge "$PROG" "目标是 $wide（/16 或更大）" \
        "内存、电量、流量三重压力，中途可能被 Android 回收" \
        "单 C 段更稳；更大范围建议到电脑上做" || exit 126
    fi
    exec "$REAL" "$@"
    ;;

  docker|podman)
    judge docker "容器运行时在 PRoot 里起不来" \
      "没有内核命名空间权限，daemon 无法启动" \
      "在电脑上跑容器" || exit 126
    exec "$REAL" "$@"
    ;;

  ffmpeg)
    big=0; res4k=0
    for a in "$@"; do
      case "$a" in
        *2160*|*[Uu][Hh][Dd]*|*4[Kk]*) res4k=1 ;;
      esac
      if [ -f "$a" ]; then
        sz=$(wc -c < "$a" 2>/dev/null || echo 0)
        [ "${sz:-0}" -gt 104857600 ] && big=1
      fi
    done
    if [ "$res4k" = 1 ] || [ "$big" = 1 ]; then
      judge ffmpeg_big "4K 输出或输入素材超过 100 MB" \
        "CPU 长时间满载会明显发热，系统可能杀进程" \
        "到电脑上转码；手机上 720p、1 分钟以内的短片更稳" || exit 126
    fi
    exec "$REAL" "$@"
    ;;

  *)
    exec "$REAL" "$@"
    ;;
esac
