///|
// The JS guest owns plugin closures, promises, and the emulated Pi API. This state is intentionally opaque to MoonBit.
// Keep foreign-runtime implementation here; the public Pi/Posoco mapping lives
// in adaptor, event_observer, hook_adaptor, and runtime_adaptor.

///|
/// JS-owned Pi extension host. Its internal representation deliberately stays
/// outside MoonBit so arbitrary Pi packages can retain JavaScript closures,
/// AbortSignals, Promises, and extension-local state.
#external
pub type JsPiHost

///|
/// Native JavaScript Promise returned to Node/Bun callers.
#external
pub type JsPromise

///|
/// Host-supplied callback that issues one UiPort request and resolves to the
/// correlated ui_response JSON string: `(requestJson) => Promise<responseJson>`.
/// Wire shapes are exactly the ones cetas-js JsUiPort emits/parses.
#external
pub type JsUiRequestFn

///|
/// Host-supplied callback that receives one UiRender event:
/// `(renderJson) => void`.
#external
pub type JsUiRenderFn

///|
/// Normalized synchronous tool result used by ToolProvider::execute.
#external
priv type JsToolResult

///|
extern "js" fn js_host_new() -> JsPiHost =
  #| () => {
  #|   const state = {
  #|     cwd: process.cwd(),
  #|     projectTrusted: false,
  #|     tools: [],
  #|     byName: new Map(),
  #|     handlers: new Map(),
  #|     updates: [],
  #|     entries: [],
  #|     messages: [],
  #|     followUps: [],
  #|     customEntries: [],
  #|     customEmit: null,
  #|     shortcuts: [],
  #|     commands: [],
  #|     messageRenderers: [],
  #|     toolRenderers: [],
  #|     hiddenTools: new Set(),
  #|     inflight: new Map(),
  #|     effects: new Map(),
  #|     settledEffects: new Set(),
  #|     followUpCallback: null,
  #|     uiOnRequest: null,
  #|     uiOnRender: null,
  #|     uiSeq: 0,
  #|     catalogVersion: 0,
  #|     // Active-set semantics: null means every registered tool is active
  #|     // (pi's default); otherwise it holds exactly the active names.
  #|     activeTools: null,
  #|     onCatalogChange: null,
  #|   };
  #|
  #|   const renderContent = (blocks) =>
  #|     (Array.isArray(blocks) ? blocks : []).map((block) => {
  #|       if (block?.type === "text") return String(block.text ?? "");
  #|       if (block?.type === "image") return `[image:${block.mimeType ?? block.mediaType ?? "unknown"}]`;
  #|       return JSON.stringify(block);
  #|     }).join("\n");
  #|
  #|   const normalizePiResult = (result) => {
  #|     const normalized = result && typeof result === "object"
  #|       ? result
  #|       : { content: [{ type: "text", text: String(result ?? "") }] };
  #|     const failed = normalized.isError === true || normalized.details?.error != null;
  #|     return {
  #|       ok: !failed,
  #|       content: renderContent(normalized.content),
  #|       details: normalized.details ?? null,
  #|       terminate: normalized.terminate === true,
  #|       cancelled: false,
  #|     };
  #|   };
  #|
  #|   const errorResult = (message, cancelled = false) => ({
  #|     ok: false,
  #|     content: message,
  #|     details: { error: message, cancelled },
  #|     terminate: false,
  #|     cancelled,
  #|   });
  #|
  #|   // ui.* projection: requests ride the injected onRequest callback using the
  #|   // exact ui_request/ui_response JSON protocol of cetas-js JsUiPort; renders
  #|   // ride onRender with JsUiPort's ui_render shape. Uncorrelated, malformed,
  #|   // error, or rejected responses degrade to pi's own defaults (false /
  #|   // undefined). Coroutine safety: the whole await chain here lives in JS —
  #|   // MoonBit never parks a coroutine on these promises, and resolution never
  #|   // re-enters MoonBit synchronously — so awaiting ctx.ui.* inside pi tool
  #|   // executes and event handlers is safe, unlike a MoonBit-side foreign
  #|   // promise wait, which requires a from_async-scheduled coroutine.
  #|   const uiRequestEvent = (requestId, request) =>
  #|     JSON.stringify({ type: "ui_request", request_id: requestId, request });
  #|
  #|   const uiRenderEvent = (slot, key, body, ttlMs) =>
  #|     JSON.stringify({
  #|       type: "ui_render",
  #|       render: {
  #|         slot,
  #|         key,
  #|         title: "",
  #|         body,
  #|         ...(ttlMs === undefined ? {} : { ttl_ms: ttlMs }),
  #|       },
  #|     });
  #|
  #|   const emitUiRender = (slot, key, body, ttlMs) => {
  #|     if (typeof state.uiOnRender !== "function") return;
  #|     state.uiOnRender(uiRenderEvent(slot, key, body, ttlMs));
  #|   };
  #|
  #|   const requestUi = async (request) => {
  #|     if (typeof state.uiOnRequest !== "function") return null;
  #|     const requestId = `pi-ui-${state.uiSeq++}`;
  #|     try {
  #|       const responseJson = await state.uiOnRequest(uiRequestEvent(requestId, request));
  #|       const parsed = typeof responseJson === "string" ? JSON.parse(responseJson) : null;
  #|       if (
  #|         !parsed ||
  #|         parsed.type !== "ui_response" ||
  #|         parsed.request_id !== requestId ||
  #|         parsed.error != null
  #|       ) {
  #|         return null;
  #|       }
  #|       return parsed.response ?? null;
  #|     } catch {
  #|       return null;
  #|     }
  #|   };
  #|
  #|   const makeContext = () => ({
  #|     cwd: state.cwd,
  #|     mode: "json",
  #|     hasUI: typeof state.uiOnRequest === "function",
  #|     isProjectTrusted: () => state.projectTrusted,
  #|     sessionManager: { getBranch: () => state.entries.slice() },
  #|     model: null,
  #|     modelRegistry: {
  #|       getAvailable: () => [],
  #|       find: () => undefined,
  #|       getApiKeyAndHeaders: async () => ({ ok: false }),
  #|     },
  #|     ui: {
  #|       theme: {
  #|         fg: (_slot, text) => text,
  #|         bg: (_slot, text) => text,
  #|         bold: (text) => text,
  #|       },
  #|       async confirm(title, message) {
  #|         const prompt = message ? `${title}\n${message}` : String(title ?? "");
  #|         const response = await requestUi({ type: "confirm", prompt, default_yes: true });
  #|         return response?.type === "yes";
  #|       },
  #|       async select(title, options, _opts) {
  #|         const choices = Array.isArray(options) ? options.map(String) : [];
  #|         const response = await requestUi({ type: "select", title: String(title ?? ""), options: choices });
  #|         if (response?.type !== "selected") return undefined;
  #|         const index = response.index;
  #|         return Number.isInteger(index) && index >= 0 && index < choices.length
  #|           ? choices[index]
  #|           : undefined;
  #|       },
  #|       async input(title, placeholder) {
  #|         const request = { type: "input", prompt: String(title ?? "") };
  #|         if (placeholder != null) request.placeholder = String(placeholder);
  #|         const response = await requestUi(request);
  #|         return response?.type === "text" && typeof response.text === "string"
  #|           ? response.text
  #|           : undefined;
  #|       },
  #|       notify(message) {
  #|         state.uiSeq += 1;
  #|         emitUiRender(
  #|           "notice",
  #|           `pi-notice-${state.uiSeq}`,
  #|           { type: "text", text: String(message ?? "") },
  #|           8000,
  #|         );
  #|       },
  #|       setStatus(key, text) {
  #|         emitUiRender(
  #|           "status",
  #|           `pi-status-${key ?? ""}`,
  #|           { type: "text", text: text == null ? "" : String(text) },
  #|         );
  #|       },
  #|       setWidget(key, content) {
  #|         if (typeof content === "function") return;
  #|         const body = Array.isArray(content)
  #|           ? { type: "lines", lines: content.map(String) }
  #|           : { type: "text", text: "" };
  #|         emitUiRender("widget", `pi-widget-${key ?? ""}`, body);
  #|       },
  #|     },
  #|   });
  #|
  #|   const emitFireAndForget = (event, payload) => {
  #|     (async () => {
  #|       const handlers = state.handlers.get(event) ?? [];
  #|       const context = makeContext();
  #|       for (const handler of handlers) await handler(payload, context);
  #|     })().catch(() => {});
  #|   };
  #|
  #|   // One filtered view of the registry consulted by every catalog accessor
  #|   // (count/name/description/schema/catalog JSONs) so their indices stay in
  #|   // lockstep: null keeps all registered tools visible, an active set keeps
  #|   // only the tools whose name it holds. Registration order is preserved.
  #|   const visibleTools = () =>
  #|     state.activeTools === null
  #|       ? state.tools
  #|       : state.tools.filter((tool) => state.activeTools.has(tool.name));
  #|
  #|   // Registration and visibility changes both bump the catalog version and
  #|   // notify the MoonBit side, whose dirty flag drives republishing at the
  #|   // next model call.
  #|   const bumpCatalog = () => {
  #|     state.catalogVersion += 1;
  #|     state.onCatalogChange?.();
  #|   };
  #|
  #|   const registerTool = (tool) => {
  #|     if (!tool || typeof tool !== "object") throw new TypeError("registerTool expects an object");
  #|     if (typeof tool.name !== "string" || tool.name.length === 0) throw new TypeError("Pi tool name must be non-empty");
  #|     if (typeof tool.execute !== "function") throw new TypeError(`Pi tool '${tool.name}' has no execute function`);
  #|     if (state.byName.has(tool.name)) throw new Error(`duplicate Pi tool '${tool.name}'`);
  #|     const normalized = {
  #|       ...tool,
  #|       description: typeof tool.description === "string" ? tool.description : "",
  #|       parameters: tool.parameters ?? { type: "object", properties: {} },
  #|     };
  #|     state.tools.push(normalized);
  #|     state.byName.set(normalized.name, normalized);
  #|     // pi parity (_refreshToolRegistry): a tool registered after an
  #|     // explicit setActiveTools call still joins the active set; the null
  #|     // default already shows everything.
  #|     if (state.activeTools !== null) state.activeTools.add(normalized.name);
  #|     bumpCatalog();
  #|   };
  #|
  #|   const on = (event, handler) => {
  #|     const list = state.handlers.get(event) ?? [];
  #|     list.push(handler);
  #|     state.handlers.set(event, list);
  #|     return () => {
  #|       const current = state.handlers.get(event) ?? [];
  #|       state.handlers.set(event, current.filter((item) => item !== handler));
  #|     };
  #|   };
  #|
  #|   // triggerTurn envelopes go to the AgentControl callback. Only the
  #|   // explicit "Parked" outcome enters state.followUps; a terminal
  #|   // "Failed:<reason>" outcome is thrown back to the Pi caller.
  #|   const sendMessage = (message, options = {}) => {
  #|     const envelope = { message, options };
  #|     state.messages.push(envelope);
  #|     if (options?.triggerTurn === true) {
  #|       if (typeof state.followUpCallback === "function") {
  #|         const outcome = state.followUpCallback(JSON.stringify(envelope));
  #|         if (outcome === "Parked") {
  #|           state.followUps.push(envelope);
  #|         } else if (outcome !== "Accepted") {
  #|           if (typeof outcome === "string" && outcome.startsWith("Failed:")) {
  #|             throw new Error(`Pi follow-up enqueue failed: ${outcome.slice(7)}`);
  #|           }
  #|           throw new Error(`Pi follow-up enqueue returned unknown outcome: ${String(outcome)}`);
  #|         }
  #|       } else {
  #|         state.followUps.push(envelope);
  #|       }
  #|     }
  #|   };
  #|
  #|   const appendEntry = (customType, data) => {
  #|     const entry = { type: "custom", customType, data };
  #|     state.entries.push(entry);
  #|     state.customEntries.push(entry);
  #|     if (typeof state.customEmit === "function") {
  #|       state.customEmit(String(customType ?? ""), JSON.stringify(data ?? null));
  #|     }
  #|   };
  #|
  #|   const api = {
  #|     registerTool,
  #|     on,
  #|     appendEntry,
  #|     sendMessage,
  #|     // pi parity: a user message always triggers a turn; string or
  #|     // content-block array collapses to text for the follow-up envelope.
  #|     sendUserMessage(content, options = {}) {
  #|       const text = typeof content === "string"
  #|         ? content
  #|         : Array.isArray(content)
  #|           ? content
  #|             .filter((block) => block?.type === "text")
  #|             .map((block) => String(block.text ?? ""))
  #|             .join("\n")
  #|           : String(content ?? "");
  #|       sendMessage(
  #|         { customType: "", content: text, display: true },
  #|         { ...options, triggerTurn: true },
  #|       );
  #|     },
  #|     registerCommand(name, command) {
  #|       state.commands.push({
  #|         name: String(name ?? ""),
  #|         description: command?.description == null ? "" : String(command.description),
  #|         handler: typeof command?.handler === "function" ? command.handler : null,
  #|       });
  #|     },
  #|     registerShortcut(key, shortcut) {
  #|       state.shortcuts.push({
  #|         key: String(key ?? ""),
  #|         description: shortcut?.description == null ? "" : String(shortcut.description),
  #|         handler: typeof shortcut?.handler === "function" ? shortcut.handler : null,
  #|       });
  #|     },
  #|     // pi api.exec parity: spawn argv directly (no shell), never rejects,
  #|     // and resolves {stdout, stderr, code, killed} exactly like pi's ExecResult.
  #|     async exec(command, args, options = {}) {
  #|       const { spawn } = await import("node:child_process");
  #|       return await new Promise((resolve) => {
  #|         let stdout = "";
  #|         let stderr = "";
  #|         let killed = false;
  #|         let settled = false;
  #|         let timeoutId;
  #|         const finish = (code) => {
  #|           if (settled) return;
  #|           settled = true;
  #|           if (timeoutId) clearTimeout(timeoutId);
  #|           resolve({ stdout, stderr, code: code ?? 0, killed });
  #|         };
  #|         let proc;
  #|         try {
  #|           proc = spawn(String(command), Array.isArray(args) ? args.map(String) : [], {
  #|             cwd: options?.cwd ?? state.cwd,
  #|             shell: false,
  #|             stdio: ["ignore", "pipe", "pipe"],
  #|           });
  #|         } catch {
  #|           return finish(1);
  #|         }
  #|         const killProcess = () => {
  #|           if (killed) return;
  #|           killed = true;
  #|           proc.kill("SIGTERM");
  #|           setTimeout(() => {
  #|             if (!proc.killed) proc.kill("SIGKILL");
  #|           }, 5000);
  #|         };
  #|         if (options?.timeout && options.timeout > 0) {
  #|           timeoutId = setTimeout(killProcess, options.timeout);
  #|         }
  #|         proc.stdout?.on("data", (data) => { stdout += data.toString(); });
  #|         proc.stderr?.on("data", (data) => { stderr += data.toString(); });
  #|         proc.on("error", () => finish(1));
  #|         proc.on("close", (code) => finish(code));
  #|       });
  #|     },
  #|     registerMessageRenderer(customType, renderer) {
  #|       state.messageRenderers.push({ customType, hasRenderer: typeof renderer === "function" });
  #|     },
  #|     registerToolRenderer(name, renderer) {
  #|       state.toolRenderers.push({ name, hasRenderer: typeof renderer === "function" });
  #|     },
  #|     // pi 0.84.x ExtensionAPI parity. getAllTools projects the full
  #|     // registry and ignores the active set; setActiveTools follows pi's
  #|     // setActiveToolsByName — names absent from the registry are silently
  #|     // ignored (so an all-unknown list deactivates everything), duplicates
  #|     // collapse, and the change takes effect at the next model call.
  #|     getAllTools() {
  #|       return state.tools.map((tool) => ({
  #|         name: tool.name,
  #|         label: tool.label ?? tool.name,
  #|         description: tool.description,
  #|       }));
  #|     },
  #|     getActiveTools() {
  #|       return visibleTools().map((tool) => tool.name);
  #|     },
  #|     setActiveTools(names) {
  #|       if (!Array.isArray(names)) {
  #|         throw new TypeError("setActiveTools expects an array of tool names");
  #|       }
  #|       const next = new Set();
  #|       for (const name of names) {
  #|         if (typeof name === "string" && state.byName.has(name)) next.add(name);
  #|       }
  #|       state.activeTools = next;
  #|       bumpCatalog();
  #|     },
  #|   };
  #|
  #|   const executeAsync = async (name, callId, argumentsJson, effectId = null) => {
  #|     const tool = state.byName.get(name);
  #|     if (!tool) return JSON.stringify(errorResult(`Unknown Pi tool: ${name}`));
  #|
  #|     let params;
  #|     try { params = JSON.parse(argumentsJson); }
  #|     catch (error) { return JSON.stringify(errorResult(`Invalid arguments JSON: ${error.message}`)); }
  #|
  #|     const controller = new AbortController();
  #|     const effectKey = effectId == null ? null : String(effectId);
  #|     const token = { controller, name, callId, effectId };
  #|     state.inflight.set(callId, token);
  #|     if (effectKey !== null) {
  #|       state.effects.set(effectKey, token);
  #|       state.settledEffects.delete(effectKey);
  #|     }
  #|     // Direct pi event plus the legacy state capture: hosts that drain
  #|     // state.updates keep working; registered handlers see the update live.
  #|     const onUpdate = (update) => {
  #|       state.updates.push({ effectId, callId, name, update });
  #|       emitFireAndForget("tool_execution_update", {
  #|         toolCallId: callId,
  #|         toolName: name,
  #|         args: params,
  #|         partialResult: update,
  #|       });
  #|     };
  #|
  #|     try {
  #|       const result = await tool.execute(callId, params, controller.signal, onUpdate, makeContext());
  #|       return JSON.stringify(normalizePiResult(result));
  #|     } catch (error) {
  #|       const message = error instanceof Error ? error.message : String(error);
  #|       return JSON.stringify(errorResult(message, controller.signal.aborted));
  #|     } finally {
  #|       if (state.inflight.get(callId) === token) state.inflight.delete(callId);
  #|       if (effectKey !== null && state.effects.get(effectKey) === token) {
  #|         state.effects.delete(effectKey);
  #|         state.settledEffects.add(effectKey);
  #|         if (state.settledEffects.size > 1024) {
  #|           const oldest = state.settledEffects.values().next().value;
  #|           state.settledEffects.delete(oldest);
  #|         }
  #|       }
  #|     }
  #|   };
  #|
  #|   return { state, api, makeContext, visibleTools, executeAsync, normalizePiResult, errorResult, renderContent, emitFireAndForget };
  #| }
