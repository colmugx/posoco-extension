///|
/// One host-provided Memoh current-turn context document.
pub(all) struct MemohContext {
  uri : String
  mime_type : String
  text : String
}

///|
/// A decoded Memoh ACP prompt.
///
/// Host context and actual user content are separate by construction so the
/// adapter cannot accidentally downgrade host context into user text or merge
/// quoted host data into the user's instruction.
pub(all) struct MemohPrompt {
  context : MemohContext
  user_content : Array[@posoco.Content]
}

///|
/// Build the actual Posoco user message. The current-turn context is not
/// included here; Memoh::prepare_turn installs it for the PipelineHook.
pub fn MemohPrompt::user_message(self : MemohPrompt) -> @posoco.Message {
  @posoco.Message::UserMessage(content=self.user_content.copy())
}

///|
fn memoh_nullable_mime(value : @acp.ProtocolNullable[String]) -> String {
  match value {
    @acp.ProtocolNullable::Value(mime) => mime
    @acp.ProtocolNullable::Null | @acp.ProtocolNullable::Omitted => ""
  }
}

///|
/// Decode one ACP prompt emitted by Memoh.
///
/// V1 deliberately accepts only user text/images plus exactly one embedded
/// text resource at memoh://context/current-turn. Other ACP block kinds are
/// rejected rather than silently changing their authority or semantics.
pub fn decode_memoh_prompt(
  blocks : Array[@acp.ContentBlock],
) -> MemohPrompt raise MemohError {
  let mut context : MemohContext? = None
  let user_content : Array[@posoco.Content] = []
  for block in blocks {
    match block {
      @acp.ContentBlock::Text(text) =>
        user_content.push(@posoco.Content::Text(text.text))
      @acp.ContentBlock::Image(image) =>
        user_content.push(
          @posoco.Content::Image(
            media_type=image.mime_type,
            data=image.data,
          ),
        )
      @acp.ContentBlock::Resource(embedded) =>
        match embedded.resource {
          @acp.EmbeddedResourceResource::Text(resource) => {
            if resource.uri != MEMOH_CURRENT_TURN_URI {
              raise UnsupportedPromptBlock(
                kind="embedded resource uri " + resource.uri,
              )
            }
            if context is Some(_) {
              raise InvalidContext(reason="duplicate current-turn context")
            }
            let mime = memoh_nullable_mime(resource.mime_type)
            if mime != MEMOH_CURRENT_TURN_MIME {
              raise InvalidContext(
                reason="current-turn context must use text/markdown",
              )
            }
            if resource.text.trim().is_empty() {
              raise InvalidContext(reason="current-turn context is empty")
            }
            context = Some({
              uri: resource.uri,
              mime_type: mime,
              text: resource.text,
            })
          }
          @acp.EmbeddedResourceResource::Blob(resource) => {
            if resource.uri == MEMOH_CURRENT_TURN_URI {
              raise InvalidContext(reason="current-turn context must be text")
            }
            raise UnsupportedPromptBlock(kind="embedded blob resource")
          }
        }
      @acp.ContentBlock::Audio(_) =>
        raise UnsupportedPromptBlock(kind="audio")
      @acp.ContentBlock::ResourceLink(_) =>
        raise UnsupportedPromptBlock(kind="resource_link")
    }
  }
  match context {
    Some(value) => { context: value, user_content, }
    None => raise MissingContext
  }
}
