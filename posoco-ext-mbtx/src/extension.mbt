///|
/// Composable MBTX extension: toolchain readiness is queried through a
/// read-only command, never broadcast as a status/UI event. Guest execution
/// stays async via Runtime.run until a scoped Posoco Runtime bridge is connected.
pub struct MbtxExtension {
  runtime : Runtime
}

///|
pub fn MbtxExtension::MbtxExtension(
  home? : String,
  prefer_system~ : Bool = true,
) -> MbtxExtension {
  { runtime: Runtime(home?, prefer_system~), }
}

///|
pub fn MbtxExtension::runtime(self : MbtxExtension) -> Runtime {
  self.runtime
}

///|
pub impl @posoco.Extension for MbtxExtension with fn extension_id(
  _self : MbtxExtension,
) -> String {
  "posoco_ext_mbtx"
}

///|
pub impl @posoco.Extension for MbtxExtension with fn manifest(
  self : MbtxExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_mbtx", commands=[self], prompt_contributors=[
    self,
  ])
}

///|
pub impl @posoco.CommandPort for MbtxExtension with fn commands(
  _self : MbtxExtension,
) -> Array[@posoco.CommandDef] {
  [
    {
      id: "mbtx",
      label: "MBTX status",
      description: "Inspect MoonBit Code Mode toolchain readiness and provenance",
      category: "mbtx",
      ctype: @posoco.CommandType::Action,
      params: [
        {
          name: "action",
          label: "Action",
          description: "Show current MBTX status",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: Some(Json::string("status")),
          choices: Some(["status"]),
          positional: true,
        },
      ],
      aliases: ["mbtx_status"],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for MbtxExtension with fn invoke(
  self : MbtxExtension,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "mbtx" | "mbtx_status" =>
      @posoco.CommandOutcome::Success(
        feedback=self.runtime.toolchain_status(),
        structured=None,
        ui_hint=None,
      )
    _ => raise @posoco.CommandError::NotFound(id)
  }
}

///|
pub extend MbtxExtension with @posoco.Extension::{manifest, extension_id}

///|
pub extend MbtxExtension with @posoco.CommandPort::{commands, invoke}
