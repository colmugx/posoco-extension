///|
/// Renders a loaded ContextBundle as <cetas-context> elements suitable for
/// the SystemPromptContributor seam.
pub struct ContextPromptContributor {
  bundle : ContextBundle
}

///|
pub fn ContextPromptContributor::new(
  bundle~ : ContextBundle,
) -> ContextPromptContributor {
  { bundle, }
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
// filesystem and may contain instructions from unknown authors. The base
// prompt teaches the model to read trust as a binary true/false flag.

///|
/// Render one document as a complete <cetas-context> element.
fn render_context(doc : ContextDocument) -> String {
  let type_ = "project_instructions"
  let trust = "false"
  let source = escape_xml(doc.path)
  let content = escape_xml(doc.content)
  "<cetas-context type=\"" +
  type_ +
  "\" trust=\"" +
  trust +
  "\" source=\"" +
  source +
  "\">\n" +
  content +
  "\n</cetas-context>"
}

///|
/// SystemPromptContributor: emit all loaded context documents as parallel
/// <cetas-context> elements. Returns "" for an empty bundle (no global, no
/// ancestors) so SystemPromptHook::assemble silently skips this section.
pub impl @posoco.SystemPromptContributor for ContextPromptContributor with fn system_prompt(
  self : ContextPromptContributor,
) -> String {
  let parts : Array[String] = []
  match self.bundle.global {
    Some(doc) => parts.push(render_context(doc))
    None => ()
  }
  for doc in self.bundle.ancestors {
    parts.push(render_context(doc))
  }
  parts.join("\n\n")
}
