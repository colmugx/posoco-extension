///|
pub struct BoardExtension {
  config : BoardConfig
  runtime_ : @runtime.BoardRuntime
}

///|
pub fn BoardExtension::BoardExtension(
  config? : BoardConfig = BoardConfig::BoardConfig(),
) -> BoardExtension {
  if config.bind_host != "127.0.0.1" {
    abort(
      "posoco-ext-board S1 only permits bind_host=127.0.0.1; remote listeners are forbidden",
    )
  }
  {
    config,
    runtime_: @runtime.default_board_runtime(
      config.event_buffer,
      client_queue_depth=config.client_queue_depth,
    ),
  }
}

///|
/// Test/host injection seam. The injected runtime must preserve the same
/// loopback-only security contract as the default implementation.
pub fn BoardExtension::with_runtime(
  runtime~ : @runtime.BoardRuntime,
  config? : BoardConfig = BoardConfig::BoardConfig(),
) -> BoardExtension {
  if config.bind_host != "127.0.0.1" {
    abort(
      "posoco-ext-board S1 only permits bind_host=127.0.0.1; remote listeners are forbidden",
    )
  }
  { config, runtime_: runtime, }
}

///|
pub fn BoardExtension::config(self : BoardExtension) -> BoardConfig {
  self.config
}

///|
pub fn BoardExtension::runtime(self : BoardExtension) -> @runtime.BoardRuntime {
  self.runtime_
}

///|
/// The headless backend owned by the extension's runtime: commands,
/// snapshots and subscriptions work without any server or browser.
pub fn BoardExtension::backend(self : BoardExtension) -> @backend.BoardBackend {
  self.runtime_.backend()
}

///|
/// Bind Board-owned long-lived workers to the host's structured-concurrency
/// scope. This is runtime ownership only; it does not bind an Agent.
pub fn BoardExtension::attach(
  self : BoardExtension,
  group : @async.TaskGroup[Unit],
) -> Unit {
  self.runtime_.attach(group)
}

///|
pub impl @posoco.Extension for BoardExtension with fn extension_id(
  _self : BoardExtension,
) -> String {
  "posoco_ext_board"
}

///|
/// Commands, shutdown cleanup and synchronous display telemetry only; no Tasks.
pub impl @posoco.Extension for BoardExtension with fn manifest(
  self : BoardExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_board",
    lifecycle=[self],
    commands=[self],
    observers=[self],
  )
}

///|
pub impl @posoco.Lifecycle for BoardExtension with fn on_shutdown(self) -> Unit {
  self.runtime_.shutdown()
}

///|
pub impl @posoco.CommandPort for BoardExtension with fn commands(
  _self : BoardExtension,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "board.open",
      label: "Open Board",
      description: "Start the local Posoco Board control plane and open it in a browser",
      category: "board",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: ["board"],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "board.status",
      label: "Board status",
      description: "Show the local Posoco Board control-plane status",
      category: "board",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "board.close",
      label: "Close Board",
      description: "Stop the local Posoco Board control plane",
      category: "board",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
fn board_command_success(
  feedback : String,
  status : @runtime.BoardServerStatus,
) -> @posoco.CommandOutcome {
  @posoco.CommandOutcome::Success(
    feedback~,
    structured=Some(status.to_json()),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
pub impl @posoco.CommandPort for BoardExtension with fn invoke(
  self : BoardExtension,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "board.open" | "board" => {
      let opened = self.runtime_.open_board() catch {
        error =>
          return @posoco.CommandOutcome::Failure(
            reason="board open failed: " + error.to_string(),
          )
      }
      match opened {
        Ok(endpoint) =>
          board_command_success(
            "Board opened at " + endpoint.base_url(),
            self.runtime_.status(),
          )
        Err(error) => @posoco.CommandOutcome::Failure(reason=error)
      }
    }
    "board.status" => {
      let status = self.runtime_.status()
      board_command_success(
        "Board status: " + status.to_json().stringify(),
        status,
      )
    }
    "board.close" => {
      self.runtime_.close_server() catch {
        error =>
          return @posoco.CommandOutcome::Failure(
            reason="board close failed: " + error.to_string(),
          )
      }
      board_command_success("Board closed", self.runtime_.status())
    }
    _ => raise @posoco.CommandError::NotFound(id)
  }
}

///|
pub extend BoardExtension with @posoco.Extension::{extension_id, manifest}

///|
pub extend BoardExtension with @posoco.CommandPort::{commands, invoke}

///|
pub extend BoardExtension with @posoco.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}
