import { appendFileSync } from "node:fs";

export default function fixtureExtension(pi) {
  pi.registerTool({
    name: "echo",
    label: "Echo",
    description: "Echo text through a Pi-compatible tool.",
    promptSnippet: "Use echo to validate the Pi compatibility adaptor.",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string", description: "Text to echo" },
      },
      required: ["text"],
      additionalProperties: false,
    },
    execute(callId, params, _signal, onUpdate, ctx) {
      onUpdate?.({
        content: [{ type: "text", text: "echoing" }],
        details: { phase: "running", callId },
      });
      return {
        content: [{ type: "text", text: `echo:${params.text}` }],
        details: {
          callId,
          adapter: "pi",
          received: params.text,
          cwd: ctx.cwd,
          projectTrusted: ctx.isProjectTrusted(),
        },
      };
    },
  });

  pi.registerTool({
    name: "delayed_echo",
    label: "Delayed Echo",
    description: "Promise-returning Pi tool used to validate async bridging.",
    parameters: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
    },
    async execute(callId, params, signal, onUpdate) {
      onUpdate?.({
        content: [{ type: "text", text: "waiting" }],
        details: { phase: "waiting", callId },
      });
      await abortableDelay(5, signal);
      return {
        content: [{ type: "text", text: `delayed:${params.text}` }],
        details: { callId, async: true },
      };
    },
  });

  pi.registerTool({
    name: "cancellable_echo",
    label: "Cancellable Echo",
    description: "Long-running Pi tool used to validate AbortSignal propagation.",
    parameters: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
    },
    async execute(callId, params, signal, onUpdate) {
      onUpdate?.({
        content: [{ type: "text", text: "cancellable wait" }],
        details: { phase: "waiting-for-cancel", callId },
      });
      await abortableDelay(10_000, signal);
      return {
        content: [{ type: "text", text: `unexpected:${params.text}` }],
        details: { callId, cancelled: false },
      };
    },
  });

  pi.registerTool({
    name: "background_notify",
    label: "Background Notify",
    description: "Queues a Pi sendMessage follow-up for RuntimeControl testing.",
    parameters: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
    },
    execute(callId, params) {
      pi.appendEntry("fixture-background", { callId, text: params.text });
      pi.sendMessage({
        customType: "fixture-background-ready",
        content: `background:${params.text}`,
        display: true,
      }, { triggerTurn: true });
      return {
        content: [{ type: "text", text: `queued:${params.text}` }],
        details: { callId, queuedFollowUp: true },
      };
    },
  });


  pi.registerTool({
    name: "constrained_echo",
    label: "Constrained Echo",
    description: "Echo tool whose parameters mirror TypeBox numeric/union constraints.",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string", description: "Text to echo", minLength: 1 },
        count: {
          type: "number",
          description: "Echo repeat count",
          minimum: 1,
          maximum: 10,
          default: 1,
        },
        mode: {
          anyOf: [{ type: "string" }, { type: "null" }],
          description: "Optional echo mode",
        },
        tags: {
          type: "array",
          description: "Optional tags appended to the echo",
          items: { type: "string", minLength: 1 },
          minItems: 1,
          maxItems: 5,
        },
      },
      required: ["text"],
      additionalProperties: false,
    },
    execute(callId, params) {
      const count = typeof params.count === "number" ? params.count : 1;
      const base = Array.isArray(params.tags) && params.tags.length > 0
        ? `${params.text}:${params.tags.join(",")}`
        : params.text;
      return {
        content: [{ type: "text", text: Array(count).fill(base).join("|") }],
        details: { callId, count, mode: params.mode ?? null },
      };
    },
  });

  pi.on("session_start", () => {
    pi.appendEntry("fixture-session-start", { entry: "primary" });
  });

  // Events-recorder family: active only when PI_EVENTS_LOG is set, so the
  // adaptor host tests above stay unaffected.
  const eventsLogPath = process.env.PI_EVENTS_LOG;
  if (eventsLogPath) {
    for (const name of [
      "agent_start",
      "agent_end",
      "agent_settled",
      "turn_start",
      "turn_end",
      "message_start",
      "message_update",
      "message_end",
      "tool_execution_start",
      "tool_execution_update",
      "tool_execution_end",
    ]) {
      pi.on(name, (payload) => {
        appendFileSync(eventsLogPath, JSON.stringify({ type: name, ...payload }) + "\n");
      });
    }
  }

  let lateToolRegistered = false;
  pi.on("session_tree", () => {
    if (lateToolRegistered) return;
    lateToolRegistered = true;
    pi.registerTool({
      name: "late_echo",
      label: "Late Echo",
      description: "Dynamically registered after a session_tree event.",
      parameters: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"],
      },
      execute(callId, params) {
        return {
          content: [{ type: "text", text: `late:${params.text}` }],
          details: { callId, dynamicallyRegistered: true },
        };
      },
    });
  });

}

function abortableDelay(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, milliseconds);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(new Error("aborted"));
    }, { once: true });
  });
}
