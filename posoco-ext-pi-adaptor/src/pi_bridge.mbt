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
  #|     state.catalogVersion += 1;
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
  #|   // triggerTurn envelopes go to the RuntimeControl callback; when the
  #|   // outcome is anything but "Accepted" (no active run, queue full, no
  #|   // control yet) the envelope parks in state.followUps so the next
  #|   // host-driven turn can drain it instead of being silently lost.
  #|   const sendMessage = (message, options = {}) => {
  #|     const envelope = { message, options };
  #|     state.messages.push(envelope);
  #|     if (options?.triggerTurn === true) {
  #|       if (typeof state.followUpCallback === "function") {
  #|         const outcome = state.followUpCallback(JSON.stringify(envelope));
  #|         if (outcome !== "Accepted") state.followUps.push(envelope);
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
  #|   return { state, api, makeContext, executeAsync, normalizePiResult, errorResult, renderContent, emitFireAndForget };
  #| }

///|
extern "js" fn js_host_load(host : JsPiHost, specifier : String) -> JsPromise =
  #| async (host, specifier) => {
  #|   const imported = await import(specifier);
  #|   const extension = imported.default ?? imported;
  #|   if (typeof extension !== "function") {
  #|     throw new TypeError(`Pi extension '${specifier}' does not export a default function`);
  #|   }
  #|   await extension(host.api);
  #|   return host.state.tools.length;
  #| }

///|
extern "js" fn js_host_set_cwd(host : JsPiHost, cwd : String) -> Unit =
  #| (host, cwd) => { host.state.cwd = cwd }

///|
extern "js" fn js_host_set_project_trusted(
  host : JsPiHost,
  trusted : Bool,
) -> Unit =
  #| (host, trusted) => { host.state.projectTrusted = trusted }

///|
extern "js" fn js_tool_count(host : JsPiHost) -> Int =
  #| (host) => host.state.tools.length

///|
extern "js" fn js_tool_name(host : JsPiHost, index : Int) -> String =
  #| (host, index) => host.state.tools[index]?.name ?? ""

///|
extern "js" fn js_tool_description(host : JsPiHost, index : Int) -> String =
  #| (host, index) => host.state.tools[index]?.description ?? ""

///|
extern "js" fn js_tool_schema_json(host : JsPiHost, index : Int) -> String =
  #| (host, index) => JSON.stringify(host.state.tools[index]?.parameters ?? { type: "object", properties: {} })

///|
extern "js" fn js_catalog_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.tools.map((tool) => ({
  #|   name: tool.name,
  #|   label: tool.label ?? tool.name,
  #|   description: tool.description,
  #|   parameters: tool.parameters,
  #|   promptSnippet: tool.promptSnippet ?? null,
  #| })))

///|
extern "js" fn js_catalog_snapshot_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify({
  #|   version: host.state.catalogVersion,
  #|   tools: host.state.tools.map((tool) => ({
  #|     name: tool.name,
  #|     label: tool.label ?? tool.name,
  #|     description: tool.description,
  #|     parameters: tool.parameters,
  #|     promptSnippet: tool.promptSnippet ?? null,
  #|   })),
  #| })

///|

///|
/// Live prompt self-description of the currently registered Pi tools: one
/// JSON entry per tool carrying a non-empty promptSnippet or
/// promptGuidelines, in registration order. Hidden tools (base wins) never
/// contribute — the model must not see a snippet for a tool it cannot call.
/// Read fresh on every call so the dynamic catalog is always reflected.
extern "js" fn js_prompt_snippets_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.tools
  #|   .filter((tool) => !(host.state.hiddenTools?.has(tool.name) ?? false))
  #|   .map((tool) => ({
  #|     name: tool.name,
  #|     snippet: typeof tool.promptSnippet === "string" ? tool.promptSnippet : "",
  #|     guidelines: Array.isArray(tool.promptGuidelines)
  #|       ? tool.promptGuidelines.filter((item) => typeof item === "string")
  #|       : [],
  #|   })).filter((item) => item.snippet.trim().length > 0 || item.guidelines.length > 0))

///|
extern "js" fn js_execute_sync(
  host : JsPiHost,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsToolResult =
  #| (host, name, callId, argumentsJson) => {
  #|   const tool = host.state.byName.get(name);
  #|   if (!tool) return syncError(`Unknown Pi tool: ${name}`);
  #|   let params;
  #|   try { params = JSON.parse(argumentsJson); }
  #|   catch (error) { return syncError(`Invalid arguments JSON: ${error.message}`); }
  #|
  #|   const controller = new AbortController();
  #|   const onUpdate = (update) => {
  #|     host.state.updates.push({ effectId: null, callId, name, update });
  #|     host.emitFireAndForget("tool_execution_update", {
  #|       toolCallId: callId,
  #|       toolName: name,
  #|       args: params,
  #|       partialResult: update,
  #|     });
  #|   };
  #|   try {
  #|     const raw = tool.execute(callId, params, controller.signal, onUpdate, host.makeContext());
  #|     if (raw && typeof raw.then === "function") {
  #|       return syncError("Pi tool returned a Promise; use PiRuntime with Agent::with_runtime");
  #|     }
  #|     const normalized = host.normalizePiResult(raw);
  #|     return {
  #|       isError: !normalized.ok,
  #|       content: normalized.content,
  #|       detailsJson: JSON.stringify(normalized.details),
  #|     };
  #|   } catch (error) {
  #|     return syncError(error instanceof Error ? error.message : String(error));
  #|   }
  #|
  #|   function syncError(message) {
  #|     return { isError: true, content: message, detailsJson: JSON.stringify({ error: message }) };
  #|   }
  #| }

///|
/// Execute a Pi tool while preserving Promise and AbortSignal semantics.
extern "js" fn js_execute_async(
  host : JsPiHost,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise =
  #| (host, name, callId, argumentsJson) => host.executeAsync(name, callId, argumentsJson, null)

///|
/// Effect-correlated execution used by the public Posoco Runtime seam.
extern "js" fn js_execute_effect_async(
  host : JsPiHost,
  effect_id : Int,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise =
  #| (host, effectId, name, callId, argumentsJson) => host.executeAsync(name, callId, argumentsJson, effectId)

///|
extern "js" fn js_emit_event(
  host : JsPiHost,
  event : String,
  payload_json : String,
) -> JsPromise =
  #| async (host, event, payloadJson) => {
  #|   const handlers = host.state.handlers.get(event) ?? [];
  #|   const payload = JSON.parse(payloadJson);
  #|   const context = host.makeContext();
  #|   for (const handler of handlers) await handler(payload, context);
  #|   return handlers.length;
  #| }

///|
extern "js" fn js_seed_entry(
  host : JsPiHost,
  custom_type : String,
  data_json : String,
) -> Unit =
  #| (host, customType, dataJson) => {
  #|   host.state.entries.push({
  #|     type: "custom",
  #|     customType,
  #|     data: JSON.parse(dataJson),
  #|   });
  #| }

///|
extern "js" fn js_event_names_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify([...host.state.handlers.keys()])

///|
extern "js" fn js_shortcuts_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.shortcuts)

///|
/// Registered Pi command descriptors (name + description, handlers withheld).
extern "js" fn js_commands_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.commands.map(({ name, description }) => ({ name, description })))

///|
/// Run one registered Pi command or shortcut handler. `name` is the bare
/// command name, or "#<key>" for shortcuts. The positional args string is
/// extracted from the host's JSON args (terminal-shell sends
/// {"_positional": ...}); the handler gets the shared makeContext(). Resolves
/// to {thrown, feedback, message} JSON: handlers never reject across the FFI.
extern "js" fn js_invoke_command_async(
  host : JsPiHost,
  name : String,
  args_json : String,
) -> JsPromise =
  #| async (host, name, argsJson) => {
  #|   const shortcut = name.startsWith("#");
  #|   const entry = shortcut
  #|     ? host.state.shortcuts.find((item) => item.key === name.slice(1))
  #|     : host.state.commands.find((item) => item.name === name);
  #|   if (!entry || typeof entry.handler !== "function") {
  #|     return JSON.stringify({ thrown: true, message: `Unknown Pi command: ${name}` });
  #|   }
  #|   let args = "";
  #|   if (!shortcut) {
  #|     try {
  #|       const parsed = JSON.parse(argsJson);
  #|       if (typeof parsed === "string") args = parsed;
  #|       else if (parsed && typeof parsed._positional === "string") args = parsed._positional;
  #|     } catch {}
  #|   }
  #|   try {
  #|     const returned = shortcut
  #|       ? await entry.handler(host.makeContext())
  #|       : await entry.handler(args, host.makeContext());
  #|     return JSON.stringify({ thrown: false, feedback: typeof returned === "string" ? returned : "" });
  #|   } catch (error) {
  #|     return JSON.stringify({
  #|       thrown: true,
  #|       message: error instanceof Error ? error.message : String(error),
  #|     });
  #|   }
  #| }

///|
/// Execute host.api.exec (child_process argv spawn) and resolve to its
/// ExecResult JSON string.
extern "js" fn js_exec_async(
  host : JsPiHost,
  command : String,
  args_json : String,
  options_json : String,
) -> JsPromise =
  #| async (host, command, argsJson, optionsJson) => {
  #|   let args = [];
  #|   let options = {};
  #|   try { args = JSON.parse(argsJson) ?? []; } catch {}
  #|   try { options = JSON.parse(optionsJson) ?? {}; } catch {}
  #|   return JSON.stringify(await host.api.exec(command, args, options));
  #| }

///|
extern "js" fn js_entries_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.entries)

///|
extern "js" fn js_messages_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.messages)

///|
extern "js" fn js_cancel_call(host : JsPiHost, call_id : String) -> Bool =
  #| (host, callId) => {
  #|   const token = host.state.inflight.get(callId);
  #|   if (!token) return false;
  #|   token.controller.abort();
  #|   return true;
  #| }

///|
extern "js" fn js_cancel_effects_json(
  host : JsPiHost,
  effect_ids_json : String,
  reason_json : String,
) -> String =
  #| (host, effectIdsJson, reasonJson) => {
  #|   const effectIds = JSON.parse(effectIdsJson);
  #|   const reason = JSON.parse(reasonJson);
  #|   return JSON.stringify(effectIds.map((effectId) => {
  #|     const key = String(effectId);
  #|     const token = host.state.effects.get(key);
  #|     if (token) {
  #|       token.controller.abort(reason);
  #|       return { effectId, disposition: "Propagated" };
  #|     }
  #|     if (host.state.settledEffects.has(key)) {
  #|       return { effectId, disposition: "AlreadySettled" };
  #|     }
  #|     return { effectId, disposition: "NotPropagated" };
  #|   }));
  #| }

///|
extern "js" fn js_inflight_count(host : JsPiHost) -> Int =
  #| (host) => host.state.inflight.size

///|
extern "js" fn js_updates_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.updates)

///|
extern "js" fn js_take_updates_json(host : JsPiHost) -> String =
  #| (host) => {
  #|   const updates = host.state.updates.splice(0, host.state.updates.length);
  #|   return JSON.stringify(updates);
  #| }

///|
extern "js" fn js_take_followups_json(host : JsPiHost) -> String =
  #| (host) => {
  #|   const followUps = host.state.followUps.splice(0, host.state.followUps.length);
  #|   return JSON.stringify(followUps);
  #| }

///|
extern "js" fn JsToolResult::is_error(self : JsToolResult) -> Bool =
  #| (result) => result.isError === true

///|
extern "js" fn JsToolResult::content(self : JsToolResult) -> String =
  #| (result) => result.content ?? ""

///|
extern "js" fn JsToolResult::details_json(self : JsToolResult) -> String =
  #| (result) => result.detailsJson ?? "null"

///|
/// Current monotonic Pi tool catalog revision.
extern "js" fn js_catalog_revision(host : JsPiHost) -> Int =
  #| (host) => host.state.catalogVersion

///|
/// Cancel one effect and encode its canonical disposition as 0/1/2.
extern "js" fn js_cancel_effect_code(
  host : JsPiHost,
  effect_id : Int,
  reason_json : String,
) -> Int =
  #| (host, effectId, reasonJson) => {
  #|   const key = String(effectId);
  #|   const token = host.state.effects.get(key);
  #|   if (token) {
  #|     let reason = null;
  #|     try { reason = JSON.parse(reasonJson); } catch {}
  #|     token.controller.abort(reason);
  #|     return 0;
  #|   }
  #|   if (host.state.settledEffects.has(key)) return 2;
  #|   return 1;
  #| }

///|
/// Install a callback used to forward triggerTurn messages to RuntimeControl.
/// The callback returns "Accepted" when the message entered the active run's
/// follow-up queue; any other outcome parks the envelope in state.followUps.
extern "js" fn js_host_set_followup_callback(
  host : JsPiHost,
  callback : (String) -> String,
) -> Unit =
  #| (host, callback) => { host.state.followUpCallback = callback }

///|
/// Install the host UI callbacks consulted by makeContext.ui. Before this is
/// called (e.g. package loads, pre-composition events) the callbacks stay
/// absent and ctx.ui keeps no-op defaults with hasUI=false.
extern "js" fn js_host_set_ui_callbacks(
  host : JsPiHost,
  on_request : JsUiRequestFn,
  on_render : JsUiRenderFn,
) -> Unit =
  #| (host, onRequest, onRender) => {
  #|   host.state.uiOnRequest = onRequest;
  #|   host.state.uiOnRender = onRender;
  #| }

///|
/// Install the callback fired on every api.appendEntry: (customType,
/// dataJson). Hosts project these as observer Custom events at emission time.
extern "js" fn js_host_set_custom_entry_callback(
  host : JsPiHost,
  callback : (String, String) -> Unit,
) -> Unit =
  #| (host, callback) => { host.state.customEmit = callback }

///|
/// Mirror the hidden-tools set into the JS host so host-side live-state
/// readers (the <pi-tools> prompt-block serializer) apply the same base-wins
/// hiding as the MoonBit-side catalog filters. Written only by
/// pi_adaptor_set_hidden_tools_json, which keeps both copies in lockstep.
extern "js" fn js_host_set_hidden_tools(
  host : JsPiHost,
  names_json : String,
) -> Unit =
  #| (host, namesJson) => {
  #|   let names = [];
  #|   try { names = JSON.parse(namesJson) ?? []; } catch {}
  #|   host.state.hiddenTools = new Set(
  #|     Array.isArray(names) ? names.filter((item) => typeof item === "string") : [],
  #|   );
  #| }

///|
/// Drain custom entries appended since the last drain. Only api.appendEntry
/// feeds this queue — js_seed_entry restore never re-drains.
extern "js" fn js_take_custom_entries_json(host : JsPiHost) -> String =
  #| (host) => {
  #|   const entries = host.state.customEntries.splice(0, host.state.customEntries.length);
  #|   return JSON.stringify(entries);
  #| }
