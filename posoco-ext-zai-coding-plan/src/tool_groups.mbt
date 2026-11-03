///|
/// The Z.ai coding-plan official tool plane: the remote MCP servers the plan
/// entitles rather than the model itself.
///
/// This module is the *declaration* — a pure function from provider facts to
/// the group list a tools extension would announce. Nothing here opens a
/// connection or touches Posoco: the announcement policy stays a value so the
/// lifecycle code (`tools.mbt`) and tests share one source of truth, and a
/// future per-model tier only changes this function.
///
/// The three servers are plan-wide (any model served by this provider gets
/// them), so `model` is accepted but not yet discriminating: an empty model is
/// the one case that declares nothing, keeping "no model, no tools" honest.

///|
/// Stable host-facing provider id. Exported so composition roots never spell
/// the literal: a rename then breaks the build instead of silently disabling
/// the tool plane.
pub fn zai_coding_plan_provider_id() -> String {
  "zai-coding-plan"
}

///|
/// The official MCP servers included in the GLM Coding Plan, in announcement
/// order. Each name is the provider-owned server id and the URL path segment.
pub fn zai_coding_plan_mcp_group_names() -> Array[String] {
  ["web_search_prime", "web_reader", "zread"]
}

///|
/// Human-facing title per provider-owned server id.
fn zai_coding_plan_mcp_group_title(group : String) -> String {
  match group {
    "web_search_prime" => "Web Search"
    "web_reader" => "Web Reader"
    "zread" => "Zread"
    other => other
  }
}

///|
/// One declared remote MCP server.
///
/// `group` is the provider-owned server id (also the tool namespace prefix the
/// MCP plane applies); `endpoint` is the absolute URL the plane dials with the
/// plan key. The declaration carries no credential: the key travels as the
/// `Authorization` header at connect time and never becomes part of a value
/// that could be logged.
#derive(Eq, Debug)
pub(all) struct ZaiToolGroup {
  group : String
  title : String
  endpoint : String
}

///|
pub extend ZaiToolGroup with Eq::{not_equal, equal}

///|
pub extend ZaiToolGroup with Debug::{to_repr}

///|
/// Host the MCP plane lives on for one profile. Unknown profiles return `None`
/// instead of guessing: a wrong host would look like a credential failure.
pub fn zai_coding_plan_profile_host(profile : String) -> String? {
  match profile {
    "coding" => Some("https://api.z.ai")
    "cn_coding" => Some("https://open.bigmodel.cn")
    _ => None
  }
}

///|
/// Normalize a host: no trailing slash, empty means unusable.
fn zai_coding_plan_clean_host(host : String) -> String? {
  if host == "" {
    return None
  }
  match host.strip_suffix("/") {
    Some(trimmed) => if trimmed == "" { None } else { Some(trimmed.to_owned()) }
    None => Some(host)
  }
}

///|
/// Endpoint of one provider-owned MCP server on the given host.
fn zai_coding_plan_mcp_endpoint(host : String, group : String) -> String {
  host + "/api/mcp/" + group + "/mcp"
}

///|
/// Declare the tool groups a given model brings.
///
/// `host` is already resolved by the caller (the profile host, or the
/// override's host) so the chat route and the MCP plane cannot disagree about
/// which host they talk to. An empty model or an unusable host declares
/// nothing rather than guessing.
pub fn zai_coding_plan_declared_groups(
  model~ : String,
  host~ : String,
) -> Array[ZaiToolGroup] {
  if model == "" {
    return []
  }
  let host = match zai_coding_plan_clean_host(host) {
    Some(host) => host
    None => return []
  }
  let groups : Array[ZaiToolGroup] = []
  for group in zai_coding_plan_mcp_group_names() {
    groups.push({
      group,
      title: zai_coding_plan_mcp_group_title(group),
      endpoint: zai_coding_plan_mcp_endpoint(host, group),
    })
  }
  groups
}
