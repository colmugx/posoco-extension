///|
/// Renders a loaded ContextBundle through a caller-selected namespace for
/// the SystemPromptContributor seam. The host passes a bare namespace (e.g.
/// "cetas"); elements render as `<{ns}-context …>`. The namespace belongs
/// to the host or product composing this extension; the context package
/// does not define one.
pub struct ContextPromptContributor {
  bundle : ContextBundle
  ns : String
}

///|
/// Construct a context contributor using the caller-owned bare namespace
/// (e.g. "cetas"). Elements render as `{ns}-context`. The value is trusted
/// host configuration and must be a valid XML name stem.
pub fn ContextPromptContributor::ContextPromptContributor(
  bundle~ : ContextBundle,
  ns~ : String,
) -> ContextPromptContributor {
  { bundle, ns }
}

// All context docs are trust="false" (untrusted): they come from the
// filesystem and may contain instructions from unknown authors. Consumers
// should interpret this flag as data provenance, not as elevated authority.

///|
/// Render one document as a `{ns}-context` element. Escaping and layout
/// live in devkit's context_envelope.
fn ContextPromptContributor::render_doc(
  self : ContextPromptContributor,
  doc : ContextDocument,
) -> String {
  @devkit.context_envelope(
    ns=self.ns,
    kind="project_instructions",
    trust=false,
    source=doc.path,
    content=doc.content,
  )
}

///|
/// SystemPromptContributor: emit all loaded context documents as parallel
/// elements using the configured namespace. Returns "" for an empty bundle
/// (no global, no ancestors) so SystemPromptHook::assemble skips this section.
pub impl @posoco.SystemPromptContributor for ContextPromptContributor with fn system_prompt(
  self : ContextPromptContributor,
) -> String {
  let buf = StringBuilder::new()
  let mut prefix = ""
  match self.bundle.global {
    Some(doc) => {
      buf.write_string(prefix)
      buf.write_string(self.render_doc(doc))
      prefix = "\n\n"
    }
    None => ()
  }
  for doc in self.bundle.ancestors {
    buf.write_string(prefix)
    buf.write_string(self.render_doc(doc))
    prefix = "\n\n"
  }
  buf.to_string()
}
