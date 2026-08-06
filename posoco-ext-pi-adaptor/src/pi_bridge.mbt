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
  #|     shortcuts: [],
  #|     commands: [],
  #|     messageRenderers: [],
  #|     toolRenderers: [],
  #|     inflight: new Map(),
  #|     effects: new Map(),
  #|     settledEffects: new Set(),
  #|     followUpCallback: null,
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
  #|   const makeContext = () => ({
  #|     cwd: state.cwd,
  #|     hasUI: false,
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
  #|       notify() {},
  #|       setStatus() {},
  #|       setWidget() {},
  #|       async input() { return undefined; },
  #|       async confirm() { return false; },
  #|       async select() { return undefined; },
  #|     },
  #|   });
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
  #|   const api = {
  #|     registerTool,
  #|     on,
  #|     appendEntry(customType, data) {
  #|       state.entries.push({ type: "custom", customType, data });
  #|     },
  #|     sendMessage(message, options = {}) {
  #|       const envelope = { message, options };
  #|       state.messages.push(envelope);
  #|       if (options?.triggerTurn === true) {
  #|         if (typeof state.followUpCallback === "function") {
  #|           state.followUpCallback(JSON.stringify(envelope));
  #|         } else {
  #|           state.followUps.push(envelope);
  #|         }
  #|       }
  #|     },
  #|     registerCommand(name, command) {
  #|       state.commands.push({ name, description: command?.description ?? "" });
  #|     },
  #|     registerShortcut(key, shortcut) {
  #|       state.shortcuts.push({ key, description: shortcut?.description ?? "" });
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
  #|     const onUpdate = (update) => state.updates.push({ effectId, callId, name, update });
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
  #|   return { state, api, makeContext, executeAsync, normalizePiResult, errorResult, renderContent };
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
  #|   const onUpdate = (update) => host.state.updates.push({ effectId: null, callId, name, update });
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
/// Attach MoonBit continuations to a JavaScript Promise resolving to String.
extern "js" fn JsPromise::attach_string(
  self : JsPromise,
  on_ok : (String) -> Unit,
  on_error : (String) -> Unit,
) -> Unit =
  #| (self, onOk, onError) => self.then(
  #|   value => onOk(String(value)),
  #|   error => onError(error instanceof Error ? error.message : String(error)),
  #| )

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
extern "js" fn js_host_set_followup_callback(
  host : JsPiHost,
  callback : (String) -> Unit,
) -> Unit =
  #| (host, callback) => { host.state.followUpCallback = callback }
