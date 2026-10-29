///|
test "team state carries per-role mcp and host servers" {
  let state = ticket_state_from_json({
    "project": "demo",
    "team": { "po": "Coach", "rd": "R&D", "set": "SET", "te": "TE" },
    "team_mcp": {
      "po": { "enabled": true, "all": false, "servers": ["github"] },
      "rd": { "enabled": false, "all": true, "servers": [] },
    },
    "team_skills": {
      "po": { "enabled": true, "all": false, "skills": ["tdd"] },
      "rd": { "enabled": true, "all": true, "skills": [] },
    },
    "skills": [
      { "name": "tdd", "description": "Test first" },
      { "name": "review", "description": "Review code" },
    ],
    "mcp_servers": {
      "servers": [
        { "name": "github", "connected": true, "tools": ["github__get_issue"] },
        { "name": "browser", "connected": false, "tools": [] },
      ],
    },
  })
  let team = match state.team {
    Some(team) => team
    None => fail("team missing")
  }
  assert_eq(team.po, "Coach")
  assert_eq(team.rd, "R&D")
  match team.mcp.get("po") {
    Some(value) => {
      assert_true(value.enabled)
      assert_false(value.all)
      assert_eq(value.servers, ["github"])
    }
    None => fail("po mcp missing")
  }
  match team.skills.get("po") {
    Some(value) => {
      assert_true(value.enabled)
      assert_false(value.all)
      assert_eq(value.skills, ["tdd"])
    }
    None => fail("po skills missing")
  }
  assert_eq(state.skills.length(), 2)
  assert_eq(state.skills[0].name, "tdd")
  assert_eq(state.mcp_servers.length(), 2)
  assert_true(state.mcp_servers[0].connected)
  assert_eq(state.mcp_servers[0].tools, ["github__get_issue"])
  assert_false(state.mcp_servers[1].connected)
}
