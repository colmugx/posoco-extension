///|
/// ToolProvider for MbtxTools, shared by every execution target (native,
/// wasm, js): the real `mbtx` listing plus the two-stage execution pipeline —
/// BUILD via `moon run --build-only`, RUN via `moonrun --policy`. The
/// target-specific edges live in `posoco_ext_mbtx.native.mbt` (@process/@fs
/// on native and wasm) and `posoco_ext_mbtx.js.mbt` (Bun forwarding), behind
/// the `Runner` trait and the `mbtx_call_tmpdir` / `mbtx_write_file` /
/// `mbtx_cleanup_tmpdir` / `mbtx_realpath` file seams.

///|
/// Package-local budget-expiry marker. The js Runner enforces the stage
/// budget extern-side (timer + kill) and must tell `timed_stage` "this was
/// the budget" — but the async library's `TimeoutError` is a read-only
/// suberror, constructible only by the library itself, and a priv suberror
/// only participates in `is` patterns within its own file. This carrier is
/// classified exactly like a TimeoutError/cancellation: the child is
/// already dead either way.
#warnings("-unused_constructor")
priv suberror MbtxBudgetExpired {
  Expired
}

///|
/// Wall-clock budget for the BUILD stage (a single-file compile; anything
/// past 10s is treated as a stuck toolchain, not a slow program).
let mbtx_build_timeout_ms : Int = 10_000

///|
/// Cap on model-visible RUN output (and BUILD diagnostics): 64KB, tail kept.
let mbtx_max_output_chars : Int = 65536

///|
#cfg(any(target="native", target="wasm", target="js"))
pub impl @posoco.ToolProvider for MbtxTools with fn list_tools(self : MbtxTools) -> Array[
  @posoco.ToolDef,
] {
  [self.tool_def()]
}

///|
#cfg(any(target="native", target="wasm", target="js"))
pub impl @posoco.ToolProvider for MbtxTools with fn execute(
  self : MbtxTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  // Decode errors surface first so argument feedback keeps working.
  let args = self.decode_args(call.arguments)
  self.execute_pipeline(args)
}

///|
/// Ensure the toolchain, create the call's one-shot temp dir, run the
/// pipeline inside it, and always clean the dir up (best effort).
#warnings("-unused_value")
async fn MbtxTools::execute_pipeline(
  self : MbtxTools,
  args : MbtxArgs,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let tc = self.ensure_toolchain()
  let tmpdir = mbtx_call_tmpdir() catch {
    err =>
      raise @posoco.RuntimeError::InvocationFailed(
        "mbtx: could not create the call temp dir: \{err.to_string()}",
      )
  }
  // The temp dir must be cleaned on every path: business errors are
  // returned (never raised) by the pipeline, so only real raises skip it.
  let settled : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    self.run_in_tmpdir(tmpdir~, args~, tc~),
  ) catch {
    e => Err(e)
  }
  mbtx_cleanup_tmpdir(tmpdir)
  match settled {
    Ok(outcome) => outcome
    Err(e) => raise e
  }
}

///|
/// The per-call pipeline inside the call's temp directory: write
/// snippet + policy, BUILD, RUN. Business-level exits (compile failure,
/// timeout, non-zero run, undecodable output) are returned as
/// `ToolReportedError`; raises are reserved for infrastructure failures
/// (missing toolchain, unwritable temp dir, failed spawn).
async fn MbtxTools::run_in_tmpdir(
  self : MbtxTools,
  tmpdir~ : String,
  args~ : MbtxArgs,
  tc~ : ResolvedToolchain,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let snippet_path = "\{tmpdir}/snippet.mbtx"
  let policy_path = "\{tmpdir}/policy.json"
  mbtx_write_file(snippet_path, args.source)
  mbtx_write_file(
    policy_path,
    build_policy(rules=self.allowlist, write_roots=[tmpdir]).stringify(),
  )
  // BUILD — compile only; `moon` never executes the snippet.
  let build_args = [
    "run",
    snippet_path,
    "--build-only",
    "--target",
    args.target,
    "--target-dir",
    "\{tmpdir}/build",
  ]
  let build = self.timed_stage(
    mbtx_build_timeout_ms,
    tc.moon,
    build_args,
    None,
    timeout_content="mbtx: BUILD timed out after 10s",
  )
  let (build_exit, build_text, build_decoded) = match build {
    Ok(triple) => triple
    Err(content) =>
      return @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  }
  if build_exit != 0 || !build_decoded {
    let diagnostics = if build_decoded {
      rewrite_tmp_paths(build_text, tmpdir~)
    } else {
      "mbtx: build output was not valid UTF-8"
    }
    return @posoco.ToolOutcome::ToolReportedError(
      content=truncate_output(
        "mbtx: BUILD failed (exit \{build_exit})\n\{diagnostics}",
      ),
      structured=None,
    )
  }
  let artifact = match parse_artifacts_path(build_text) {
    Some(path) => path
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="mbtx: BUILD succeeded but printed no artifacts_path JSON line\n" +
          truncate_output(rewrite_tmp_paths(build_text, tmpdir~)),
        structured=None,
      )
  }
  // RUN — the artifact under moonrun; escalated calls drop --policy (the
  // extension executes faithfully; the approval gate owns the decision).
  let run_args = if args.escalated {
    [artifact]
  } else {
    [artifact, "--policy", policy_path]
  }
  let run_cwd : String? = match self.anchor {
    Some(anchor) => Some(anchor.root)
    None => None
  }
  let run = self.timed_stage(
    self.run_timeout_ms,
    tc.moonrun,
    run_args,
    run_cwd,
    timeout_content="mbtx: RUN timed out after \{self.run_timeout_ms}ms",
  )
  let (run_exit, run_text, run_decoded) = match run {
    Ok(triple) => triple
    Err(content) =>
      return @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  }
  let mut decode_failed = false
  let content = if run_decoded {
    run_text
  } else {
    decode_failed = true
    "mbtx: decode failed (stage=decode_output, category=invalid_utf8, exit_code=\{run_exit})"
  }
  let content = truncate_output(content)
  if run_exit != 0 || decode_failed {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  } else {
    @posoco.ToolOutcome::Success(content~, structured=None)
  }
}

///|
/// One timed pipeline stage: run argv under a wall-clock budget. The budget
/// expiry surfaces as `Err(timeout_content)` (the caller turns it into a
/// `ToolReportedError`); the timeout kills the child — via the timing
/// layer's cancellation on native/wasm, via the runner's extern-side timer
/// on js. Note: an externally aborted turn cancels the same way and is
/// classified as a timeout too — acceptable, since the child is killed and
/// the call reports an error either way.
async fn MbtxTools::timed_stage(
  self : MbtxTools,
  budget_ms : Int,
  cmd : String,
  args : Array[String],
  cwd : String?,
  timeout_content~ : String,
) -> Result[(Int, String, Bool), String] raise @posoco.RuntimeError {
  let settled : Result[(Int, String, Bool), Error] = Ok(
    @async.with_timeout(budget_ms, () => {
      self.runner.run(cmd, args, cwd, budget_ms)
    }),
  ) catch {
    e => Err(e)
  }
  match settled {
    Ok(triple) => Ok(triple)
    Err(err) =>
      // Budget expiry surfaces either as the injected TimeoutError or as
      // the Cancelled of the collection task being torn down — or, on js,
      // as the runner's extern-side budget marker (the js layer cannot
      // construct the library's TimeoutError; see `MbtxBudgetExpired`).
      if err is @async.TimeoutError ||
        @async.is_cancellation_error(err) ||
        err is MbtxBudgetExpired::Expired {
        Err(timeout_content)
      } else {
        raise @posoco.RuntimeError::InvocationFailed(
          "mbtx: stage process '\{cmd}' failed: \{err.to_string()}",
        )
      }
  }
}

///|
/// Rewrite the temp snippet path (and the bare temp dir, including its
/// macOS `/private` realpath face) in BUILD diagnostics back to
/// "snippet.mbtx" so the model reads a diagnosis about its own program, not
/// our filesystem layout. (Explicit error type: async fns default to the
/// generic `Error`, which the RuntimeError-raising caller rejects.)
#warnings("-unused_error_type")
async fn rewrite_tmp_paths(
  text : String,
  tmpdir~ : String,
) -> String raise @posoco.RuntimeError {
  let mut out = text
  for dir in [tmpdir, mbtx_realpath(tmpdir) catch { _ => tmpdir }] {
    out = out.replace_all(old="\{dir}/snippet.mbtx", new="snippet.mbtx")
    out = out.replace_all(old=dir, new=".")
  }
  out
}

///|
/// Extract the first `artifacts_path` entry from BUILD stdout (moon prints
/// one `{"artifacts_path":[...]}` JSON line among possible other output).
fn parse_artifacts_path(stdout : String) -> String? {
  for line in stdout.split("\n") {
    let parsed = @json.parse(line.to_owned()) catch { _ => continue }
    match parsed {
      Json::Object(map) =>
        if map.contains("artifacts_path") {
          match map["artifacts_path"] {
            Json::Array(items) =>
              if items.length() > 0 {
                match items[0] {
                  Json::String(s) => return Some(s)
                  _ => ()
                }
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  None
}

///|
/// Cap output at 64KB: keep the tail (errors land at the end of long
/// build/run logs) and prepend one truncation notice line.
fn truncate_output(content : String) -> String {
  if content.length() <= mbtx_max_output_chars {
    return content
  }
  let total = content.length()
  let tail = content[total - mbtx_max_output_chars:].to_owned()
  "\n[mbtx: output truncated; showing the last \{mbtx_max_output_chars} of \{total} characters]\n" +
  tail
}

///|
/// The single `mbtx` ToolDef. Shared construction keeps the schema,
/// description and owner/policy/provenance in one place.
#warnings("-unused_value")
fn MbtxTools::tool_def(self : MbtxTools) -> @posoco.ToolDef {
  // OpenAI/DeepSeek tool schema requires `parameters` to be a JSON Schema
  // with `type: "object"`; strict servers otherwise reject with HTTP 400.
  let properties : Array[(String, Json)] = [
    (
      "source",
      Json::object(
        Map::from_array([
          ("type", Json::string("string")),
          (
            "description",
            Json::string(
              "Full single-file MoonBit (.mbtx) program source to compile and run",
            ),
          ),
        ]),
      ),
    ),
    (
      "target",
      Json::object(
        Map::from_array([
          ("type", Json::string("string")),
          ("enum", Json::array(mbtx_valid_targets.map(Json::string))),
          ("description", Json::string("Build target; defaults to wasm")),
        ]),
      ),
    ),
  ]
  if self.escalation {
    properties.push(
      (
        "escalated",
        Json::object(
          Map::from_array([
            ("type", Json::string("boolean")),
            (
              "description",
              Json::string(
                "Run this one call without the sandbox policy; requires per-call approval and is never session-approved",
              ),
            ),
          ]),
        ),
      ),
    )
  }
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(Map::from_array(properties))),
      ("required", Json::array([Json::string("source")])),
    ]),
  )
  {
    name: @posoco.ToolName::unchecked("mbtx"),
    description: self.description(),
    input_schema: schema,
    owner: @posoco.OwnerId::unchecked("posoco_ext_mbtx"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_mbtx"),
  }
}

///|
/// Tool description: shell-free charter, the effective allowlist table with
/// argument constraints, the excluded face, coreutils substitutions, the
/// write boundary, and target semantics. Built only from constructor state,
/// so it is stable for the agent's lifetime.
fn MbtxTools::description(self : MbtxTools) -> String {
  "Run one task as a single-file MoonBit (.mbtx) program — there is no shell. The source is compiled and run under a moonrun policy sandbox; subprocesses spawn as literal argv (no string command line to parse). Allowed subprocess programs (deny-by-default allowlist):\n" +
  allowlist_table(self.allowlist) +
  "Everything else is denied — including any shell or interpreter (sh, bash, zsh, fish, python, node, deno), xargs, and curl/wget piping. The allowlist is not a security perimeter; it buys the long tail. File writes are restricted to this call's temporary directory — to change workspace files, use the write/edit tools instead. Prefer MoonBit over coreutils:\n" +
  coreutils_substitutions +
  "target defaults to wasm (the only policy-constrained backend family); native is not available."
}
