///|
fn command_defs() -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "obsidian-open",
      label: "Open in Obsidian",
      description: "Open a vault note in the Obsidian app",
      category: "obsidian",
      ctype: @posoco.CommandType::Input,
      params: [
        @posoco.CommandParam::{
          name: "path",
          label: "Vault path",
          description: "Vault-relative note path to open",
          ptype: @posoco.ParamType::Str,
          required: true,
          default: None,
          choices: None,
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "obsidian-daily",
      label: "Obsidian daily note",
      description: "Open (creating if needed) today's daily note",
      category: "obsidian",
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
