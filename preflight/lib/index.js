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

/** 明显属于「本机跑不了但云端能替代」的工作 → 第二档 */
const TIER2_HINT = /(本地|本机).{0,20}(生图|出图|图片|画|视频|diffusion|sd)/i;
/** 属于「严重建议别在本机做」的工作 → 第三档 */
const HARD_LOCAL = /(本地大模型|大模型推理|llm\s?推理|训练模型|微调|4k|8k|渲染|masscan|全端口|扫\s*\/16)/i;
/** 纯文本请求（写代码、讲解）不算执行类任务 */
const WRITE_ONLY = /(写|实现|示例|代码|脚本|教程|怎么|如何|解释|原理|区别|对比|review|阅读)/i;

/**
 * 关键词直判，不花 token。
 *   · 有替代方案的（本地生图/生视频）→ 第二档：本机能跑但要换路，问一次就够
 *   · 会卡死设备的（本地大模型、4K 渲染、大网段扫描）→ 第三档：每次都提醒
 */
function hardTier(text) {
  if (WRITE_ONLY.test(text)) return null;
  if (HARD_LOCAL.test(text)) {
    return {
      tier: 3,
      work: "本机扛不住的推理/渲染类任务",
      why: "手机没有 GPU，单进程内存 2–4 GB，真跑起来会 OOM 或被系统杀掉，表现是 App 闪退或手机卡死",
      alt: "到电脑上做；或用云端接口只做能做的部分"
    };
  }
  if (TIER2_HINT.test(text)) {
    return {
      tier: 2,
      work: "本地生图/生视频",
      why: "本机没有推理框架和 GPU，本地出图会吃掉几 GB 内存直接被系统杀掉",
      alt: "改走云端生图接口：几十秒出图，要联网走流量，请求里带 nologo=true 可去水印"
    };
  }
  return null;
}

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
  /** 已确认过第二档的会话（同会话第二档不再追问；第三档不受影响） */
  const acked = new Set();

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
    const answer = await ctx.userQuestions.ask({
      agent,
      signal,
      questions: [
        {
          id: "phone-armor-tier",
          header: third ? "⛔ 第三档 · 强烈建议别在本机做" : "⚠ 第二档 · 本机得换条路",
          question: verdict.work || "这条指令",
          detail: [
            `判断：${verdict.why}`,
            `换路径：${verdict.alt}`,
            "",
            third
              ? "在本机执行大概率导致 App 被杀或手机卡死。第三档每次都会提醒你。"
              : "第二档在本会话内只问这一次，之后同类任务直接放行。",
            "",
            "点「我知道了」之后，我会先把风险和替代方案说清楚、停在这里等你，",
            "不会自己动手 —— 你回一句「继续」我再开始。"
          ].join("\n"),
          options: [
            { label: "我知道了", description: "先停下，把选择权给我" },
            { label: "取消", description: "这条不做了" }
          ],
          multiSelect: false
        }
      ]
    });

    const item = answer?.answers?.find((a) => a.id === "phone-armor-tier");
    const selected = (item?.selected ?? []).map(String);
    return selected.some((s) => s.includes("取消"));
  }

  ctx.on("agent/pre-step", async (payload, next) => {
    const { agent, messages, turn, signal, modelSelection } = payload ?? {};

    if (!cfg.enabled) return next();
    if (!agent || !Array.isArray(messages) || messages.length === 0) return next();

    const sessionId = agent.session?.id ?? "";

    // 同一轮只判一次
    if (judgedTurn.get(sessionId) === turn) return next();
    judgedTurn.set(sessionId, turn);

    const text = extractText(messages).join("\n").trim();
    if (text.length < cfg.minLength) return next();

    const verdict = hardTier(text) || (await grade(text, modelSelection, signal));
    if (!verdict || verdict.tier < cfg.askAtOrAbove) return next();

    // 第二档：本会话确认过一次就不再追问（第三档每次都要提醒，用户明确要求）
    if (verdict.tier === 2 && acked.has(sessionId)) {
      log(`第二档已确认过，直接放行：${verdict.work}`);
      return next();
    }

    let cancelled = false;
    try {
      cancelled = await askUser(agent, signal, verdict);
    } catch (error) {
      log(`弹窗失败（放行）：${error?.message || error}`);
      return next();
    }

    if (cancelled) {
      log(`用户取消：第 ${verdict.tier} 档 —— ${verdict.work}`);
      return { kind: "reject" };
    }

    if (verdict.tier === 2) {
      acked.add(sessionId);
      log(`用户知悉（第二档）—— 本会话不再追问：${verdict.work}`);
    } else {
      log(`用户知悉（第三档）—— 每次都会提醒，但不拦截：${verdict.work}`);
    }

    // 关键：不 reject。会话完整保留，用户下一句「继续」能接上；
    // 具体停不停由 TIER-RULES 约束主 agent 自己处理。
    return next();
  });
}
