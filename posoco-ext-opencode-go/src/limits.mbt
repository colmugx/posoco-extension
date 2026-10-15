///|
/// The OpenCode Go plan allowances. Usage limits are defined as monthly
/// dollar amounts per model ("5-hour — 20% of the monthly limit; weekly —
/// 50%; monthly — 100%" is the vendor's own rule), and both plans pay the
/// same token prices — the plans differ only in the allowance. The table is
/// distilled from the vendor's Go documentation; `None` means the vendor
/// lists the model as Unlimited (limited-time free rows) or the model is
/// unknown to the table — never a guessed dollar figure. The authoritative
/// live state is the `/usage` endpoint; this table only names the allowance
/// the windows are shares of.
pub(all) enum GoPlan {
  Go
  GoPlus
} derive(Eq, Debug)

///|
pub extend GoPlan with Eq::{not_equal, equal}

///|
pub extend GoPlan with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parse the `plan` setting; an unknown value is a typed composition
/// failure rather than a silent default.
pub fn go_plan_of_setting(
  value : String,
) -> GoPlan raise @posoco.CompositionError {
  match value {
    "go" => Go
    "go_plus" => GoPlus
    other =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_go",
        detail="setting plan must be \"go\" or \"go_plus\", got: " + other,
      )
  }
}

///|
/// The vendor's Go-plan monthly allowance for one model, in USD:
/// `(go, go_plus)` per model id. `None` = Unlimited (the limited-time free
/// rows) or unknown to the table.
fn go_allowance_pair(model_id : String) -> (Double?, Double?) {
  match model_id {
    "glm-5.3-flash" => (Some(60.0), Some(180.0))
    "glm-5.3" => (Some(15.0), Some(120.0))
    "glm-5.2" => (Some(60.0), Some(180.0))
    "kimi-k3" => (Some(15.0), Some(60.0))
    "kimi-k2.7-code" => (Some(60.0), Some(180.0))
    "kimi-k2.6" => (Some(60.0), Some(240.0))
    "longcat-2.0" => (Some(60.0), Some(240.0))
    "longcat-2.5-preview-free" | "step-5-preview-free" | "cat-jam-free" =>
      (None, None)
    "mimo-v2.6-flash" => (Some(60.0), Some(120.0))
    "mimo-v2.6-pro" => (Some(15.0), Some(60.0))
    "mimo-v2.5" => (Some(60.0), Some(120.0))
    "mimo-v2.5-pro" => (Some(15.0), Some(60.0))
    "minimax-m3" => (Some(60.0), Some(180.0))
    "minimax-m2.7" => (Some(60.0), Some(240.0))
    "muse-spark-1.3-contributor" => (Some(60.0), Some(120.0))
    "muse-spark-1.2-contributor" => (Some(60.0), Some(120.0))
    "qwen3.8-max" => (Some(15.0), Some(60.0))
    "qwen3.8-flash" => (Some(30.0), Some(90.0))
    "qwen3.7-plus" => (Some(60.0), Some(180.0))
    "deepseek-v4.1-flash" => (Some(80.0), Some(160.0))
    "deepseek-v4-pro" => (Some(15.0), Some(60.0))
    "hy4-preview" => (Some(30.0), Some(120.0))
    "hy3" => (Some(60.0), Some(240.0))
    "space-bunny" => (Some(30.0), Some(120.0))
    "grok-4.7" | "grok-4.6" => (Some(15.0), Some(60.0))
    "gpt-6-luna" => (Some(15.0), Some(60.0))
    "gpt-5.6-luna" => (Some(15.0), Some(60.0))
    "claude-haiku-5-5" => (Some(15.0), Some(60.0))
    "gemini-4-argon-contributor" => (Some(60.0), Some(240.0))
    _ => (None, None)
  }
}

///|
/// The vendor's Go-plan monthly allowance for one model, in USD.
/// `None` = Unlimited (limited-time free rows) or unknown to the table.
pub fn go_monthly_allowance(model_id : String, plan : GoPlan) -> Double? {
  let pair = go_allowance_pair(model_id)
  match plan {
    Go => pair.0
    GoPlus => pair.1
  }
}
