# phone-armor

把 `dsh-purge-community` 破甲包装进 **DSH Go（Android）的本机引擎**，并在 agent 开始干活之前加一道**风险预检**。

手机上不需要电脑、不需要 pnpm、不需要联网装依赖 —— 把仓库里的文件拉下来，交给脚本跑完。

---

## 工作流程（这是本仓库的核心）

用户发出一条工作指令之后，实际发生的是：

```
用户输入工作指令
      ↓
┌─────────────────────────────────────┐
│ preflight 预检（独立短 LLM 调用）    │  ← 约 200 token，temperature 0
│ 按「实际要做多少工作」评三档         │
└─────────────────────────────────────┘
      ↓
  第一档 ──→ 静默通过，主 agent 直接干活
      ↓
  第二/三档 ──→ 弹风险卡片
                 ⚠ 第二档 · 会烫会卡
                 ⛔ 第三档 · 本机跑不了
                 ┌──────────┬──────────┐
                 │ 我已知悉 │   取消   │
                 └──────────┴──────────┘
                      ↓            ↓
              本轮停下，不执行   本轮停下
              留一张一次性通行证
                      ↓
        用户自己在聊天框再发一条指令（例如「执行」）
                      ↓
              主 agent 才开始干活（按最小化策略）
```

**核心：点「我已知悉」≠ 替你执行。** 它只是确认知悉 + 关掉弹窗 + 把这一轮停掉。
真正的执行信号永远是用户在聊天框里亲手发出的下一条消息。

这不是多此一举 —— 风险工作天然多了一步，用户得自己再推一次，中间随时可以反悔。

关键设计：

- **判断依据是「这条指令实际要做的工作量」，不是关键词**。写一个 nmap 脚本是第一档（写代码），跑这个脚本扫全段是第三档（执行大扫描）。
- **点「我已知悉」只是知道，不是执行**。插件返回 `{kind:"reject"}` 把这一轮停掉，同时给会话留一张一次性通行证；用户再发一条消息，通行证消耗掉才放行。
- **确认之后就不再拦**。卡顿、进程被杀、过热由设备本身承担 —— 告知义务已履行。
- **预检本身挂了不影响干活**：任何异常、超时、解析失败一律放行。
- **预检和提示词规则不重复**：提示词里明确告诉主 agent「卡片上的知悉不等于执行，只有收到新的用户消息才动手」，所以它不会抢在用户前面跑。

能力分级的完整依据见 [capability-tiers.md](capability-tiers.md)。

## 手机端怎么用

把 [INSTALL-PROMPT.txt](INSTALL-PROMPT.txt) 整段发给 DSH Go 里的 agent（替换掉 `OWNER/REPO`）。

或者自己在 PRoot 终端里跑：

```sh
mkdir -p /root/phone-armor && cd /root/phone-armor
node -e "fetch('https://raw.githubusercontent.com/OWNER/REPO/main/bootstrap.sh').then(r=>r.text()).then(t=>require('fs').writeFileSync('bootstrap.sh',t))"
sh bootstrap.sh
```

装完回 App：**设置 → 本机引擎 → 停止 → 启动**。

装完按 [VERIFY.md](VERIFY.md) 的七步逐条确认 —— 尤其第 5 步（点「我已知悉」之后不该执行）。

**跑之前先做一件事**：设置里关掉「自动进入安全模式」。开着的话，破甲一旦让启动失败会被静默跳过，界面看起来一切正常，极难排查。

## 实测环境（DSH Go 1.1.0）

| 项 | 值 |
|---|---|
| App | DSH Go 1.1.0 (11150838) |
| 本机引擎 | DSH **0.2.2-rc.1**（与电脑版一致） |
| Node.js | v24.22.1 |
| App 安装路径 | `/opt/dsh-app/` |
| 引擎地址 | `127.0.0.1:3080` |
| 引擎启动参数 | `dsh web --patch /opt/dsh-app/*.patch.yml --host 127.0.0.1 --port 3080 --no-open` |

## 四个部件

| 部件 | 装什么 | 默认 |
|---|---|---|
| **A 破甲本体** | 86 条源码补丁 + 注入正文 | 装 |
| **预检** | `agent/pre-step` 上的三档评级 + 风险弹窗 | 装 |
| 静态闸门 | 进会话弹一次三档总表 | **不装**（`ARMOR_WITH_TIER_GATE=1` 才装） |
| 命令提示 | 危险命令执行前打一行提示 | 装 |

### A · 破甲本体 `armor.sh`

```sh
sh armor.sh check      # 只读体检：HOME / node / @deepseek-ai / 宿主可写性 / 补丁数
sh armor.sh install    # 一键注入（幂等）
sh armor.sh repair     # 强制重打（App 升级引擎之后）
sh armor.sh status     # 只看补丁数
sh armor.sh revert     # 回滚
```

**不走官方 `scripts/install.sh`**：它最后落 `bootstrap-install.mjs`，Linux+web 分支会走 `prepareLinuxHost` —— 宿主不可写时把整份 DSH 复制到 `~/.local/share/dsh-purge/hosts/` 再打补丁，而 App 启动的仍是 `/opt/dsh-app` 那份，等于白打。`armor.sh` 自己走等价路径，并在 apply **之前**检查宿主可写性。

注入正文走**合并**不走覆盖：只插/更新 `<!-- TIER-RULES -->` 那一段，你原有的 25 KB 定制原样保留。

### 预检 `preflight/`

一个 host 侧 cordis 插件，挂在 `agent/pre-step`：

```js
ctx.on("agent/pre-step", async ({ agent, messages, turn, signal, modelSelection }, next) => {
  // 同一轮只判一次
  const verdict = await grade(text, modelSelection, signal);   // ctx.llm.stream，maxTokens 220
  if (!verdict || verdict.tier < 2) return next();
  const go = await askUser(agent, signal, verdict);            // ctx.userQuestions.ask
  return go ? next() : { kind: "reject" };
});
```

- 服务注入：`["llm", "userQuestions"]`
- 弹窗用的是 DSH 原生的 `ask_user_question` 卡片，前端有现成 UI，不需要自己写界面
- 用户选「取消」→ 返回 `{kind:"reject"}`，这一轮不进入主 agent
- 用户选「继续」→ `next()`，并记住该会话已确认，后续「继续/好/开始」这类弱指令不再判

```sh
sh preflight/install-preflight.sh install
sh preflight/install-preflight.sh status
sh preflight/install-preflight.sh uninstall
```

### 命令提示 `guard/`

```sh
sh guard/guard-install.sh install     # 装
sh guard/guard-install.sh test        # 自测
sh guard/guard-install.sh uninstall   # 卸
```

默认**只提示不拦截**。配置 `/etc/phone-armor/guard.conf`，每项三档，改完立刻生效：

```conf
masscan=0      # 0 只提示 / 1 拦截 / 2 完全放行
nmap_syn=0
hashcat=0
fscan=0
gogo=0
docker=0
ffmpeg_big=0
bypass_all=0
```

拦截方式是真改名（`/usr/bin/nmap` → `nmap.phone-armor-real`，原位置放包装器），所以走绝对路径也拦得住。卸载就是把名字改回去，真程序从未被删。

## 版本与兼容

| App 版本 | 内置引擎 | 破甲包 |
|---|---|---|
| 1.0.15 | 0.2.2-rc.1 | 1.6.91 ✅ |
| **1.1.0** | **0.2.2-rc.1** | **1.6.91 ✅**（实测） |

电脑端实测 1.6.91 → **74/86 applied，0 pending**。⚠️ 不要用 1.7.17（锚点按 rc.3 校准，在 rc.1 上反而降级）。

## 已知坑：环境门禁误弹

红队模式会话里发第一条消息会弹「环境还没配好 / 需要 Kali」。根因是 `EnvAdaptSendGate` 缓存时序 bug（缓存为空时异步刷新但不等结果），手机新开页面第一次发送必弹。

处理：点「确认暂不配置」，会写 `~/.dsh/redteam/config.json` 的 `envAdaptSkip=true`。

## 维护

| 场景 | 动作 |
|---|---|
| App 升级引擎 | `sh armor.sh repair` |
| 重置运行环境 | `/root` 被清空，重跑 bootstrap |
| 想撤销预检 | `sh preflight/install-preflight.sh uninstall` |
| 想撤销全部 | 三个 uninstall + `sh armor.sh revert` |

## 已知未验证项

- `@deepseek-ai` 在手机上的确切路径与可写性 —— 靠 `sh armor.sh check` 的输出钉死。
- 预检的 `ctx.llm.stream` 调用：`RequestMessage` 的 content 用的是块数组形式（`[{type:"text",text}]`），如果手机端契约不同会抛错 → 自动放行，等于不弹窗。要看 `[phone-armor-preflight]` 的 warn 日志确认。
- 端到端只能在手机上验：本机 node 是内嵌 runtime，从 git bash 启动会阻塞。
