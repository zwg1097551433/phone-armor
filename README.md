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

## 三层结构

| 层 | 作用 | 装在手机的哪 |
|---|---|---|
| **破甲本体** | 86 条源码补丁 + 注入正文，拆掉审批弹窗与沙箱拦截 | `~/.dsh` + 引擎目录 |
| **风险预检** | `agent/pre-step` 上的一次短 LLM 调用（约 200 token），三档评级 + 弹窗 | `~/.dsh/profiles/web/node_modules` |
| **命令提示** | `nmap` / `masscan` / `hashcat` 等执行前打一行黄字，**只提示不拦截** | `/opt/phone-armor` |

想只要其中一部分：

```sh
ARMOR_SKIP_PREFLIGHT=1 sh bootstrap.sh   # 只要破甲 + 命令提示
ARMOR_SKIP_GUARD=1 sh bootstrap.sh       # 只要破甲 + 预检
```

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
