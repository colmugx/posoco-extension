///|
/// Runner seam: one subprocess invocation, `(exit_code, decoded_output,
/// decoded_ok)` — `decoded_ok=false` marks output that could not be decoded
/// as UTF-8 (it must not masquerade as empty success). The raise type is
/// the generic `Error` on purpose: task cancellation (the timing layer's
/// budget expiry) must reach the timing layer unconverted, or it would be
/// mistaken for a spawn failure. `budget_ms` is the stage's wall-clock
/// budget: the native/wasm runner ignores it (timing is owned by the
/// `@async.with_timeout` layer, whose cancellation kills the child), while
/// the js runner enforces it in the extern layer (spawn-side timer + kill).
priv trait Runner {
  async fn run(
    self : Self,
    cmd : String,
    args : Array[String],
    cwd : String?,
    budget_ms : Int,
  ) -> (Int, String, Bool)
}

///|
/// MbtxTools — the MoonBit script tool provider (tools: `mbtx` and `cmd`).
///
/// `mbtx` submits a single-file MoonBit (`.mbtx`) program; the extension
/// compiles it (`moon run --build-only`) and runs the artifact under
/// `moonrun --policy`. `cmd` runs one allowlisted program as literal argv
/// straight through the Runner (no compile, no policy). There is no shell:
/// subprocesses spawn as literal argv constrained by a program allowlist,
/// and `mbtx` file writes are confined to the call's temp directory.
///
/// On native and wasm the pipeline runs through `@process`/`@fs`; on js it
/// forwards to the Bun runtime (Bun.spawn argv + node:fs sync IO —
/// `posoco_ext_mbtx.js.mbt`). Both faces share the two-stage pipeline.
#warnings("-unused_field")
pub struct MbtxTools {
  /// Working directory anchor for the run stage (same semantics as the
  /// bash extension); None inherits the host process cwd.
  anchor : @devkit.WorkspaceAnchor?
  /// Effective subprocess allowlist: `default_allowlist` minus
  /// `allowlist_without` (by program name) plus `allowlist_extra`.
  allowlist : Array[SpawnRule]
  /// Wall-clock budget for the run stage; default 120s.
  run_timeout_ms : Int
  /// When true, the `escalated` argument is accepted (runs the call once
  /// without the sandbox policy; gated per-call by the approval layer).
  escalation : Bool
  /// Explicit toolchain bin directory override (resolution order:
  /// toolchain_bin -> PATH -> ~/.moon/bin).
  toolchain_bin : String?
  /// When set, the constructor publishes the `tool_exemptions` self-report.
  bus : @devkit.EventBus?
  /// Resolved toolchain cache: the bin_dir of the first usable candidate,
  /// set once by the execution edge (`ensure_toolchain`). Deriving
  /// `moon`/`moonrun` paths from it is pure string joins.
  mut resolved : String?
  /// Subprocess seam for the execution pipeline; the canonical constructor
  /// installs the real runner for this target (`@process` on native/wasm,
  /// Bun forwarding on js; tests may inject a fake).
  priv runner : &Runner
}

///|
/// One `process.allow` entry of the moonrun policy. An empty `args_prefix`
/// means the program may run with any arguments.
pub(all) struct SpawnRule {
  program : String
  args_prefix : Array[String]
}

///|
/// Default subprocess allowlist (design §5). Every entry allows any
/// arguments; the excluded face is everything else — notably any shell or
/// interpreter (sh, bash, zsh, fish, python, node, deno), xargs, and
/// curl/wget piping. This is not a security perimeter: spawned children get
/// host ambient permissions — it buys the long tail of accidental damage,
/// and gives the model a legible, code-reviewable command vocabulary.
let default_allowlist : Array[SpawnRule] = [
  { program: "moon", args_prefix: [], },
  { program: "git", args_prefix: [], },
  { program: "gh", args_prefix: [], },
  { program: "rg", args_prefix: [], },
  { program: "diff", args_prefix: [], },
]

///|
/// Canonical constructor. Use this everywhere.
pub fn MbtxTools::MbtxTools(
  anchor? : @devkit.WorkspaceAnchor? = None,
  allowlist_extra? : Array[SpawnRule] = [],
  allowlist_without? : Array[String] = [],
  run_timeout_ms? : Int = 120_000,
  escalation? : Bool = false,
  toolchain_bin? : String? = None,
  bus? : @devkit.EventBus? = None,
) -> MbtxTools {
  let tools = MbtxTools::{
    anchor,
    allowlist: effective_allowlist(
      without=allowlist_without,
      extra=allowlist_extra,
    ),
    run_timeout_ms,
    escalation,
    toolchain_bin,
    bus,
    resolved: None,
    runner: mbtx_default_runner(),
  }
  match bus {
    Some(bus) => publish_tool_exemptions(bus, tools=["mbtx"])
    None => ()
  }
  tools
}

///|
/// Package-internal composition seam (white-box tests): the canonical field
/// layout with an injected Runner. Not public API — hosts always get the
/// real process runner from `MbtxTools`.
#warnings("-unused_value")
fn MbtxTools::with_runner(
  runner~ : &Runner,
  anchor? : @devkit.WorkspaceAnchor? = None,
  run_timeout_ms? : Int = 120_000,
  escalation? : Bool = false,
  allowlist_extra? : Array[SpawnRule] = [],
  allowlist_without? : Array[String] = [],
) -> MbtxTools {
  {
    anchor,
    allowlist: effective_allowlist(
      without=allowlist_without,
      extra=allowlist_extra,
    ),
    run_timeout_ms,
    escalation,
    toolchain_bin: None,
    bus: None,
    resolved: None,
    runner,
  }
}

///|
/// Default allowlist minus `without` (matched on program name), then
/// `extra` appended (duplicates are harmless).
fn effective_allowlist(
  without~ : Array[String],
  extra~ : Array[SpawnRule],
) -> Array[SpawnRule] {
  let rules : Array[SpawnRule] = []
  for rule in default_allowlist {
    if !without.contains(rule.program) {
      rules.push(rule)
    }
  }
  for rule in extra {
    rules.push(rule)
  }
  rules
}

///|
/// The `tool_exemptions` topic this extension self-reports on (convention
/// shared with posoco-ext-plan / posoco-ext-permission; a trust channel for
/// approval gates, not a security boundary). The sandboxed `mbtx` call
/// carries its own governance via the moonrun policy; escalated calls are
/// gated per-call by the permission layer, not exempted here.
let tool_exemptions_topic : String = "tool_exemptions"

///|
/// Publish one exemption report: `tools` are the exact tool names that
/// subscribing approval gates let bypass their checks.
fn publish_tool_exemptions(
  bus : @devkit.EventBus,
  tools~ : Array[String],
) -> Unit {
  bus.publish({
    source: "posoco_ext_mbtx",
    topic: tool_exemptions_topic,
    data: Json::object({ "tools": Json::array(tools.map(Json::string)) }),
  })
}

///|
let mbtx_valid_targets : Array[String] = ["wasm", "wasm-gc", "js", "llvm"]

///|
/// Decoded `mbtx` call arguments, consumed by the execution pipeline.
#warnings("-unused_field")
priv struct MbtxArgs {
  source : String
  target : String
  escalated : Bool
}

///|
/// Decode and validate one `mbtx` call's arguments. Missing or mistyped
/// fields are typed errors (never silent fallbacks): `source` is required
/// and must be a non-empty string; `target` defaults to "wasm" and rejects
/// "native" (the moonrun policy can only bind wasm-family backends);
/// `escalated: true` is only legal when the extension was constructed with
/// `escalation=true`.
#warnings("-unused_value")
fn MbtxTools::decode_args(
  self : MbtxTools,
  args : Json,
) -> MbtxArgs raise @posoco.RuntimeError {
  let map = match args {
    Json::Object(map) => map
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "mbtx: arguments must be a JSON object",
      )
  }
  let source = if map.contains("source") {
    match map["source"] {
      Json::String(s) =>
        if s.length() == 0 {
          raise @posoco.RuntimeError::UnknownTool(
            "mbtx: 'source' must be a non-empty string",
          )
        } else {
          s
        }
      _ =>
        raise @posoco.RuntimeError::UnknownTool(
          "mbtx: 'source' must be a string",
        )
    }
  } else {
    raise @posoco.RuntimeError::UnknownTool("mbtx: missing 'source' argument")
  }
  let target = if map.contains("target") {
    match map["target"] {
      Json::String(t) =>
        if mbtx_valid_targets.contains(t) {
          t
        } else if t == "native" {
          raise @posoco.RuntimeError::UnknownTool(
            "mbtx: target \"native\" is not supported: the moonrun policy sandbox can only bind wasm-family backends (wasm, wasm-gc, js, llvm)",
          )
        } else {
          raise @posoco.RuntimeError::UnknownTool(
            "mbtx: 'target' must be one of wasm, wasm-gc, js, llvm",
          )
        }
      _ =>
        raise @posoco.RuntimeError::UnknownTool(
          "mbtx: 'target' must be a string",
        )
    }
  } else {
    "wasm"
  }
  let escalated = if map.contains("escalated") {
    match map["escalated"] {
      Json::True =>
        if !self.escalation {
          raise @posoco.RuntimeError::UnknownTool(
            "mbtx: 'escalated' is not available: this agent's mbtx tool was not configured with escalation enabled",
          )
        } else {
          true
        }
      Json::False => false
      _ =>
        raise @posoco.RuntimeError::UnknownTool(
          "mbtx: 'escalated' must be a boolean",
        )
    }
  } else {
    false
  }
  { source, target, escalated, }
}

///|
/// Coreutils -> MoonBit substitutions every mbtx script should prefer.
let coreutils_substitutions : String = "- ls -> @fs.readdir(path)\n" +
  "- find -> @shell.glob(pattern)\n" +
  "- grep -> MoonBit core regex matching\n" +
  "- pipes / loops / glue -> MoonBit itself (write the composition as code)\n"

///|
/// Render the effective allowlist as a "- program — constraint" table,
/// shared by the tool description and the system prompt (the whitelist must
/// appear in both or it protects nothing).
fn allowlist_table(rules : Array[SpawnRule]) -> String {
  let buf = StringBuilder()
  for rule in rules {
    if rule.args_prefix.length() == 0 {
      buf.write_string("- \{rule.program} — any arguments\n")
    } else {
      buf.write_string(
        "- \{rule.program} — only when arguments start with: \{rule.args_prefix.join(" ")}\n",
      )
    }
  }
  buf.to_string()
}

///|
/// Execution-edge cache write: record the resolved toolchain bin_dir once
/// the probe succeeds. A universal method so the cache field participates on
/// every target (the field itself is only mutated from the execution edge).
#warnings("-unused_value")
fn MbtxTools::cache_resolved(self : MbtxTools, bin_dir : String) -> Unit {
  self.resolved = Some(bin_dir)
}

///|
/// Per-target import keepers: `@fs` and `@process` back the execution edge
/// on native and wasm (`posoco_ext_mbtx.native.mbt`) and are referenced by
/// no other target's code (the js face is an `unimplemented` stub; backends
/// beyond the three execution targets have no execution edge at all), so
/// everywhere except native/wasm the build would trip `unused_package`
/// without these. `@js_async` backs the bun runner (js only), hence the
/// mirrored keeper.
#cfg(not(any(target="native", target="wasm")))
let _fs_import_keeper : Unit = ignore(@fs.unimplemented)

///|
#cfg(not(any(target="native", target="wasm")))
let _process_import_keeper : Unit = ignore(@process.unimplemented)

///|
#cfg(target="js")
let _env_import_keeper : Unit = ignore(@env.get_env_var)

///|
#cfg(not(target="js"))
// The reference intentionally targets the native js_async stub, whose
// unimplemented alert is noise for a value that is never evaluated.
#warnings("-alert_unimplemented")
let _js_async_import_keeper : Unit = ignore(@js_async.AbortController::new)
