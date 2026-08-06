///|
/// Renders a loaded ContextBundle through a caller-selected XML envelope for
/// the SystemPromptContributor seam. The envelope name belongs to the host or
/// product composing this extension; the context package does not define one.
pub struct ContextPromptContributor {
  bundle : ContextBundle
  envelope : String
}

///|
/// Construct a context contributor using the caller-owned envelope element
/// name. The value is trusted host configuration and must be a valid XML
/// element name.
pub fn ContextPromptContributor::new(
  bundle~ : ContextBundle,
  envelope~ : String,
) -> ContextPromptContributor {
  { bundle, envelope }
}

///|
/// XML-escape text content so file contents cannot break out of the
/// envelope or inject attributes. Applied to both content and the source
/// path (paths are filesystem-controlled but escape defensively).
fn escape_xml(s : String) -> String {
  s
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&apos;")
}

// All context docs are trust="false" (untrusted): they come from the
// filesystem and may contain instructions from unknown authors. Consumers
// should interpret this flag as data provenance, not as elevated authority.

///|
/// Render one document using the configured envelope element.
fn ContextPromptContributor::render_context(
  self : ContextPromptContributor,
  doc : ContextDocument,
) -> String {
  let type_ = "project_instructions"
  let trust = "false"
  let source = escape_xml(doc.path)
  let content = escape_xml(doc.content)
  "<" +
  self.envelope +
  " type=\"" +
  type_ +
  "\" trust=\"" +
  trust +
  "\" source=\"" +
  source +
  "\">\n" +
  content +
  "\n</" +
  self.envelope +
  ">"
}

///|
/// SystemPromptContributor: emit all loaded context documents as parallel
/// elements using the configured envelope. Returns "" for an empty bundle
/// (no global, no ancestors) so SystemPromptHook::assemble skips this section.
pub impl @posoco.SystemPromptContributor for ContextPromptContributor with fn system_prompt(
  self : ContextPromptContributor,
) -> String {
  let parts : Array[String] = []
  match self.bundle.global {
    Some(doc) => parts.push(self.render_context(doc))
    None => ()
  }
  for doc in self.bundle.ancestors {
    parts.push(self.render_context(doc))
  }
  parts.join("\n\n")
}
