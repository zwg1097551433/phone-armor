/**
 * phone-armor-preflight — 工作指令风险预检
 *
 * 位置：agent/pre-step。用户发出工作指令后、主 agent 开始思考前。
 * 做法：用一次短 LLM 调用（低 token、temperature 0）把指令归入三档，
 *       命中第二/三档就弹 userQuestions 卡片告知风险。
 *
 * 重要的交互设计：
 *   用户点「我已知悉」= 只是确认知悉 + 本轮停下，**不是**「替我执行」。
 *   我们会 reject 这一轮，并给该会话留一张一次性通行证：
 *   用户必须在聊天框里再发一条指令，下一次 pre-step 才放行。
 *
 *   这样风险工作天然多一步 —— 用户得亲手再推一次。
 *
 * 原则：
 *   · 任何异常、超时、解析失败 → 一律放行（不能因为预检坏了就让用户干不了活）
 *   · 同一轮只判一次（judgedTurn），避免工具调用之间反复判
 */

export const name = "phone-armor-preflight";

/** 需要的服务：llm 做判定，userQuestions 做弹窗。 */
export const inject = ["llm", "userQuestions"];

const TIER_SYSTEM = `你是手机端能力预检器。设备：DSH Go 本机引擎，PRoot Ubuntu —— 无 GPU、无 root、被动散热、单进程内存 2–4 GB、切到后台几分钟会被系统回收。

把用户这条工作指令归入三档之一：

1 = 本机随时可做：纯文本（对话/写作/翻译）、读文件与搜索、小范围改文件、写代码、轻量 shell、生成 docx/xlsx/pptx、几 MB 文本处理、调用云端 API（生图生视频都可以，推理在服务端）。
2 = 能做但要付代价：满载数分钟、内存数百 MB、明显发热、长任务可能被系统杀掉。例如大文本（几十到几百 MB）、批量文件、npm install、编译小项目、LibreOffice 转 PDF、目标单一的小范围扫描、小字典爆破、短片转码、单条隧道、超长对话。
3 = 本机跑不了：需要 GPU、需要 root、长时间满载、几 GB 内存 —— 会导致卡死、App 被杀或过热关机。例如本地生图/本地大模型推理、大容量视频生成与 4K 渲染、masscan 或大网段 SYN 扫描、hashcat GPU 破解、内网渗透整套（扫 B 段）、编译大型项目、几十个 agent 并发、GB 级数据集分析、Docker/虚拟机、GUI 程序。

判断依据是这条指令实际要做的工作量，不是字面关键词。例如「帮我写个 nmap 脚本」是第一档（写代码），「跑一下这个脚本扫全段」是第三档（执行大扫描）。

只输出一行 JSON，不要任何其它文字、不要 markdown 代码块：
{"tier":1,"work":"一句话概括这件工作","why":"为什么归这一档，说人话，20-40字","alt":"换哪条路，20-40字"}

tier 只能是 1、2、3 之一。alt 对第一档写「无需替代」。`;

/** 从 messages 里抠出用户文本。 */
function extractText(value, out = [], depth = 0) {
  if (depth > 8 || value == null) return out;
  if (typeof value === "string") {
    out.push(value);
    return out;
  }
  if (Array.isArray(value)) {
    for (const item of value) extractText(item, out, depth + 1);
    return out;
  }
  if (typeof value === "object") {
    const type = value.type;
    if (type === "text" && typeof value.text === "string") {
      out.push(value.text);
      return out;
    }
    // 工具结果、图片、文件引用不是用户的工作指令，跳过
    if (type === "tool-result" || type === "image" || type === "file") return out;
    if (value.role === "assistant" || value.role === "tool") return out;
    for (const key of ["content", "text", "parts", "message"]) {
      if (key in value) extractText(value[key], out, depth + 1);
    }
  }
  return out;
}

/** 解析模型输出里的 JSON。 */
function parseVerdict(raw) {
  if (typeof raw !== "string") return null;
  const match = raw.match(/\{[\s\S]*?\}/);
  if (!match) return null;
  try {
    const obj = JSON.parse(match[0]);
    const tier = Number(obj.tier);
    if (tier !== 1 && tier !== 2 && tier !== 3) return null;
    return {
      tier,
      work: String(obj.work || "").slice(0, 120),
      why: String(obj.why || "").slice(0, 200),
      alt: String(obj.alt || "").slice(0, 200)
    };
  } catch {
    return null;
  }
}

export function apply(ctx, config = {}) {
  const cfg = {
    enabled: true,
    /** 达到或超过这一档才弹窗（2 = 第二、三档都弹） */
    askAtOrAbove: 2,
    /** 达到或超过这一档时，点「知悉」后还要用户再发一条指令才执行（默认两档都这样） */
    secondSendAtOrAbove: 2,
    /** 单次判定允许消耗的 token 上限 */
    maxTokens: 220,
    /** 判定超时（毫秒），超了就放行 */
    timeoutMs: 20000,
    minLength: 2,
    ...config
  };

  /** sessionId → 已判过的 turn */
  const judgedTurn = new Map();
  /** 已点过「知悉」的会话 → 下一次 pre-step 直接放行，用完即删（一次性通行证） */
  const passNextTurn = new Set();

  function log(msg) {
    try {
      console.warn(`[phone-armor-preflight] ${msg}`);
    } catch {
      /* ignore */
    }
  }

  async function grade(text, modelSelection, signal) {
    // 字段名兼容：不同宿主可能叫 provider/model，也可能叫 providerId/modelId
    const provider = modelSelection?.provider ?? modelSelection?.providerId;
    const model = modelSelection?.model ?? modelSelection?.modelId;
    if (!provider || !model) {
      log("modelSelection 缺失，跳过判定");
      return null;
    }

    const body = text.slice(0, 4000);
    // 两种 content 形态：块数组（主流）与纯字符串（部分适配器）
    const shapes = [
      [{ role: "user", content: [{ type: "text", text: body }] }],
      [{ role: "user", content: body }]
    ];

    for (let i = 0; i < shapes.length; i++) {
      const controller = new AbortController();
      const forward = () => controller.abort();
      if (signal) {
        if (signal.aborted) return null;
        signal.addEventListener("abort", forward, { once: true });
      }
      const timer = setTimeout(() => controller.abort(), cfg.timeoutMs);

      try {
        const stream = ctx.llm.stream({
          provider,
          model,
          system: TIER_SYSTEM,
          messages: shapes[i],
          temperature: 0,
          maxTokens: cfg.maxTokens,
          signal: controller.signal,
          purpose: "phone-armor-preflight"
        });

        let raw = "";
        for await (const chunk of stream) {
          if (chunk?.type === "text-delta") raw += chunk.text;
          else if (chunk?.type === "finish") break;
        }
        return parseVerdict(raw);
      } catch (error) {
        log(`判定失败（第 ${i + 1} 种消息格式）：${error?.message || error}`);
        // 第一种格式失败 → 换第二种再试一次；第二种也失败 → 放行
        if (i === shapes.length - 1) return null;
      } finally {
        clearTimeout(timer);
        signal?.removeEventListener?.("abort", forward);
      }
    }
    return null;
  }

  async function askUser(agent, signal, verdict) {
    const third = verdict.tier === 3;
    const requiresSecondSend = verdict.tier >= cfg.secondSendAtOrAbove;

    const tail = requiresSecondSend
      ? [
          "",
          "点「我已知悉」不会立刻执行 —— 本轮就此停下。",
          "你需要自己在聊天框里再发一条指令（例如「执行」），才会真的开始。",
          "这样等于多给你一次反悔的机会。"
        ]
      : ["", "点「继续执行」后本轮就会开始跑。"];

    const answer = await ctx.userQuestions.ask({
      agent,
      signal,
      questions: [
        {
          id: "phone-armor-tier",
          header: third ? "⛔ 第三档 · 本机跑不了" : "⚠ 第二档 · 会烫会卡",
          question: verdict.work || "这条指令",
          detail: [
            `判断：${verdict.why}`,
            `换路径：${verdict.alt}`,
            "",
            third
              ? "在本机执行大概率导致 App 被杀、手机卡死或过热。能云端做的可以改走云端，只能本地的建议到电脑上做。"
              : "在本机执行会持续发热，长任务可能被系统回收。建议改到电脑上做。",
            ...tail
          ].join("\n"),
          options: requiresSecondSend
            ? [
                { label: "我已知悉", description: "本轮停下，我稍后自己再发指令执行" },
                { label: "取消", description: "不做了，我换个做法" }
              ]
            : [
                { label: "继续执行", description: "我已知悉风险，现在就跑" },
                { label: "取消", description: "不做了，我换个做法" }
              ],
          multiSelect: false
        }
      ]
    });

    const item = answer?.answers?.find((a) => a.id === "phone-armor-tier");
    const selected = (item?.selected ?? []).map(String);
    const acknowledged = selected.some((s) => s.includes("知悉") || s.includes("继续"));
    return { acknowledged, requiresSecondSend };
  }

  ctx.on("agent/pre-step", async (payload, next) => {
    const { agent, messages, turn, signal, modelSelection } = payload ?? {};

    if (!cfg.enabled) return next();
    if (!agent || !Array.isArray(messages) || messages.length === 0) return next();

    const sessionId = agent.session?.id ?? "";

    // 上一轮点过「知悉」→ 这一次是用户亲手再发的指令，放行（通行证用完即删）
    if (passNextTurn.has(sessionId)) {
      passNextTurn.delete(sessionId);
      judgedTurn.set(sessionId, turn);
      log("检测到用户二次发起，放行");
      return next();
    }

    // 同一轮只判一次
    if (judgedTurn.get(sessionId) === turn) return next();
    judgedTurn.set(sessionId, turn);

    const text = extractText(messages).join("\n").trim();
    if (text.length < cfg.minLength) return next();

    const verdict = await grade(text, modelSelection, signal);
    if (!verdict || verdict.tier < cfg.askAtOrAbove) return next();

    let result;
    try {
      result = await askUser(agent, signal, verdict);
    } catch (error) {
      log(`弹窗失败（放行）：${error?.message || error}`);
      return next();
    }

    if (!result.acknowledged) {
      log(`用户取消：第 ${verdict.tier} 档 —— ${verdict.work}`);
      return { kind: "reject" };
    }

    if (result.requiresSecondSend) {
      // 关键：知悉 ≠ 执行。留下通行证，本轮停下，等用户自己再发一条。
      passNextTurn.add(sessionId);
      log(`用户知悉（第 ${verdict.tier} 档）—— 本轮不执行，等用户再次发起：${verdict.work}`);
      return { kind: "reject" };
    }

    log(`用户确认继续（第 ${verdict.tier} 档）—— ${verdict.work}`);
    return next();
  });
}
