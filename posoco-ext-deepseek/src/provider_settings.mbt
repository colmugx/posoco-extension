///|
/// Provider settings resolution: every `ProviderConfigSource` key DeepSeek
/// consumes, parsed in a fixed order with typed composition errors,
/// provider-owned defaults, and strict validation. The shared
/// `deepseek_provider_config` entry is used by both the offline `build` and
/// the online `refresh`; catalog selection and network policy stay with the
/// callers.

///|
fn deepseek_setting_string(
  source : @provider.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_deepseek",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Keep URL parsing in the provider extension. The host passes one opaque
/// base_url string; DeepSeek decides how its path prefix maps to chat/FIM.
fn deepseek_endpoint_parts(url : String) -> (String, String) {
  match url.find("://") {
    None => (url, "")
    Some(protocol_end) => {
      let after_start = protocol_end + 3
      let after = url.exact_view(start=after_start)
      match after.find("/") {
        None => (url, "")
        Some(slash) => {
          let host_end = after_start + slash
          let clean = url.exact_view(end=host_end).to_owned()
          let prefix = after.exact_view(start=slash).to_owned()
          match prefix.strip_suffix("/") {
            Some(value) => (clean, value.to_owned())
            None => (clean, prefix)
          }
        }
      }
    }
  }
}

///|
/// DeepSeek API key from settings + credential; `None` when no key is present
/// anywhere. Shared by the catalog build/refresh and the balance probe so
/// both read the account through one credential.
fn deepseek_api_key(
  source : @provider.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential("deepseek")
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="OAuth credential is not supported for provider deepseek",
      )
    Some(@oauth.ProviderCredential::ApiKey(value)) => Some(value.secret)
    None => deepseek_setting_string(source, "api_key")
  }
}

///|
/// Settings-level effort gate shared by build and refresh: the empty string
/// (thinking disabled) plus every provider-wide selectable effort.
fn deepseek_setting_effort_supported(effort : String) -> Bool {
  effort == "" || deepseek_reasoning_efforts().contains(effort)
}

///|
/// Provider-owned ceiling parser. Both factory build and authenticated
/// refresh use the same strict validation. No host-specific settings schema.
fn deepseek_setting_max_reasoning_chars(
  source : @provider.ProviderConfigSource,
) -> Int32? raise @posoco.CompositionError {
  match source.setting("max_reasoning_chars") {
    None => Some(120000)
    Some(Json::Null) => None
    Some(Json::Number(number, ..)) => {
      if number.is_nan() ||
        number.is_inf() ||
        number <= 0.0 ||
        number > 2147483647.0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_deepseek",
          detail="max_reasoning_chars must be a positive integer within Int range",
        )
      }
      let value = number.to_int()
      if value.to_double() != number {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_deepseek",
          detail="max_reasoning_chars must be a positive integer within Int range",
        )
      }
      Some(value)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="max_reasoning_chars must be a positive integer within Int range",
      )
  }
}

///|
fn deepseek_setting_repeated_span(
  source : @provider.ProviderConfigSource,
) -> Int32? raise @posoco.CompositionError {
  match source.setting("repeated_reasoning_span_chars") {
    None => Some(256)
    Some(Json::Null) => None
    Some(Json::Number(n, ..)) => {
      if n.is_nan() ||
        n.is_inf() ||
        n < 128.0 ||
        n > 715827882.0 ||
        n.to_int().to_double() != n {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_deepseek",
          detail="repeated_reasoning_span_chars must be an integer from 128 to 715827882",
        )
      }
      Some(n.to_int())
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="repeated_reasoning_span_chars must be an integer from 128 to 715827882",
      )
  }
}

///|
fn deepseek_setting_recover_on_exhaustion(
  source : @provider.ProviderConfigSource,
) -> Bool raise @posoco.CompositionError {
  match source.setting("recover_on_reasoning_exhaustion") {
    None | Some(Json::True) => true
    Some(Json::False) => false
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="recover_on_reasoning_exhaustion must be a boolean",
      )
  }
}

///|
/// Prompt profile is explicit because `/models` does not advertise a
/// version. Do not infer the renderer version from mutable model aliases.
fn deepseek_setting_prompt_profile(
  source : @provider.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match source.setting("prompt_profile") {
    None => "unknown"
    Some(String("unknown")) => "unknown"
    Some(String("v4")) => "v4"
    Some(String("v4.1")) => "v4.1"
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="prompt_profile must be one of unknown, v4, v4.1",
      )
  }
}

///|
/// Image-input opt-in. The /models endpoint carries no modality metadata,
/// so the host declares it per settings; default false keeps every image
/// block on the explicit placeholder downgrade.
fn deepseek_setting_image_input(
  source : @provider.ProviderConfigSource,
) -> Bool raise @posoco.CompositionError {
  match source.setting("image_input") {
    None | Some(Json::False) => false
    Some(Json::True) => true
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="image_input must be a boolean",
      )
  }
}

///|
/// A typed provider-setting error is better than a constructor abort for
/// contradictory user-specified V4 renderer and image capability.
fn deepseek_setting_vision_profile(
  source : @provider.ProviderConfigSource,
) -> (String, Bool) raise @posoco.CompositionError {
  let prompt_profile = deepseek_setting_prompt_profile(source)
  let supports_images = deepseek_setting_image_input(source)
  if prompt_profile == "v4" && supports_images {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="image_input is unsupported for the explicit V4 prompt profile",
    )
  }
  (prompt_profile, supports_images)
}

///|
/// The shared settings→config resolution for both factory entries. Returns
/// `None` only when no API key is present anywhere (the caller's
/// Unconfigured case); field order, defaults, and error text are part of the
/// contract and must not drift between build and refresh.
fn deepseek_provider_config(
  source : @provider.ProviderConfigSource,
) -> DeepSeekConfig? raise @posoco.CompositionError {
  let api_key = match deepseek_api_key(source) {
    Some(value) => value
    None => return None
  }
  let model = match deepseek_setting_string(source, "model") {
    Some(value) => value
    // Provider-owned default; the setting is optional and only pins priority.
    None => "deepseek-flash"
  }
  let base_url_setting = match deepseek_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.deepseek.com"
  }
  let (base_url, endpoint_prefix) = deepseek_endpoint_parts(base_url_setting)
  let effort = match deepseek_setting_string(source, "reasoning_effort") {
    Some("off") => ""
    Some(value) => value
    None => "high"
  }
  // Keep live refresh validation identical to the static build path.  In
  // particular, an unknown configured effort is a typed composition failure,
  // not the abort emitted by DeepSeekConfig for an invalid value.
  if !deepseek_setting_effort_supported(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning_effort: " + effort,
    )
  }
  let (prompt_profile, supports_images) = deepseek_setting_vision_profile(
    source,
  )
  Some(
    DeepSeekConfig(
      api_key,
      model~,
      base_url~,
      endpoint_prefix~,
      reasoning_effort=effort,
      context_window=source.context_window_setting(
        manifest_id="posoco_ext_deepseek",
      ),
      max_reasoning_chars=deepseek_setting_max_reasoning_chars(source),
      recover_on_reasoning_exhaustion=deepseek_setting_recover_on_exhaustion(
        source,
      ),
      repeated_reasoning_span_chars=deepseek_setting_repeated_span(source),
      supports_images~,
      prompt_profile~,
    ),
  )
}
