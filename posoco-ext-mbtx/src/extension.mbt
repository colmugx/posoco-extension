///|
/// Composable MBTX extension: the toolchain and status reporting belong to
/// the extension rather than to the embedding product. Guest execution stays
/// async via Runtime.run until a scoped Posoco Runtime bridge is connected.
pub struct MbtxExtension {
  runtime : Runtime
}

///|
pub fn MbtxExtension::MbtxExtension(
  bus? : @devkit.EventBus,
  home? : String,
  prefer_system~ : Bool = true,
) -> MbtxExtension {
  { runtime: Runtime(bus?, home?, prefer_system~), }
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
  @posoco.ExtensionManifest(id="posoco_ext_mbtx", commands=[self])
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
