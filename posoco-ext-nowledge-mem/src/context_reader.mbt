///|
/// Total startup-context budget shared by every read attempt (upstream
/// STARTUP_CONTEXT_BUDGET_MS = 8_000).
const NMEM_STARTUP_BUDGET_MS : Int = 8000

///|
/// Cap on one startup context bundle (upstream MAX_CONTEXT_CHARS = 20_000).
const NMEM_MAX_CONTEXT_CHARS : Int = 20000

///|
/// Truncation tail note appended when a bundle exceeds the cap (host label
/// derived from `source_app`).
fn context_truncation_note(source_app : String) -> String {
  "[Nowledge Mem startup context truncated by \{host_label(source_app)} plugin]"
}

///|
/// Local-file fallback, only consulted for a default local service config
/// (upstream readStartupContext's final degradation step).
const NMEM_LOCAL_MEMORY_REL : String = "ai-now/memory.md"

///|
/// Degradation reasons reported in the startup prompt section (upstream
/// degradedReason strings).
pub const STARTUP_CONTEXT_TIMED_OUT : String = "startup context reads timed out"

///|
pub const STARTUP_CONTEXT_FAILED : String = "startup context reads failed"

///|
/// Result of the startup context degradation chain: a fetched bundle, or a
/// reason why none arrived. Both `None` means every read completed cleanly
/// with nothing to report (e.g. an empty working memory).
pub(all) struct StartupContext {
  context : String?
  degraded_reason : String?
} derive(Debug)

///|
/// Cap a startup bundle at NMEM_MAX_CONTEXT_CHARS and append the truncation
/// note (mirrors truncate_message's shape).
pub fn truncate_startup_context(text : String, source_app : String) -> String {
  if text.length() <= NMEM_MAX_CONTEXT_CHARS {
    text
  } else {
    "\{take_prefix(text, NMEM_MAX_CONTEXT_CHARS)}\n\n\{context_truncation_note(source_app)}"
  }
}

///|
/// Which CLI shape one degradation attempt uses — `context` and `wm read`
/// disagree on payload fields, so the parser needs to know the producer.
priv enum ContextAttemptKind {
  Context
  WmRead
}

///|
/// One degradation-chain attempt: the CLI argv plus its parser kind.
priv struct ContextAttempt {
  kind : ContextAttemptKind
  args : Array[String]
}

///|
/// The attempts, in order: scoped context, unscoped context, scoped wm read,
/// unscoped wm read (upstream ordering). Without a configured space the
/// scoped and unscoped pairs are identical, so only one of each runs — the
/// budget is not spent on duplicate invocations.
fn startup_attempts(config : NmemConfig) -> Array[ContextAttempt] {
  let context_args : Array[String] = [
    "--json",
    "context",
    "--source-app",
    config.source_app,
  ]
  let wm_args : Array[String] = ["--json", "wm", "read"]
  match config.space {
    Some(space) =>
      [
        {
          kind: Context,
          args: array_with_suffix(context_args, ["--space", space]),
        },
        { kind: Context, args: context_args },
        { kind: WmRead, args: array_with_suffix(wm_args, ["--space", space]) },
        { kind: WmRead, args: wm_args },
      ]
    None =>
      [{ kind: Context, args: context_args }, { kind: WmRead, args: wm_args }]
  }
}

///|
fn array_with_suffix(
  base : Array[String],
  suffix : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for item in base {
    out.push(item)
  }
  for item in suffix {
    out.push(item)
  }
  out
}

///|
/// stdout as a JSON object without an "error" key, else None (upstream treats
/// an error envelope as a failed read).
fn clean_json_object(stdout : String) -> Map[String, Json]? {
  let parsed = @json.parse(stdout) catch { _ => return None }
  match parsed {
    Json::Object(fields) =>
      if fields.contains("error") {
        None
      } else {
        Some(fields)
      }
    _ => None
  }
}

///|
/// First non-empty string among `keys`.
fn first_string_field(
  fields : Map[String, Json],
  keys : Array[String],
) -> String? {
  for key in keys {
    match fields.get(key) {
      Some(Json::String(value)) =>
        if value.trim().length() > 0 {
          return Some(value)
        }
      _ => ()
    }
  }
  None
}

///|
/// Context-bundle payload: rendered_markdown, then markdown, then content.
fn parse_context_payload(stdout : String) -> String? {
  match clean_json_object(stdout) {
    Some(fields) =>
      first_string_field(fields, ["rendered_markdown", "markdown", "content"])
    None => None
  }
}

///|
/// Working-memory payload: only when exists is not false, take content.
fn parse_wm_payload(stdout : String) -> String? {
  match clean_json_object(stdout) {
    Some(fields) =>
      if fields.get("exists") is Some(Json::False) {
        None
      } else {
        first_string_field(fields, ["content"])
      }
    None => None
  }
}

///|
/// Whether the local-file fallback is allowed: only a default local service
/// with no scoping configured reads the on-disk copy (upstream gate).
fn local_fallback_allowed(config : NmemConfig) -> Bool {
  config.space is None &&
  config.agent_id is None &&
  config.host_agent_id is None &&
  config.api_url == NMEM_DEFAULT_API_URL
}

///|
/// Run the startup context degradation chain (upstream readStartupContext):
///
/// 1. `nmem --json context --source-app <app>` (scoped first, then unscoped);
/// 2. `nmem --json wm read` (scoped, then unscoped);
/// 3. local `~/ai-now/memory.md` when the service is the default local one
///    and nothing scoped the reads;
///
/// all under one 8s budget — each attempt gets the remaining time, and an
/// exhausted budget skips the rest. Every hit is capped at 20k characters.
/// When nothing lands, `degraded_reason` distinguishes timeouts from failed
/// reads; a clean chain with no content carries neither.
pub async fn read_startup_context(
  runner : &NmemRunner,
  config : NmemConfig,
) -> StartupContext {
  let started_ms = @async.now()
  let mut timed_out = false
  let mut failed = false
  for attempt in startup_attempts(config) {
    let remaining_ms = NMEM_STARTUP_BUDGET_MS.to_int64() -
      (@async.now() - started_ms)
    if remaining_ms <= 0 {
      timed_out = true
      break
    }
    let outcome = NmemRunner::run_cli(
      runner,
      attempt.args,
      timeout_ms=remaining_ms.to_int(),
    )
    if outcome.exit == NMEM_CLI_ABORT_EXIT && outcome.stderr == "timeout" {
      timed_out = true
      continue
    }
    if outcome.exit != 0 {
      failed = true
      continue
    }
    let content : String? = match attempt.kind {
      Context => parse_context_payload(outcome.stdout)
      WmRead => parse_wm_payload(outcome.stdout)
    }
    match content {
      Some(text) =>
        return {
          context: Some(truncate_startup_context(text, config.source_app)),
          degraded_reason: None,
        }
      None =>
        // A clean object with no usable payload is a miss, not a failure —
        // only malformed output counts as a failed read.
        if clean_json_object(outcome.stdout) is None {
          failed = true
        }
    }
  }
  if local_fallback_allowed(config) {
    match NmemRunner::read_home_file(runner, NMEM_LOCAL_MEMORY_REL) {
      Some(text) =>
        return {
          context: Some(truncate_startup_context(text, config.source_app)),
          degraded_reason: None,
        }
      None => ()
    }
  }
  let reason : String? = if timed_out {
    Some(STARTUP_CONTEXT_TIMED_OUT)
  } else if failed {
    Some(STARTUP_CONTEXT_FAILED)
  } else {
    None
  }
  { context: None, degraded_reason: reason }
}

///|
/// Assemble the system-prompt sections (upstream before_agent_start): the
/// context bundle when present, a degradation notice when absent with a
/// reason, then the startup guidance — always.
pub fn assemble_prompt_sections(
  startup : StartupContext,
  source_app : String,
) -> String {
  let bundle : String? = match startup.context {
    Some(context) => Some("## Nowledge Mem Context Bundle\n\n" + context)
    None =>
      match startup.degraded_reason {
        Some(reason) =>
          Some(
            "## Nowledge Mem Context Bundle\n\n[Nowledge Mem startup context unavailable: \{reason}.]",
          )
        None => None
      }
  }
  match bundle {
    Some(bundle) => bundle + "\n\n" + startup_guidance(source_app)
    None => startup_guidance(source_app)
  }
}
