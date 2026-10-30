///|
fn team_name_field(
  id : String,
  label : String,
  value : String,
  role : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @ui.text_input(
    id~,
    name=id,
    label~,
    value~,
    placeholder="",
    disabled=false,
    autofocus=false,
    aria_label=label,
    on_input=text => emit(TeamNameChanged(role, text)),
  )
}

///|
fn team_role_name(draft : TeamNames, role : String) -> String {
  match role {
    "po" => draft.po
    "sm" => draft.sm
    "rd" => draft.rd
    "set" => draft.set
    _ => draft.te
  }
}

///|
fn team_mcp_for(draft : TeamNames, role : String) -> TeamMcp {
  match draft.mcp.get(role) {
    Some(value) => value
    None => TeamMcp::defaults()
  }
}

///|
fn team_tab(
  draft : TeamNames,
  role : String,
  active : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.button(
    type_="button",
    class=if role == active { "team-tab is-active" } else { "team-tab" },
    attrs=@html.Attrs::build()
      .role("tab")
      .aria_selected(if role == active { "true" } else { "false" })
      .on_click(_ => emit(TeamTabChanged(role))),
    team_role_name(draft, role),
  )
}

///|
fn team_skills_for(draft : TeamNames, role : String) -> TeamSkills {
  match draft.skills.get(role) {
    Some(value) => value
    None => TeamSkills::defaults()
  }
}

///|
fn team_skills_panel(
  model : Model,
  draft : TeamNames,
  role : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let config = team_skills_for(draft, role)
  let skills = model.tickets.skills
  @html.section(class="team-section", [
    @html.h3(class="section-title", "Skills"),
    @html.label(class="team-check", [
      @html.input(
        input_type=Checkbox,
        id="team-skills-enabled",
        name="team_skills_enabled",
        checked=config.enabled,
        on_change=_ => emit(TeamSkillsEnabledChanged(role, !config.enabled)),
      ),
      @html.span("Allow this member to use host-discovered skills"),
    ]),
    if !config.enabled {
      @html.p(
        class="empty-line",
        "Skills are off for this member. The agent gets no skill catalog or activation tools.",
      )
    } else if skills.is_empty() {
      @html.p(
        class="empty-line",
        "The host discovered no skills. Add SKILL.md files, then reopen this dialog.",
      )
    } else {
      @html.div(class="team-mcp", [
        @html.div(class="team-mode", [
          @html.label(class="team-check", [
            @html.input(
              input_type=Radio,
              name="team_skills_mode",
              value="all",
              checked=config.all,
              on_change=_ => emit(TeamSkillsAllChanged(role, true)),
            ),
            @html.span("All host skills"),
          ]),
          @html.label(class="team-check", [
            @html.input(
              input_type=Radio,
              name="team_skills_mode",
              value="selected",
              checked=!config.all,
              on_change=_ => emit(TeamSkillsAllChanged(role, false)),
            ),
            @html.span("Selected skills"),
          ]),
        ]),
        @html.div(
          class="team-servers",
          skills.map(skill => {
            let checked = config.all || config.skills.contains(skill.name)
            @html.label(
              class=if config.all {
                "team-server is-muted"
              } else {
                "team-server"
              },
              [
                @html.input(
                  input_type=Checkbox,
                  name="team_skill",
                  value=skill.name,
                  checked~,
                  attrs=@html.Attrs::build().disabled(config.all),
                  on_change=_ => emit(TeamSkillToggled(role, skill.name)),
                ),
                @html.span(class="team-server-name", skill.name),
                @html.span(
                  class="team-skill-desc",
                  if skill.description == "" {
                    "no description"
                  } else {
                    skill.description
                  },
                ),
              ],
            )
          }),
        ),
      ])
    },
  ])
}

///|
fn team_mcp_panel(
  model : Model,
  draft : TeamNames,
  role : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let config = team_mcp_for(draft, role)
  let servers = model.tickets.mcp_servers
  @html.div(class="team-page", [
    team_name_field("team-name", "Name", team_role_name(draft, role), role, emit),
    @html.section(class="team-section", [
      @html.h3(class="section-title", "MCP"),
      @html.label(class="team-check", [
        @html.input(
          input_type=Checkbox,
          id="team-mcp-enabled",
          name="team_mcp_enabled",
          checked=config.enabled,
          on_change=_ => emit(TeamMcpEnabledChanged(role, !config.enabled)),
        ),
        @html.span("Allow this member to use host-configured MCP servers"),
      ]),
      if !config.enabled {
        @html.p(
          class="empty-line",
          "MCP is off for this member. The tools stay hidden from its agent.",
        )
      } else if servers.is_empty() {
        @html.p(
          class="empty-line",
          "The host has no configured MCP servers. Add them in mcp.json, then reopen this dialog.",
        )
      } else {
        @html.div(class="team-mcp", [
          @html.div(class="team-mode", [
            @html.label(class="team-check", [
              @html.input(
                input_type=Radio,
                name="team_mcp_mode",
                value="all",
                checked=config.all,
                on_change=_ => emit(TeamMcpAllChanged(role, true)),
              ),
              @html.span("All host servers"),
            ]),
            @html.label(class="team-check", [
              @html.input(
                input_type=Radio,
                name="team_mcp_mode",
                value="selected",
                checked=!config.all,
                on_change=_ => emit(TeamMcpAllChanged(role, false)),
              ),
              @html.span("Selected servers"),
            ]),
          ]),
          @html.div(
            class="team-servers",
            servers.map(server => {
              let checked = config.all || config.servers.contains(server.name)
              @html.label(
                class=if config.all {
                  "team-server is-muted"
                } else {
                  "team-server"
                },
                [
                  @html.input(
                    input_type=Checkbox,
                    name="team_mcp_server",
                    value=server.name,
                    checked~,
                    attrs=@html.Attrs::build().disabled(config.all),
                    on_change=_ =>
                      emit(TeamMcpServerToggled(role, server.name)),
                  ),
                  @html.span(class="team-server-name", server.name),
                  @html.span(
                    class=if server.connected {
                      "chip is-running"
                    } else {
                      "chip is-quiet"
                    },
                    if server.connected {
                      "\{server.tools.length()} tools"
                    } else {
                      "not connected"
                    },
                  ),
                ],
              )
            }),
          ),
          @html.label(class="team-check", [
            @html.input(
              input_type=Checkbox,
              name="team_mcp_restrict_tools",
              checked=config.tools.length() > 0,
              on_change=_ =>
                emit(TeamMcpToolsRestricted(role, config.tools.is_empty())),
            ),
            @html.span("Only selected tools"),
          ]),
          if config.tools.is_empty() {
            @html.p(
              class="empty-line",
              "Every tool from the allowed servers is available.",
            )
          } else {
            @html.div(class="team-tools", {
              let groups : Array[@html.Html] = []
              for server in servers {
                let selected = config.all ||
                  config.servers.contains(server.name)
                if selected && !server.tools.is_empty() {
                  groups.push(
                    @html.div(class="team-tool-group", [
                      @html.span(class="team-tool-server", server.name),
                      @html.div(
                        class="team-tool-list",
                        server.tools.map(tool =>
                          @html.label(class="team-check team-tool", [
                            @html.input(
                              input_type=Checkbox,
                              name="team_mcp_tool",
                              value=tool,
                              checked=config.tools.contains(tool),
                              on_change=_ =>
                                emit(TeamMcpToolToggled(role, tool)),
                            ),
                            @html.span(tool),
                          ])
                        ),
                      ),
                    ]),
                  )
                }
              }
              groups
            })
          },
        ])
      },
    ]),
    team_skills_panel(model, draft, role, emit),
  ])
}

///|
fn team_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let draft = model.team_draft
  let draft_profile = model.team_profile_draft
  let roles = ["po", "sm", "rd", "set", "te"]
  @ui.dialog(
    "team-dialog",
    "Team settings",
    _ => emit(TeamClosed),
    ["width:min(calc(100% - 2rem),46rem)"],
    [
      @html.div(class="dialog-shell", [
        @html.header(class="dialog-head", [
          @html.div(class="dialog-titles", [
            @html.h2(class="dialog-title", "Team settings"),
            @html.p(
              class="dialog-subtitle",
              "Each member has a name and its own MCP access. MCP servers come from the host's mcp.json.",
            ),
          ]),
        ]),
        @html.div(class="dialog-body", [
          @ui.select_field(
            id="team-profile",
            name="work_profile",
            label="Work profile",
            disabled=false,
            on_change=value => emit(TeamProfileChanged(value)),
            work_profiles().map(profile => {
              @html.option(
                value=profile.id,
                selected=profile.id == draft_profile.id,
                profile.label,
              )
            }),
          ),
          @html.div(
            class="team-tabs",
            roles.map(role => {
              team_tab(draft, role, model.team_tab, emit)
            }),
          ),
          team_mcp_panel(model, draft, model.team_tab, emit),
        ]),
        @html.footer(class="dialog-foot", [
          @html.div(class="dialog-actions", [
            @html.button(
              type_="button",
              class="btn",
              attrs=@html.Attrs::build().on_click(_ => {
                ui_close("team-dialog")
                emit(TeamClosed)
              }),
              "Cancel",
            ),
            @html.button(
              type_="button",
              class="btn btn-primary",
              disabled=model.ticket_sending || !model.ticket_available,
              attrs=@html.Attrs::build().on_click(_ => {
                ui_close("team-dialog")
                emit(TeamSaved)
              }),
              "Save team",
            ),
          ]),
        ]),
      ]),
    ],
  )
}

