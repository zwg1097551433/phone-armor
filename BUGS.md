# 已知问题与修复记录

按**发现顺序**记录部署过程中真实踩到的坑。每条：症状 → 根因 → 修在哪个版本 → 你怎么自查或绕过。

部署遇到异常先翻这张表，绝大部分都能对上。

---

## 快速对照：看到这句话就翻第几条

| 你看到的 | 翻 |
|---|---|
| `[!] 未定位 @deepseek-ai` | [#1](#1-未定位-deepseek-ai5-路径漏了-optdsh) |
| 装完发现 preflight 目录悬空、guard 装了但没意义 | [#2](#2-破甲失败后bootstrap-还在装后面几层) |
| `bootstrap.sh` 一跑就 `[STOP] 仓库信息未设置` | [#3](#3-占位符替换后误触发仓库信息检查) |
| 克隆下来 `sha256sum` 和 `SHA256SUMS.txt` 对不上 | [#4](#4-gitattributes-把-payload-的-crlf-转了) |
| `补丁 0/86 已清洗, 0 待清洗` | [#6](#6-定位判据要求-lib-子目录太严) |
| `armor.sh status` 只打两行，看不到宿主路径 | [#5](#5-status-输出被过滤只剩两行) |

---

## #1 「未定位 @deepseek-ai」—— 路径漏了 `/opt/dsh`

**症状**

```
[7] 应用补丁
    [!] 未定位 @deepseek-ai
[ERROR] 插件根未找到 / set DSH_BASE
[!] apply 之后读不到补丁数 → 还原 package.json
```

**根因**

`armor.sh` 的 `find_aibase()` 候选清单只覆盖了 `/opt/dsh-app/**` 和 `$DSH_HOME/**`。
但 DSH Go 1.1.0 实机把宿主放在 **`/opt/dsh/node_modules/@deepseek-ai`** —— 这个路径从没进过候选。

**修复**：`45d7f1e`

```sh
/opt/dsh/node_modules/@deepseek-ai \
/opt/*/node_modules/@deepseek-ai \
```

第二条通配能兜住所有把宿主任意放在 `/opt/<名字>/` 下的布局。

**自查**

```sh
sh armor.sh check
```

会打出「环境里实际存在的 @deepseek-ai 目录」，`✓` 表示算宿主，`?` 表示缺 `dsh` 包不算。

**绕过**：显式指定

```sh
DSH_BASE=/opt/dsh/node_modules/@deepseek-ai sh armor.sh install
```

---

## #2 破甲失败后，bootstrap 还在装后面几层

**症状**

`armor.sh` 在 apply 阶段失败并回滚，但 `preflight/` 插件目录留在 `node_modules` 里没登记、`guard` 也装上了。等于留下半套悬空组件。

**根因**

`bootstrap.sh` 调完 `sh armor.sh install` 没检查返回值，继续往下执行。

**修复**：`45d7f1e`

```sh
if [ "$RC" != 0 ]; then
  say "armor.sh 失败（rc=$RC）—— 后续几层不再安装，避免留下半套东西。"
  exit $RC
fi
```

**自查**：`bootstrap` 的输出里，如果出现「armor.sh 失败」就再没有 `[6]` `[7]` `[8]`，说明修复生效了。

**清理残留**：

```sh
sh cleanup.sh          # 保留 prompt-inject.md
sh cleanup.sh --all    # 连 TIER-RULES 段一起抹掉
```

---

## #3 占位符替换后误触发「仓库信息检查」

**症状**

`bootstrap.sh` 一启动就 `[STOP] 缺少仓库信息`，但它明明已经填好了仓库地址。

**根因**

脚本里有一句「如果 `OWNER` 还是占位符就退出」的保护：

```sh
[ "$OWNER" = "CHANGE_ME" ] && die "..."
```

`set-repo.ps1` 把全仓的 `CHANGE_ME` 替换成真实用户名时，**把这句保护里的占位符也换了**，于是变成
`[ "$OWNER" = "你的用户名" ]` —— 恒真，必然触发。

**修复**：`612c45e` —— 改成只检查非空：

```sh
[ -n "$OWNER" ] && [ -n "$REPO" ] || die "缺少仓库信息..."
```

**自查**：`head -25 bootstrap.sh` 应该看到 `OWNER="${ARMOR_OWNER:-你的用户名}"`，下面紧跟一句 `[ -n "$OWNER" ]` 而不是 `[ "$OWNER" = ... ]`。

---

## #4 `.gitattributes` 把 payload 的 CRLF 转了

**症状**

克隆仓库后 `sha256sum payload/prompt-inject.md` 和 `SHA256SUMS.txt` 里记的值对不上。

**根因**

`.gitattributes` 里的 `* text=auto eol=lf` 会把所有文本按 LF 存。
`payload/prompt-inject.md` 原本是 CRLF，被转成 LF 后字节变了，哈希自然对不上。

**修复**：`f39c1e5`

```
payload/* -text
```

整个 payload 目录按二进制存，字节原样保留。

**自查**

```sh
git hash-object payload/prompt-inject.md
git rev-parse HEAD:payload/prompt-inject.md
```

两个值相同 = 没被转换。

---

## #5 `status` 输出被过滤，只剩两行

**症状**

```sh
sh armor.sh status
  注入状态        default
  补丁 0/86 已清洗, 0 待清洗
```

看不到 `DSH_HOME`、`插件根`、`shim 目录` —— 完全没法判断问题在哪。

**根因**

`do_status()` 里用 `sed -n '/补丁/p;/注入状态/p'` 只挑了两行。

**修复**：`工作区最新` —— 改为输出 `dsh-purge.js --status` 的完整结果。

**自查**：现在 `sh armor.sh status` 会打出一整屏，包括「插件根 / root」那行。**那行有没有值，是判断宿主是否定位成功的第一依据。**

---

## #6 定位判据要求 `lib` 子目录，太严

**症状**

宿主明明在 `/opt/dsh/node_modules/@deepseek-ai`，但脚本报未定位；或者装完 `补丁 0/86 已清洗, 0 待清洗`（86 条全部"不适用"而不是 pending）。

**根因**

判据写的是：

```sh
[ -d "$d/dsh-agent-instructions/lib" ]
```

但不同构建里 `dsh-agent-instructions` 内部布局不一样 —— 有的直接放编译产物，没有 `lib/` 子目录。
判据不中 → 定位失败 → 所有补丁找不到目标文件 → 既不 applied 也不 pending。

**修复**：`工作区最新` —— 放宽为「有 `dsh` 包就算宿主」：

```sh
is_aibase() {
  [ -f "$1/dsh/package.json" ] || [ -d "$1/dsh-agent-instructions/lib" ]
}
```

**自查**

```sh
ls -d /opt/dsh/node_modules/@deepseek-ai/dsh-agent-instructions/lib 2>&1
```

- 有路径 → 旧判据也能中
- `No such file or directory` → 就是这个坑，升级脚本

---

## #7 回滚不清 `prompt-inject.md`（设计如此，不是 bug）

**症状**

apply 失败回滚后，`/root/.dsh/prompt-inject.md` 还在，里面已经有 TIER-RULES 段。

**说明**

这是**刻意的**。`prompt-inject.md` 属于用户文件，里面可能有你自己写的内容，脚本回滚时不该替你删。

而且它只在 `dsh-purge` 插件加载时才被读取 —— 插件撤了，它就是个普通文件，**不会影响宿主行为**。

**想一并清掉**：

```sh
sh cleanup.sh --all
```

---

## #8 apply 中断会留下「部分应用」状态

**症状**

`4 已清洗 + 62 待清洗`，其余 20 条是不适用。

**根因**

`dsh-purge --apply` 是**逐条打**的，一条失败不影响下一条。中途按 Ctrl-C 或进程被杀，就会停在半路。

**处理**：直接重跑，`--apply` 是幂等的 —— 已应用的会报「已是最新」，没应用的继续打。

```sh
cd /root/phone-armor
DSH_BASE=/opt/dsh/node_modules/@deepseek-ai sh armor.sh repair
```

**想完全恢复原样**：

```sh
DSH_BASE=/opt/dsh/node_modules/@deepseek-ai \
  node /root/.dsh/profiles/web/node_modules/dsh-purge-community/bin/dsh-purge.js --revert
```

---

## #9 只想上规则、不想拆宿主安全层

**不是 bug，是模式选择。**

完整破甲会改动宿主的审批默认值、沙箱拦截、fs 围栏。如果你只想加「手机能干什么」的边界，不动这些：

```sh
DSH_BASE=/opt/dsh/node_modules/@deepseek-ai ARMOR_SKIP_APPLY=1 sh armor.sh install
```

效果：

| 层 | 完整模式 | `ARMOR_SKIP_APPLY=1` |
|---|---|---|
| 注入规则（TIER-RULES） | ✅ | ✅ |
| 风险预检（三档弹窗） | ✅ | ✅ |
| 命令提示 | ✅ | ✅ |
| 86 条源码补丁 | ✅ 全打 | ❌ 一条不打 |
| 宿主审批 / 沙箱 | 被拆 | **保持原样** |

---

## #10 卸载后插件仍在内存里，会反复回写 `prompt-inject.md`

**症状**

已经摘掉 `profile.bundles`、删掉插件目录，`prompt-inject.md` 也删了 —— 过几分钟它又出现了，内容正是那段注入正文。

**根因**

卸载只改了**磁盘**。正在运行的引擎进程里还挂着插件实例，它会周期性把注入正文写回 `$DSH_HOME/prompt-inject.md`。
只要进程活着，删多少次都会被写回来。

更麻烦的是：如果这个文件在引擎启动时存在，它会被读进系统提示。

**正确的清理顺序（顺序错了就白删）**

```
1. App → 设置 → 本机引擎 → 停止        ← 进程死掉，回写源消失
2. 删 $DSH_HOME/prompt-inject.md        ← 这时候删才是永久的
3. App → 设置 → 本机引擎 → 启动        ← bundles 已摘除，插件不加载，不会再生成
```

**反例**（会失败）：删文件 → 立刻重启。
重启过程里旧进程还在跑，可能又写一次，新进程启动正好读到它。

**自查**

```sh
ls -l /root/.dsh/prompt-inject.md
```

- 文件不存在 → 干净
- 存在但**重启后 mtime 不再变化** → 残留文件，删掉即可，不会再重生
- 存在且 mtime 一直在变 → 还有存活进程在写，先停引擎

**修复**：文档级（本条）。`cleanup.sh` 结尾会提示这个顺序。

---

## 记录规则

新增一条时请包含四件事，缺一条以后就复现不了：

1. **症状** —— 用户原样看到的输出（可复制粘贴）
2. **根因** —— 代码里哪一行导致
3. **修复** —— commit 号或版本号
4. **自查 / 绕过** —— 用户自己能验证或临时规避的办法
