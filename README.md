# phone-armor

给 **DSH Go（Android）** 装破甲，并在 agent 开始干活之前加一道**风险预检**。

**全程在手机上完成，不需要电脑。** 只要你的手机上装了 DSH Go 并且初始化过「本机运行环境」，就能装。

---

## 安装：一条命令

在 DSH Go 里新建会话（确认主机是**本机**，不是远程），把下面整段发给它：

```
请执行这条命令，把完整输出贴回来（就十几行）：

mkdir -p /root/phone-armor && cd /root/phone-armor && \
node -e "fetch('https://raw.githubusercontent.com/zwg1097551433/phone-armor/main/deploy.sh').then(r=>r.text()).then(t=>require('fs').writeFileSync('deploy.sh',t))" && \
sh deploy.sh
```

`deploy.sh` 会自己探环境、装四层、判定结果；失败时自动换方案重试，屏幕只留十几行结论。

只想要规则层、不动宿主源码：`sh deploy.sh --rules`

自动模式失败时再走手动两步版：

```
cd /root/phone-armor && \
node -e "fetch('https://raw.githubusercontent.com/zwg1097551433/phone-armor/main/bootstrap.sh').then(r=>r.text()).then(t=>require('fs').writeFileSync('bootstrap.sh',t))" && \
sh bootstrap.sh
```

或者自己在 App 的终端（Web 界面 `127.0.0.1:3080` 里的 terminal）里跑同样的三行。

> 把 `zwg1097551433/phone-armor` 换成实际仓库地址。国内网络拉不动 GitHub 时，`bootstrap.sh` 会自动依次尝试
> jsDelivr CDN、raw.githubusercontent、gh-proxy 三个源。

装完回 App：**设置 → 本机引擎 → 停止 → 启动**。

## 装完是什么样

之后你在聊天框里发一条工作指令，会看到这个流程：

```
你：帮我在本地用 diffusion 生成一张 1024x1024 的图
      ↓
   （主 agent 先不动手）
      ↓
┌────────────────────────────────────┐
│ ⛔ 第三档 · 本机跑不了              │
│                                    │
│   判断：需要 4–16 GB 内存和 GPU，   │
│         手机必然 OOM 被系统杀掉     │
│   换路径：改走云端生图 API          │
│                                    │
│   点「我已知悉」不会立刻执行 ——     │
│   本轮就此停下。你需要自己在聊天框  │
│   里再发一条指令，才会真的开始。    │
│                                    │
│        [ 我已知悉 ]  [ 取消 ]       │
└────────────────────────────────────┘
```

- 第一档（写代码、问答、读文件、调云端 API）→ **不弹窗**，直接干活
- 第二档（大文本、小范围扫描、转录、装依赖）→ 弹卡片，会烫会卡
- 第三档（本地出图、大模型推理、4K 渲染、大网段扫描）→ 弹卡片，本机跑不了

**点「我已知悉」≠ 替你执行。** 它只是关掉弹窗、把这一轮停掉。你必须自己再发一条指令，
主 agent 才会真的开始 —— 风险工作天然多一道人为摩擦。

## 四层结构（稳定优先，可逐层降级）

| 层 | 内容 | 来源 | 能关吗 |
|---|---|---|---|
| **L0 补丁** | 88 条源码补丁 + apply 机制 | **原作者**（kingcharleslzy-ai/dsh-purge） | 不建议，这是破甲本体 |
| **L1 核心注入** | 5 条执行纪律：身份优先级 / 多轮清零 / 输出层 / 意图映射 / 边界词处理 | **抄自原作者**的规则描述，他验证过 | 不建议，这是"能干活"的基础 |
| **L2 扩展注入** | 手机能力三档、转场阈值、水印处理、输出透明 | **本仓库新增** | ✅ `ARMOR_INJECT=core` |
| **L3 增强插件** | 风险预检 / 设置页 / 命令提示 | **本仓库新增** | ✅ 各自独立开关 |

**出问题时的排查顺序：先关 L2，再关 L3，最后才动 L0/L1。**

因为 L0 和 L1 是原作者验证过的部分，L2/L3 是本仓库新增、验证数据还少的部分。

### 降级到「最接近原版」

```sh
cd /root/phone-armor
ARMOR_INJECT=core sh armor.sh install      # 只留 L1，去掉能力边界
ARMOR_SKIP_PREFLIGHT=1 sh bootstrap.sh     # 不装风险预检
ARMOR_SKIP_GUARD=1 sh bootstrap.sh         # 不装命令提示
ARMOR_SKIP_SETTINGS_UI=1 sh bootstrap.sh   # 不装设置页
```

四层全部可查：

```sh
sh armor.sh status
```

```
① 破甲补丁      66/86 命中       ✅
② 注入正文      36781 字节       ✅
③ 注入到达模型  probe …          ⬜
④ 风险预检      已注册           ✅
⑤ 命令提示      已装             ✅
⑥ 设置页        已注册           ✅
```

设置页里也能看到当前的注入模式（完整 / 精简）。

### 为什么这样分层

原作者的项目经过他自己的测试验证，稳定性是基础。我们加的东西只在外围，**不碰补丁逻辑**：

```
我们改过的：  注入文本内容、tuning.json 的值、额外插件
我们没改的：  补丁表、锚点、apply 流程、备份机制
```

所以「关掉我们加的部分」就等于回到原版行为，不需要重装整个包。

## 兼容性

| App 版本 | 内置引擎 | 破甲包 | 状态 |
|---|---|---|---|
| DSH Go 1.0.15 | 0.2.2-rc.1 | 1.6.91 | ✅ |
| DSH Go **1.1.0** | **0.2.2-rc.1** | 1.6.91 | ✅ 实测 74/86 |
| 其它版本 | ？ | 1.6.91 | ⚠️ 锚点可能漂移，安装脚本会提示 |

补丁锚点是对着引擎 **0.2.2-rc.1** 的真实源码写的。App 升级导致引擎版本变化时，
补丁命中率会下降 —— 安装脚本会先读出版本告诉你，不会闷头装。

**任何情况下装坏都能救**：脚本会备份 `package.json` 与 `prompt-inject.md`，
apply 后读不到补丁数就自动还原。App 起不来时用「设置 → 以安全模式启动」进去卸插件。

## 破甲到底能做什么

[CAPABILITIES.md](CAPABILITIES.md) 按补丁编号逐条列出 88 条补丁的作用、在手机上是否适用、怎么验证。

## 出问题先看这个

[VERIFY.md](VERIFY.md) 有七步验收清单，每步写明「期望看到什么 / 不对怎么办」。
部署时遇到异常先翻 [BUGS.md](BUGS.md) —— 已知的坑、根因、修复版本都在里面，附快速对照表。

最常遇到的一个：红队模式会话里发第一条消息会弹「环境还没配好 / 需要 Kali」。
这是宿主前端缓存时序的老毛病，点「确认暂不配置」即可，之后不再弹。

## 卸载

```sh
cd /root/phone-armor
sh preflight/install-preflight.sh uninstall
sh guard/guard-install.sh uninstall
sh armor.sh revert
```

命令提示那层会把改过名的系统程序改回去，真程序从头到尾没被删过。

## 仓库内容

```
bootstrap.sh              远程自举：找 node → 三源回退下载 → SHA256 校验 → 依次安装
armor.sh                  破甲本体：定位 → 备份 → 落位 → 注册 → 注入 → apply → 自检 → 回滚
preflight/lib/index.js    风险预检插件（agent/pre-step + llm.stream + userQuestions.ask）
guard/guard.sh            命令风险提示（默认只提示，配置可改为拦截）
tier-gate/                可选的静态闸门（进会话弹一次三档总表，默认不装）
payload/                  破甲包 1.6.91 + 含规则的注入正文
capability-tiers.md       三档划分的完整依据
VERIFY.md                 手机端七步验收
docs/                     实测环境与踩坑记录
```

## 为什么不用官方 `scripts/install.sh`

官方安装链最后落 `bootstrap-install.mjs`，Linux+web 分支会走 `prepareLinuxHost` ——
宿主不可写时会把整份 DSH 复制到 `~/.local/share/dsh-purge/hosts/` 再打补丁，
而 App 启动的仍是 `/opt/dsh-app` 那份，等于白打。

`armor.sh` 自己走等价路径，并在 apply **之前**检查宿主可写性，只读就直接停手。

## 许可

破甲包 `dsh-purge-community` 版权归其上游作者；本仓库的安装器与预检插件为 MIT。
