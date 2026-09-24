///|
/// Consent hook: destructive writes need an explicit yes from the composed
/// UI before execution. Headless hosts (no UiPort) get Reject — never a
/// silent pass-through. Ordinary calls (all reads, append/prepend, property
/// set/remove, trash deletes) approve with zero UI interaction.
pub impl @posoco.PipelineHook for ObsidianTools with fn before_tool(
  self : ObsidianTools,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  let needs_consent = match call.name.to_string() {
    "obsidian_delete_note" => arg_bool(call.arguments, "permanent")
    "obsidian_create_note" => arg_bool(call.arguments, "overwrite")
    "obsidian_patch_note" =>
      match arg_string(call.arguments, "target_type") {
        Some("heading") =>
          match arg_string(call.arguments, "operation") {
            Some("replace") | Some("delete") => true
            _ => false
          }
        _ => false
      }
    _ => false
  }
  if !needs_consent {
    return @posoco.ToolDecision::Approve(call~)
  }
  match self.ui {
    None =>
      @posoco.ToolDecision::Reject(
        reason="destructive Obsidian write requested but no UI is available for consent; host must compose a UiPort",
      )
    Some(ui) => {
      let prompt = consent_prompt(call)
      match ui.request(@posoco.UiRequest::Confirm(prompt~)) {
        @posoco.UiResponse::Yes =>
          @posoco.ToolDecision::ApproveAfterConsent(
            call~,
            consent_scope="obsidian_write",
          )
        _ =>
          @posoco.ToolDecision::Reject(
            reason="user declined the Obsidian write",
          )
      }
    }
  }
}

///|
pub extend ObsidianTools with @posoco.PipelineHook::{
  on_post_event,
  on_turn_begin,
  on_post_event_at,
  before_model,
  before_tool,
  on_turn_end,
}

///|
fn consent_prompt(call : @posoco.ToolCall) -> String {
  let path = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => "?"
  }
  match call.name.to_string() {
    "obsidian_delete_note" =>
      if arg_bool(call.arguments, "permanent") {
        "Permanently delete vault note \"\{path}\" (skips trash)?"
      } else {
        "Delete vault note \"\{path}\"?"
      }
    "obsidian_create_note" => "Overwrite existing vault note \"\{path}\"?"
    "obsidian_patch_note" => {
      let op = match arg_string(call.arguments, "operation") {
        Some(o) => o
        None => "?"
      }
      let target = match arg_string(call.arguments, "target") {
        Some(t) => t
        None => "?"
      }
      "\{op} section \"\{target}\" in vault note \"\{path}\"?"
    }
    _ => "Confirm Obsidian write"
  }
}

///|
/// The composed UI is delivered once at compose time and stored for the
/// consent hook; declared via `requires: [Capability::Ui]`.
pub impl @posoco.Lifecycle for ObsidianTools with fn on_compose(
  self : ObsidianTools,
  ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.ui = ctx.ui()
}

///|
/// Static usage guidance. Byte-stable by contract: no vault names, counts,
/// or timestamps here, so the prompt cache never invalidates.
pub impl @posoco.SystemPromptContributor for ObsidianTools with fn system_prompt(
  _self : ObsidianTools,
) -> String {
  "Obsidian: locate notes with search/list before reading; never guess paths. Use outline before heading replace/delete. Move notes with obsidian_move_note. Permanent delete/overwrite requires consent."
}
