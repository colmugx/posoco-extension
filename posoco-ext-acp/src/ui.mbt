///|
/// UiPort view over the ACP bridge: interactive requests become ACP v1
/// `elicitation/create` form-mode reverse requests.
///
/// Elicitation is a v1 *client* capability: the client (an editor such as
/// Zed) renders its own native form UI from the JSON schema sent here, so
/// this port never draws anything itself. The mapping is fixed:
/// - `Input`   → one required string field, optional pre-fill as `default`
/// - `Confirm` → one required boolean field
/// - `Select`  → one required string field with the options as an `enum`
///
/// Accept returns the field value; decline and cancel both mean the user
/// refused the form → `UiResponse::Cancelled`. A client without the
/// elicitation capability (the runtime rejects the request) and a detached
/// bridge both raise `Unsupported`, which ask-question-style tools degrade
/// to a model-visible tool error instead of failing the turn.
///
/// `render` is a deliberate no-op: ACP v1 has no render-intent channel, and
/// status lines, toasts, and widgets are host-UI concepts the client owns.

///|
/// Form field name shared by every elicitation this bridge creates. The
/// name is the only coupling between the schema builders below and the
/// accept-content extraction in `acp_elicitation_value`.
const ACP_ELICIT_FIELD = "value"

///|
/// The question text and the requested-schema property fields for one UI
/// request. The property shapes the client's form field; the message is the
/// form's heading.
fn acp_elicitation_parts(
  req : @posoco.UiRequest,
) -> (String, Map[String, Json]) {
  match req {
    Input(prompt~, default~) => {
      let fields : Map[String, Json] = { "type": Json::string("string") }
      match default {
        Some(value) => fields["default"] = Json::string(value)
        None => ()
      }
      (prompt, fields)
    }
    Confirm(prompt~) => (prompt, { "type": Json::string("boolean") })
    Select(prompt~, options~, default~) => {
      let enum_values : Array[Json] = []
      for option in options {
        enum_values.push(Json::string(option))
      }
      let fields : Map[String, Json] = {
        "type": Json::string("string"),
        "enum": Json::array(enum_values),
      }
      match default {
        Some(index) if index >= 0 && index < options.length() =>
          fields["default"] = Json::string(options[index])
        _ => ()
      }
      (prompt, fields)
    }
  }
}

///|
/// Build the `elicitation/create` form payload for one UI request: an
/// object schema with a single required field named `ACP_ELICIT_FIELD`,
/// whose per-kind shape is the only thing that varies.
fn acp_elicitation_params(
  session_id : String,
  req : @posoco.UiRequest,
) -> @acp.ElicitationCreateParams {
  let (message, property) = acp_elicitation_parts(req)
  let properties : Map[String, Json] = Map([])
  properties[ACP_ELICIT_FIELD] = Json::object(property)
  Form({
    scope: Session(session_id~, tool_call_id=Omitted),
    message,
    requested_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object(properties),
      "required": Json::array([Json::string(ACP_ELICIT_FIELD)]),
    }),
    meta: Omitted,
  })
}

///|
/// Extract the accept-action form value. An accept without usable content
/// is a client contract violation and fails loudly, never a silent empty
/// answer.
fn acp_elicitation_value(
  result : @acp.ElicitationCreateResult,
) -> Json raise @posoco.UiError {
  match result.content {
    Value(Json::Object(fields)) =>
      match fields.get(ACP_ELICIT_FIELD) {
        Some(value) => value
        None =>
          raise @posoco.UiError::IoFailure(
            detail="acp: elicitation accept carried no '" +
              ACP_ELICIT_FIELD +
              "' field",
          )
      }
    _ =>
      raise @posoco.UiError::IoFailure(
        detail="acp: elicitation accept carried no form content",
      )
  }
}

///|
/// Map an accepted string answer onto the option index it names. A string
/// outside the requested enum is a client contract violation.
fn acp_select_response(
  options : Array[String],
  value : Json,
) -> @posoco.UiResponse raise @posoco.UiError {
  match value {
    Json::String(text) => {
      let mut chosen = -1
      for index, option in options {
        if option == text {
          chosen = index
          break
        }
      }
      if chosen < 0 {
        raise @posoco.UiError::IoFailure(
          detail="acp: elicitation answer is outside the requested options",
        )
      }
      @posoco.UiResponse::Selected(chosen)
    }
    _ =>
      raise @posoco.UiError::IoFailure(
        detail="acp: elicitation answer must be a string",
      )
  }
}

///|
/// Map one elicitation result onto the UI response for the request that
/// produced it. Decline and cancel are both "the user refused the form".
fn acp_ui_response(
  req : @posoco.UiRequest,
  result : @acp.ElicitationCreateResult,
) -> @posoco.UiResponse raise @posoco.UiError {
  match result.action {
    Decline | Cancel => @posoco.UiResponse::Cancelled
    Accept => {
      let value = acp_elicitation_value(result)
      match req {
        Input(..) =>
          match value {
            Json::String(text) => @posoco.UiResponse::Text(text)
            _ =>
              raise @posoco.UiError::IoFailure(
                detail="acp: elicitation answer must be a string",
              )
          }
        Confirm(..) =>
          match value {
            Json::True => @posoco.UiResponse::Yes
            Json::False => @posoco.UiResponse::No
            _ =>
              raise @posoco.UiError::IoFailure(
                detail="acp: elicitation answer must be a boolean",
              )
          }
        Select(prompt~, options~, default~) => {
          // prompt and default already shaped the form; only options matter.
          ignore(prompt)
          ignore(default)
          acp_select_response(options, value)
        }
      }
    }
  }
}

///|
pub impl @posoco.UiPort for AcpBridge with fn ui_descriptor(_self : AcpBridge) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
/// No-op by design: ACP v1 has no render-intent channel. The client owns
/// its own chrome; hosts that need status/toast rendering run a UI-capable
/// host (cetas-js), not an ACP stdio process.
pub impl @posoco.UiPort for AcpBridge with fn render(
  _self : AcpBridge,
  _intent : @posoco.UiRender,
) -> Unit {
  ()
}

///|
/// Ask through one `elicitation/create` form-mode reverse request. Queued
/// updates are flushed first so the client sees the pending ask_question
/// tool-call announcement (and any streamed text) before the form appears —
/// the same ordering the permission gate guarantees. A detached bridge, a
/// client without the elicitation capability, and transport failures map
/// onto the three UiError shades (Unsupported / Cancelled / IoFailure).
pub impl @posoco.UiPort for AcpBridge with fn request(
  self : AcpBridge,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse {
  match (self.context, self.session_id) {
    (Some(context), Some(session_id)) => {
      ignore(self.flush())
      let result = context.elicitation_create(
        acp_elicitation_params(session_id, req),
      ) catch {
        AgentContextUnavailable(..) =>
          raise @posoco.UiError::Unsupported(
            detail="acp: client does not support elicitation",
          )
        AgentContextCancelled(..) => raise @posoco.UiError::Cancelled
        AgentContextBrokerFailure(..) =>
          raise @posoco.UiError::IoFailure(
            detail="acp: elicitation request failed in transit",
          )
        AgentContextReplyMismatch(..) =>
          raise @posoco.UiError::IoFailure(
            detail="acp: elicitation reply did not match the request",
          )
      }
      acp_ui_response(req, result)
    }
    _ =>
      raise @posoco.UiError::Unsupported(
        detail="acp: bridge is detached from the session",
      )
  }
}
