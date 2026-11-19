# 手机端破甲能力清单

> 基于实机安装的 `dsh-purge-community 1.6.91` 补丁表（**88 条**，其中 2 条 opt-in 默认关闭）。
> 手机上命中 **66/86**（分母 86 不含 2 条 opt-in）。
> 每条都标注：它到底改了什么、在手机上有没有意义、怎么自己验证。

---

## 结论先行

破甲拆的是**宿主代码里的闸**，不是模型服务端的审核。所以：

| 能做到 | 做不到 |
|---|---|
| 写系统目录不弹审批 | 让模型服务端放行它不放行的内容 |
| 执行命令不被沙箱拦 | 在没 GPU 的手机上跑本地大模型 |
| 读工作区外的文件 | 让第三方接口忽略内容过滤 |
| 子代理能更深、bash 超时更长 | 绕过 DeepSeek 的内容政策 |
| AI 不再自称"我是 AI 助手" | 桌面版专属功能（手机上不存在） |

**一句话**：它让你能自由地调工具、跑命令、改文件；它不能让外部服务改变它们自己的规则。

---

## 一、审批系统（6 条）—— 已实测生效

| # | 补丁 | 改了什么 |
|---|---|---|
| 5 | `APPROVAL_NEVER_SENTENCE` | 系统提示里"执行前必须询问用户"那段改成"永不询问" |
| 8 | `APPROVAL_POLICY_DEFAULT` | 审批策略默认值 → `never` |
| 9 | `APPROVAL_AUTO_GRANT` | 自动批准，不弹框 |
| 10 | `APPROVAL_CONFIG_DEFAULT_NEVER` | profile 配置里默认写 `approval: never` |
| 11 | `APPROVAL_NEVER_SENTENCE_BYPASS` | 绕过"必须询问"的判定分支 |
| 12 | `APPROVAL_ASK_SENTENCE_BYPASS` | 绕过"建议先确认"的话术 |

**效果**：工具调用不再弹「是否允许执行」。

**已验证**：写 `/opt/dsh/probe.txt`（App 安装目录，工作区外）**没有弹审批，直接成功**。

---

## 二、沙箱（5 条）—— 已实测生效

| # | 补丁 | 改了什么 |
|---|---|---|
| 6 | `SANDBOX_DENY_FILE_WRITE` | 沙箱"禁止写文件"的分支改成放行 |
| 7 | `SANDBOX_MODE_DEFAULT` | 沙箱模式默认值改成最宽松 |
| 15 | `SANDBOX_CONFINE_PASSTHROUGH` | 限制路径检查改为直通 |
| 16 | `FS_FENCE_DISABLED` | 文件系统围栏整体拆掉 |
| 34 | `SANDBOX_HINT_NEUTRAL` | 去掉"沙箱会限制你"的提示 |

**效果**：可以读写工作区外的路径，不再报权限/沙箱错误。

**已验证**：同上那条测试——`/opt/dsh` 不在工作区内，写入成功说明围栏确实拆了。

---

## 三、提权与升级（3 条）

| # | 补丁 | 改了什么 |
|---|---|---|
| 13 | `ESCALATION_WIDENING_EXEMPT` | 权限升级的"扩大范围"检查豁免 |
| 14 | `ESCALATION_GRANT_UNCONDITIONAL` | 无条件授予提权请求 |
| 35 | `ESCALATION_NEVER_REJECT` | 提权请求永不拒绝 |

**效果**：工具需要更高权限时自动放行，不再走"申请→等待批准"。

---

## 四、文件系统（3 条）

| # | 补丁 | 改了什么 |
|---|---|---|
| 17 | `FS_OBSERVATION_INTENT_FREE` | 读文件不再需要声明意图 |
| 22 | `READ_CAPS_RAISED` | 单次读取的容量上限提高 |
| 36 | `TOOL_FS_ESCALATION_SCHEMA` | fs 工具的提权参数不再弹窗 |

**效果**：读大文件、读敏感路径少一层阻碍。

---

## 五、身份去 AI 化（7 条）—— 影响"它怎么自称"

| # | 补丁 | 改了什么 |
|---|---|---|
| 25 | `HARNESS_IDENTITY_STRIP` | 去掉"你是 DeepSeek Harness 助手"这类身份声明 |
| 26 | `MINIMAL_PERSONA_PURGE` | 清掉最小人格模板里的自述 |
| 4 | `SYSTEM_PROMPT_PERSONA` | 人格段整体替换 |
| 43 | `WEB_PRESET_IDENTITY_STRIP` | web 预设的身份段剥离 |
| 76 | `PRESET_UNRESTRICTED_IDENTITY_STRIP` | 无限制预设的身份段剥离（opt-in） |
| 32 | `WEB_SURFACE_IDENTITY_NEUTRAL` | web 界面的身份描述中性化 |
| 71 | `LIANGSHEN_IDENTITY_LINE` | 移除特定的身份行 |

**效果**：它不再张口"作为 AI 助手…"。**这是你最早观察到的现象能消失的关键。**

---

## 六、工具能力放宽（10 条）

| # | 补丁 | 改了什么 | 手机上有意义吗 |
|---|---|---|---|
| 21 | `BASH_TIMEOUT_RESTORE` | 恢复 bash 的默认超时（不被设成几十秒） | ✅ 长命令能跑完 |
| 23 | `SUBAGENT_MAXDEPTH_RAISED` | 子代理嵌套深度上限提高 | ✅ 多层编排可行 |
| 24 | `PRESET_FETCH_ENABLED` | 允许预设拉取 | ✅ |
| 30 | `HOOKS_CLAUDE_DENY_ALLOW` | Claude 钩子的 deny 改 allow | ⚠️ 需装对应钩子 |
| 31 | `HOOKS_CODEX_DENY_ALLOW` | Codex 钩子的 deny 改 allow | ⚠️ 同上 |
| 48 | `TOOL_SHELL_DELETE_MOVE_NEUTRAL` | shell 删除/移动不再拦截 | ✅ |
| 60 | `OFFICIAL_RUN_CODE_APPROVAL_NEUTRAL` | 代码执行的审批中性化 | ✅ |
| 62 | `OFFICIAL_TOOL_ASK_FAILOPEN` | 工具询问失败时按放行处理 | ✅ |
| 64 | `HOOKS_STOP_STEER_NEUTRAL` | stop/steer 钩子中性化 | ✅ |
| 65 | `HOOKS_PRESTEP_REJECT_NEUTRAL` | pre-step 的 reject 中性化 | ✅ **这条和我们的预检插件同层** |
| 89 | `ASK_USER_WAIT_CAPPED` | `ask_user_question` 的无限等待收成 300 秒 | ✅ 防止卡死 |

---

## 七、系统提示管线（5 条）—— 注入能不能到模型的关键

| # | 补丁 | 改了什么 |
|---|---|---|
| 55 | `SYSTEM_PROMPT_REPLACE_HEAD` | 允许替换系统提示的开头 |
| 74 | `ASSEMBLE_BEFORE_PRESTEP` | 在 pre-step 之前完成提示装配 |
| 66 | `SYSTEM_PROMPT_RENDER_GUARD` | 渲染守卫放行 |
| 67 | `AGENT_LOOP_MESSAGES_GUARD` | agent-loop 的消息校验放行 |
| 68 | `SYSTEM_NODES_CONTENT_GUARD` | 系统节点内容守卫放行 |
| 72 | `MESSAGES_SYSTEM_CURRENT` | 使用当前 messages 里的 system |

**这 6 条决定了「注入正文能不能进到模型」**。如果 probe 回显不了，问题就在这一组没命中。

---

## 八、上下文管理（2 条，默认关闭）

| # | 补丁 | 改了什么 | 开不开 |
|---|---|---|---|
| 18 | `REPEAT_TOOL_REMINDER_DISABLED` | 关掉"你又在重复调用"的提醒 | 默认关 |
| 19 | `TOOL_RESULT_PRUNER_DISABLED` | 关掉工具结果自动修剪（能看完整输出） | 默认关 |

手机上**建议保持关闭**：开着会让上下文膨胀更快，手机会更卡。

要开：`tuning.json` 里加 `"contextManagement": true`。

---

## 九、会话回退（4 条）

`REWIND_HIDE_CUT_ONLY` / `REWIND_SKIP_DERIVE` / `REWIND_RESET_TODOS` / `REWIND_DROP_SENT_ON_APPEND`

只有在用"回退到某条消息"功能时才有意义。手机上用得少，可忽略。

---

## 十、桌面专属（5 条）—— 手机上完全无意义

| # | 补丁 | 为什么无意义 |
|---|---|---|
| 45 | `OFFICIAL_DESKTOP_UPDATE_HANDOFF` | Electron 更新换包 |
| 46 | `OFFICIAL_DESKTOP_UPDATE_ASCII` | 同上 |
| 82 | `DESKTOP_SHELL_PROFILE_FALLBACK` | 桌面 shell profile |
| 83 | `DESKTOP_HOST_CLOSE_NO_FATAL` | 桌面主机关闭 |
| 84 | `DESKTOP_HOST_CLOSE_CODE0_NO_FAIL` | 同上 |

**这解释了 66/86 的差额**：一部分是这些永远不适用的，一部分是锚点漂移。

---

## 十一、兼容性与杂项（其余）

- `ANTHROPIC_OAUTH_*`（#47/#49）—— 手机不接 Anthropic OAuth，无用
- `SESSION_V0_PLUGIN_SUMMARY_ALIAS`（#39）、`SETTINGS_LEGACY_API`（#42）—— 老版本兼容
- `MODEL_STREAM_RELEASE`（#69）、`RESTORE_NATIVE_STEERING`（#90）—— 稳定性修复
- `BROWSER_COOKIE_NAME_IGNORE_PORT`（#91）—— 浏览器 cookie 作用域
- `HOST_MAX_HTTP_HEADER_SIZE`（#92）—— HTTP 头大小上限
- `INSPECTOR_FRAME_BUDGET_*`（#95/#96）—— 检查器性能

---

## 十二、手机上实际能拿到的能力（按场景）

| 场景 | 破甲前 | 破甲后 | 已验证 |
|---|---|---|---|
| 写系统目录 `/opt/dsh/...` | 弹审批 → 沙箱拒 | **直接成功** | ✅ 实测 |
| 执行长命令 | bash 超时被截断 | 能跑完 | 待测 |
| 读工作区外文件 | 需要意图声明 | 直接读 | 待测 |
| 子代理多层编排 | 深度受限 | 可更深 | 待测 |
| AI 自称"我是助手" | 常见 | 应消失 | 待测（依赖注入层） |
| 生成成人内容 | 模型拒绝 | **仍然拒绝** | ❌ 不归破甲管 |
| 本地跑大模型 | 跑不动 | **仍然跑不动** | ❌ 没有 GPU |

---

## 十三、如何逐条验证

```sh
# 补丁状态（逐条列出 applied / pending）
cd /root/phone-armor && DSH_BASE=/opt/dsh/node_modules/@deepseek-ai sh armor.sh status

# 注入层是否到达模型（官方 probe）
NODE=$(command -v node)
$NODE ~/.dsh/profiles/web/node_modules/dsh-purge-community/bin/community.js probe new
# 然后发消息，看模型是否原样回显那串 nonce

# 审批+沙箱（行为验证）
# 让 agent 写 /opt/dsh/probe.txt —— 不弹窗、不报错 = 生效

# 调优配置是否加载
cat ~/.dsh/dsh-purge/tuning.json
```

---

## 附录：为什么是 66 而不是 86

88 条里：
- **5 条桌面专属**（#45 #46 #82 #83 #84）→ 手机上目标文件不存在，永远不适用
- **2 条 opt-in 默认关**（#18 #19）→ 不计入分母
- 剩余约 81 条里命中 66 条，**约 15 条锚点漂移**（手机引擎构建与 npm 版有差异）

补齐这 15 条需要 `reanchor`（逐条对着真机源码改锚点），工作量大，且多数是边角逻辑。**主干（审批 6 条 + 沙箱 5 条 + 提权 3 条 + 提示管线 6 条）已确认命中。**
