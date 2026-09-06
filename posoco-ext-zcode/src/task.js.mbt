///|
/// js (bun) backend of the task seam. The whole session loop — Bun.spawn,
/// line-delimited JSON-RPC, reverse-request policy, event reduction,
/// teardown — lives in ONE JS driver (`zcode_js_session`). It
/// always resolves, never rejects: every failure is caught inside and
/// returned as a JSON-string envelope, per the documented js FFI boundary
/// (docs/questions.md 2026-08-19: pure-value pass-through, Promise bridging
/// via @js_async.Promise::wait, try/catch + JSON envelope for anything that
/// can throw). No cross-language streaming: JS does the protocol, MoonBit
/// assembles ZcodeTaskResult from the final envelope.

///|
/// Full session driver. Request JSON: {cmd, args, cwd, timeoutMs, workspace,
/// registry, task, sessionId|null, mode}. Result envelope:
/// {"ok":true,"result":{sessionId,title,finalText,stopReason,usage|null}} or
/// {"ok":false,"error":{kind: spawn_failed|rpc|model_config|protocol|timeout|
/// process_died, detail, code?, message?}}.
extern "js" fn zcode_js_session(
  request_json : String,
) -> @js_async.Promise[String] =
  #| async (requestJson) => {
  #|   const req = JSON.parse(requestJson);
  #|   const g = globalThis;
  #|   if (!g.__zcodeProcs) { g.__zcodeProcs = new Map(); }
  #|   if (!g.__zcodeSeq) { g.__zcodeSeq = 0; }
  #|   g.__zcodeSeq += 1;
  #|   const handle = "zcode-" + g.__zcodeSeq;
  #|   const deadline = Date.now() + (req.timeoutMs || 1800000);
  #|   const detail = (e) => String(e && e.message ? e.message : e);
  #|   // fail() is the single teardown gate: every error return passes through
  #|   // finish() so the app-server child can never keep the event loop alive.
  #|   // finish() is idempotent (proc nulled on first call), so double calls
  #|   // from the catch/finally paths create no second stdin.end or kill timer.
  #|   const fail = (kind, message, extra) => {
  #|     finish();
  #|     return JSON.stringify(Object.assign(
  #|       { ok: false, error: Object.assign({ kind, detail: message || "" }, extra || {}) }));
  #|   };
  #|   let proc = null;
  #|   let denial = null;
  #|   let sessionId = "";
  #|   let nextId = 0;
  #|   const finish = () => {
  #|     if (!proc) { return; }
  #|     const p = proc;
  #|     proc = null;
  #|     g.__zcodeProcs.delete(handle);
  #|     try { p.stdin.end(); } catch (e) {}
  #|     const t = setTimeout(() => { try { p.kill(); } catch (e) {} }, 5000);
  #|     if (t.unref) { t.unref(); }
  #|   };
  #|   try {
  #|     proc = Bun.spawn({
  #|       cmd: [req.cmd].concat(req.args),
  #|       stdin: "pipe",
  #|       stdout: "pipe",
  #|       stderr: "inherit",
  #|       ...(req.cwd ? { cwd: req.cwd } : {}),
  #|     });
  #|     g.__zcodeProcs.set(handle, proc);
  #|   } catch (e) {
  #|     return fail("spawn_failed", "zcode: cannot spawn app-server: " + detail(e));
  #|   }
  #|   let lineBuf = "";
  #|   const lineDec = new TextDecoder();
  #|   let lineReader = null;
  #|   async function readLine() {
  #|     for (;;) {
  #|       const at = lineBuf.indexOf("\n");
  #|       if (at >= 0) {
  #|         const line = lineBuf.slice(0, at);
  #|         lineBuf = lineBuf.slice(at + 1);
  #|         if (line.length > 0) { return line; }
  #|         continue;
  #|       }
  #|       if (!lineReader) { lineReader = proc.stdout.getReader(); }
  #|       const chunk = await lineReader.read();
  #|       if (chunk.done) {
  #|         const rest = lineBuf;
  #|         lineBuf = "";
  #|         if (rest.length > 0) { return rest; }
  #|         return "";
  #|       }
  #|       lineBuf += lineDec.decode(chunk.value, { stream: true });
  #|     }
  #|   }
  #|   function send(obj) { proc.stdin.write(JSON.stringify(obj) + "\n"); }
  #|   function denyOf(params) {
  #|     const options = (params && params.options) || [];
  #|     for (const option of options) {
  #|       const kind = (option && (option.kind || option.type)) || "";
  #|       if (kind.includes("deny") || kind.includes("reject") || kind.includes("Deny") || kind.includes("Reject")) {
  #|         const toolName = (params && params.toolName) || "";
  #|         const reason = (params && params.reason) || "";
  #|         return {
  #|           result: { optionId: (option && (option.optionId || option.id)) || "" },
  #|           summary: "zcode asked for permission for tool '" + toolName + "' (" + reason + ") and was denied by cetas",
  #|         };
  #|       }
  #|     }
  #|     return null;
  #|   }
  #|   function answer(msg) {
  #|     if (msg.method === undefined || msg.id === undefined) { return false; }
  #|     if (msg.method === "session/requestRuntimePreferences") {
  #|       send({ id: msg.id, result: { nativeSearchEnhancementsEnabled: false, memoryEnabled: false } });
  #|     } else if (msg.method === "interaction/requestOfficialMcpAuthHeaders") {
  #|       send({ id: msg.id, result: {} });
  #|     } else if (msg.method === "interaction/requestPermission") {
  #|       const denied = denyOf(msg.params);
  #|       if (denied) { denial = denied.summary; send({ id: msg.id, result: denied.result }); }
  #|       else { send({ id: msg.id, error: { code: -32600, message: "cetas: no deny option found in the permission request" } }); }
  #|     } else if (msg.method === "interaction/requestUserInput") {
  #|       send({ id: msg.id, error: { code: -32600, message: "cetas: user input not bridged" } });
  #|     } else {
  #|       send({ id: msg.id, error: { code: -32601, message: "Method not found" } });
  #|     }
  #|     return true;
  #|   }
  #|   const timeoutRej = (left) => {
  #|     const p = new Promise((_, rej) => {
  #|       const t = setTimeout(() => rej({ zkind: "timeout" }), Math.max(left, 0));
  #|       if (t.unref) { t.unref(); }
  #|     });
  #|     p.catch(() => {});
  #|     return p;
  #|   };
  #|   async function request(method_name, params) {
  #|     nextId += 1;
  #|     const id = nextId;
  #|     send({ id, method: method_name, params });
  #|     for (;;) {
  #|       const left = deadline - Date.now();
  #|       if (left <= 0) { throw { zkind: "timeout" }; }
  #|       const line = await Promise.race([readLine(), timeoutRej(left)]);
  #|       if (line === "") { throw { zkind: "died", zdetail: "zcode: connection closed before the response arrived" }; }
  #|       let msg = null;
  #|       try { msg = JSON.parse(line); } catch (e) { continue; }
  #|       if (answer(msg)) { continue; }
  #|       if (msg.id === id) { return msg; }
  #|     }
  #|   }
  #|   const turn = { buffer: "", title: "", response: "", usage: null, completedUsage: null, failedMessage: null, terminal: false, streamClosed: false };
  #|   function mergeParams(params) {
  #|     const p = params || {};
  #|     if (p.payload && typeof p.payload === "object" && !Array.isArray(p.payload)) {
  #|       return Object.assign({}, p.payload, p);
  #|     }
  #|     return p;
  #|   }
  #|   function reduce(p) {
  #|     switch (p.type) {
  #|       case "model.streaming":
  #|         if (p.kind === "text_delta" && typeof p.delta === "string") { turn.buffer += p.delta; }
  #|         break;
  #|       case "session.updated":
  #|         if (p.usage) { turn.usage = p.usage; }
  #|         break;
  #|       case "session.titleUpdated":
  #|         if (typeof p.title === "string") { turn.title = p.title; }
  #|         break;
  #|       case "turn.completed":
  #|         turn.response = typeof p.response === "string" ? p.response : "";
  #|         turn.completedUsage = p.usage || null;
  #|         turn.terminal = true;
  #|         break;
  #|       case "turn.failed":
  #|         turn.failedMessage = p.error && typeof p.error.message === "string" ? p.error.message : "";
  #|         turn.terminal = true;
  #|         break;
  #|       default:
  #|         break;
  #|     }
  #|   }
  #|   const rpcFail = (error) => fail("rpc", error && error.message ? error.message : "", { code: (error && error.code) || 0, message: (error && error.message) || "" });
  #|   try {
  #|     let replyMsg = await request("workspace/updateProviderRegistry", { workspace: req.workspace, registry: req.registry });
  #|     if (replyMsg.error) {
  #|       const message = replyMsg.error.message || "";
  #|       if (message.includes("Model config is missing")) {
  #|         return fail("model_config", message + " (rpc code " + (replyMsg.error.code || 0) + ")");
  #|       }
  #|       return rpcFail(replyMsg.error);
  #|     }
  #|     if (req.sessionId) {
  #|       replyMsg = await request("session/resume", { sessionId: req.sessionId });
  #|       if (replyMsg.error) { return rpcFail(replyMsg.error); }
  #|       const r = replyMsg.result || {};
  #|       sessionId = (r.session && r.session.sessionId) || req.sessionId;
  #|     } else {
  #|       replyMsg = await request("session/create", { workspace: req.workspace, mode: req.mode });
  #|       if (replyMsg.error) { return rpcFail(replyMsg.error); }
  #|       const r = replyMsg.result || {};
  #|       sessionId = (r.session && r.session.sessionId) || "";
  #|       if (!sessionId) { return fail("protocol", "session/create response has no session.sessionId"); }
  #|     }
  #|     replyMsg = await request("session/subscribe", { sessionId, deliveryKind: "desktop-continuous", includeSnapshot: true, afterSeq: 0 });
  #|     if (replyMsg.error) { return rpcFail(replyMsg.error); }
  #|     replyMsg = await request("session/send", { sessionId, content: req.task });
  #|     if (replyMsg.error) { return rpcFail(replyMsg.error); }
  #|     if (!(replyMsg.result && replyMsg.result.accepted === true)) {
  #|       return fail("protocol", "session/send was not accepted");
  #|     }
  #|     while (!turn.terminal) {
  #|       const left = deadline - Date.now();
  #|       if (left <= 0) { throw { zkind: "timeout" }; }
  #|       const line = await Promise.race([readLine(), timeoutRej(left)]);
  #|       if (line === "") { turn.streamClosed = true; break; }
  #|       let msg = null;
  #|       try { msg = JSON.parse(line); } catch (e) { continue; }
  #|       if (answer(msg)) { continue; }
  #|       if (msg.method === "session/event") { reduce(mergeParams(msg.params)); }
  #|     }
  #|   } catch (e) {
  #|     finish();
  #|     if (e && e.zkind === "timeout") { return fail("timeout", "zcode: delegation exceeded the wall clock"); }
  #|     if (e && e.zkind === "died") { return fail("process_died", e.zdetail || ""); }
  #|     return fail("process_died", detail(e));
  #|   }
  #|   finish();
  #|   if (!turn.terminal) {
  #|     if (turn.streamClosed) {
  #|       return fail("process_died", "zcode app-server exited before the turn reached a terminal event");
  #|     }
  #|     return fail("timeout", "zcode: delegation exceeded the wall clock");
  #|   }
  #|   let finalText = turn.response !== "" ? turn.response : turn.buffer;
  #|   let stop = "success";
  #|   if (turn.failedMessage !== null) {
  #|     stop = "failed";
  #|     if (turn.failedMessage !== "") { finalText = turn.failedMessage; }
  #|     else if (finalText === "") { finalText = "zcode turn failed without an error message"; }
  #|   }
  #|   if (denial) {
  #|     stop = "permission_denied";
  #|     finalText = finalText + "\n\n" + denial;
  #|   }
  #|   const usage = turn.completedUsage || turn.usage;
  #|   return JSON.stringify({
  #|     ok: true,
  #|     result: {
  #|       sessionId,
  #|       title: turn.title,
  #|       finalText,
  #|       stopReason: stop,
  #|       usage: usage ? {
  #|         inputTokens: usage.inputTokens || 0,
  #|         outputTokens: usage.outputTokens || 0,
  #|         totalTokens: usage.totalTokens || 0,
  #|       } : null,
  #|     },
  #|   });
  #| }

///|
/// js env lookup: `process.env[name] ?? ""` pure pass-through; blank and
/// missing collapse to None.
extern "js" fn zcode_js_env_raw(name : String) -> String =
  #| (name) => process.env[name] ?? ""

///|
fn zcode_js_env_opt(key : String) -> String? {
  let raw = zcode_js_env_raw(key)
  if raw == "" {
    None
  } else {
    Some(raw)
  }
}

///|
/// `Bun.file(path).exists()` — Promise<bool>, false for missing paths.
extern "js" fn zcode_js_exists(path : String) -> @js_async.Promise[Bool] =
  #| (path) => Bun.file(path).exists()

///|
/// `Bun.file(path).text()` — Promise<String>, rejects when unreadable; the
/// rejection becomes ZcodeCredsUnreadable at the call site.
extern "js" fn zcode_js_file_text(path : String) -> @js_async.Promise[String] =
  #| (path) => Bun.file(path).text()

///|
/// `fs.realpathSync` with a "" failure sentinel; the caller degrades to "."
/// exactly like the native `@fs.realpath` catch.
extern "js" fn zcode_js_realpath(path : String) -> String =
  #| (path) => { try { return require("node:fs").realpathSync(path); } catch (e) { return ""; } }

///|
/// Default cwd for the tool seam: the real current directory.
fn zcode_cwd_default() -> String {
  let real = zcode_js_realpath(".")
  if real == "" {
    "."
  } else {
    real
  }
}

///|
/// js `zcode_resolve_command_io`: same candidate list and cache shape as the
/// native pre-probe, with Bun.file.exists as the async probe.
async fn zcode_resolve_command_io(
  config~ : ZcodeConfig,
) -> (String, Array[String]) raise ZcodeError {
  let probed : Map[String, Bool] = Map::from_array([])
  for candidate in zcode_probe_candidates(env=zcode_js_env_opt) {
    probed[candidate] = zcode_js_exists(candidate).wait() catch { _ => false }
  }
  match
    zcode_resolve_command(config~, env=zcode_js_env_opt, exists=path => {
      probed.get(path).unwrap_or(false)
    }) {
    Ok(pair) => pair
    Err(e) => raise e
  }
}

///|
/// Read the v2 credentials and build the provider registry payload.
async fn zcode_registry_io(config~ : ZcodeConfig) -> Json raise ZcodeError {
  let path = zcode_creds_path(config~, env=zcode_js_env_opt)
  let text = zcode_js_file_text(path).wait() catch {
    e => raise ZcodeCredsUnreadable(detail="cannot read \{path}: \{e}")
  }
  let v2 = @json.parse(text) catch {
    e => raise ZcodeCredsUnreadable(detail="cannot parse \{path}: \{e}")
  }
  match zcode_build_registry(v2, generated_at_ms=@async.now()) {
    Ok(registry) => registry
    Err(message) => raise ZcodeCredsUnreadable(detail=message)
  }
}

///|
fn zcode_js_usage_of(result : Json) -> ZcodeUsage? {
  match json_field(result, "usage") {
    Some(u) =>
      Some({
        input_tokens: json_field_int(u, "inputTokens"),
        output_tokens: json_field_int(u, "outputTokens"),
        total_tokens: json_field_int(u, "totalTokens"),
      })
    None => None
  }
}

///|
/// js session driver: hand the prebuilt request to the JS driver and map the
/// result/error envelope back onto ZcodeTaskResult / ZcodeError.
async fn zcode_session_run(
  cmd : (String, Array[String]),
  registry : Json,
  config~ : ZcodeConfig,
  task~ : String,
  cwd~ : String,
  session_id~ : String?,
  mode~ : String,
) -> ZcodeTaskResult raise Error {
  let workspace = Json::object(
    Map::from_array([
      ("workspacePath", Json::string(cwd)),
      ("workspaceKey", Json::string(cwd)),
    ]),
  )
  let request = Json::object(
    Map::from_array([
      ("cmd", Json::string(cmd.0)),
      ("args", Json::array(cmd.1.map(fn(a) { Json::string(a) }))),
      ("cwd", Json::string(cwd)),
      ("timeoutMs", Json::number(config.timeout_ms.to_double())),
      ("workspace", workspace),
      ("registry", registry),
      ("task", Json::string(task)),
      (
        "sessionId",
        match session_id {
          Some(s) => Json::string(s)
          None => Json::null()
        },
      ),
      ("mode", Json::string(mode)),
    ]),
  )
  let raw = zcode_js_session(request.stringify()).wait() catch {
    e => raise ZcodeProcessDied(detail="zcode js driver failed: \{e}")
  }
  let envelope = @json.parse(raw) catch {
    _ =>
      raise ZcodeProcessDied(
        detail="zcode js driver returned a non-JSON envelope",
      )
  }
  if json_field(envelope, "ok") is Some(Json::True) {
    let result = json_field(envelope, "result").unwrap_or(Json::null())
    {
      session_id: json_field_string(result, "sessionId").unwrap_or(""),
      title: json_field_string(result, "title").unwrap_or(""),
      final_text: json_field_string(result, "finalText").unwrap_or(""),
      stop_reason: json_field_string(result, "stopReason").unwrap_or("failed"),
      usage: zcode_js_usage_of(result),
    }
  } else {
    let error = json_field(envelope, "error").unwrap_or(Json::null())
    let detail = json_field_string(error, "detail").unwrap_or("")
    match json_field_string(error, "kind").unwrap_or("") {
      "spawn_failed" => raise ZcodeSpawnFailed(detail~)
      "rpc" =>
        raise ZcodeRpc(
          code=json_field_int(error, "code"),
          message=json_field_string(error, "message").unwrap_or(""),
        )
      "model_config" => raise ZcodeModelConfig(detail~)
      "protocol" => raise ZcodeProtocol(detail~)
      "timeout" => raise ZcodeTimeout
      _ => raise ZcodeProcessDied(detail~)
    }
  }
}
