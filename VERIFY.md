# 手机端验收清单

装完 bootstrap 之后，按这七步逐条确认。**任何一步不对，把该步的输出贴回来**。

前提：`sh bootstrap.sh` 跑完了，App 里已经**停止 → 启动**过一次本机引擎。

---

## 1. 破甲本体：补丁数对不对

```sh
cd /root/phone-armor && sh armor.sh status
```

期望：`补丁 74/86 已清洗, 0 待清洗`（电脑上实测就是 74/86）。

| 看到的 | 含义 | 怎么办 |
|---|---|---|
| 74/86，0 pending | 完全命中 | 继续第 2 步 |
| 数字明显偏低、pending 很多 | 锚点漂移（引擎版本变了） | 把 `sh armor.sh check` 全贴回来 |
| 一条都没有 | `@deepseek-ai` 没定位到 | 看第 7 节 |

## 2. 宿主路径与可写性

```sh
cd /root/phone-armor && sh armor.sh check
```

重点看两行：

```
@deepseek-ai  /opt/dsh-app/.../node_modules/@deepseek-ai     ← 实际路径
宿主可写性    ✓ 可写                                          ← 决定补丁能不能打进去
```

- **可写** → 破甲全量生效
- **只读** → 只有提示词层生效，脚本会拦住 apply。把输出贴回来，另想办法

## 3. 命令提示：默认只提示不拦截

```sh
docker ps
```

期望：**黄色**一行 `⚠ 风险提示：docker ps`，然后照常执行（报 docker 不存在也算正常）。

```sh
sh /opt/phone-armor/guard.sh test 2>/dev/null || sh /root/phone-armor/guard/guard-install.sh test
```

期望：逐条显示 `⚠ 提示后放行` 或 `⛔ 拦截`，默认配置下大部分是黄字提示。

## 4. 预检：第三档必须弹窗

在 DSH Go 会话里发一条**明显第三档**的指令，例如：

```
在本地用 diffusion 模型生成一张 1024x1024 的图片
```

期望：

1. 主 agent **先不动手**
2. 弹出一张卡片，抬头 `⛔ 第三档 · 本机跑不了`
3. 卡片正文有「判断 / 换路径 / 点我已知悉不会立刻执行」
4. 两个按钮：`我已知悉` / `取消`

## 5. 二次确认：点「我已知悉」之后不该执行

在第 4 步的卡片上点 **`我已知悉`**。

期望：**什么都不发生** —— 这一轮直接停下，主 agent 不干活、不回复、不调用工具。

然后在聊天框里自己发一句：

```
执行
```

期望：这次主 agent **直接开始干活**，不再弹窗。

> 这一步是整个设计的核心。如果点了「我已知悉」agent 就开始跑了，说明 `secondSendAtOrAbove` 没生效，检查 `cordis.patch.yml` 里那段 config。

## 6. 第一档不该被打扰

新开一个会话，发：

```
帮我写一个快速排序的 Python 函数
```

期望：**不弹任何卡片**，直接给代码。

如果第一档也弹窗，说明判定提示词太严，把 `preflight/lib/index.js` 里 `TIER_SYSTEM` 的第一档描述再放宽些。

## 7. 预检没生效时怎么查

预检所有异常都会**静默放行**，所以「不弹窗」有两种可能：判定为第一档，或者它挂了。

看引擎日志里的这几行（App 日志或 `adb logcat` 里搜 `phone-armor-preflight`）：

```
[phone-armor-preflight] 判定失败（第 1 种消息格式）：...
[phone-armor-preflight] 判定失败（第 2 种消息格式）：...
[phone-armor-preflight] 弹窗失败（放行）：...
[phone-armor-preflight] 用户知悉（第 3 档）—— 本轮不执行，等用户再次发起：...
[phone-armor-preflight] 检测到用户二次发起，放行
```

| 日志 | 含义 |
|---|---|
| `判定失败（第 2 种消息格式）` | 两种 content 格式都被拒 → `llm.stream` 契约不同，把报错贴回来 |
| `弹窗失败（放行）` | `userQuestions.ask` 抛错 → 可能是 no provider（纯终端环境） |
| `用户知悉` + `二次发起` | 正常工作 |
| 什么都没有 | 插件没加载 → `sh preflight/install-preflight.sh status` |

---

## 一次性全查

```sh
cd /root/phone-armor
sh armor.sh check
sh armor.sh status
sh preflight/install-preflight.sh status
sh guard/guard-install.sh status
```

四条全绿再开始用。
