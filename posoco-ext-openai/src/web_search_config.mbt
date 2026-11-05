///|
/// Hosted OpenAI Web Search mode owned by the provider. Hosts pick a mode
/// name; this extension alone decides how that mode reaches the Responses
/// `tools` array, so router/agent layers stay free of provider wire knowledge.
pub(all) enum OpenAIWebSearchMode {
  /// Server-side index only: the hosted tool declares
  /// `external_web_access: false`.
  Cached
  /// Live external page access: the hosted tool declares
  /// `external_web_access: true`.
  Live
  /// Declare nothing; the request keeps the plain function-tool shape.
  Disabled
}

///|
/// The hosted `web_search` tool declaration sent beside the ordinary function
/// tools. `Disabled` yields `None`, so no hosted entry (and no empty `tools`
/// array) is ever emitted for it.
fn openai_web_search_tool(mode : OpenAIWebSearchMode) -> Json? {
  match mode {
    OpenAIWebSearchMode::Disabled => None
    OpenAIWebSearchMode::Cached =>
      Some(openai_web_search_declaration(external_web_access=false))
    OpenAIWebSearchMode::Live =>
      Some(openai_web_search_declaration(external_web_access=true))
  }
}

///|
/// Official hosted-tool tag plus the one field the modes differ on. Cached
/// answers come from the server-side index; live adds external page access.
fn openai_web_search_declaration(external_web_access~ : Bool) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("web_search")),
      ("external_web_access", Json::boolean(external_web_access)),
    ]),
  )
}

///|
/// Provider-settings decoder for the `web_search` key. `cached`, `live` and
/// `disabled` are the only accepted values, and an absent key keeps the
/// official client default (`cached`). A typo or a non-string value fails
/// composition instead of silently falling back, and the accepted set is named
/// in the error.
fn parse_openai_web_search_mode(
  source : @llm.ProviderConfigSource,
) -> OpenAIWebSearchMode raise @posoco.CompositionError {
  let key = "web_search"
  match source.setting(key) {
    None => OpenAIWebSearchMode::Cached
    Some(Json::String("cached")) => OpenAIWebSearchMode::Cached
    Some(Json::String("live")) => OpenAIWebSearchMode::Live
    Some(Json::String("disabled")) => OpenAIWebSearchMode::Disabled
    Some(Json::String(other)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai",
        detail="unsupported web_search mode: \{other} (expected cached, live or disabled)",
      )
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai",
        detail="setting must be a string: \{key}",
      )
  }
}
