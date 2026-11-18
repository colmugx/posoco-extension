///|
/// Profile member extensions are deferred past the prompt layer as well as
/// the tool layer. Tool visibility is the gateway's job now — the definitions
/// stay registered and only leave the model request — so a deep-deferred view
/// strips `prompt_contributors` alone, because activation re-injects that text
/// once per profile and keeping it resident would duplicate it every turn.

///|
/// A view of an extension whose `prompt_contributors` array is emptied.
/// Everything else (id, tools, and the remaining port arrays — hooks,
/// observers, sessions, commands, ...) is copied from the wrapped extension,
/// so composition still attributes its ports to it and the gateway still sees
/// the owner's tools.
priv struct DeepDeferredView {
  inner : &@posoco.Extension
}

///|
impl @posoco.Extension for DeepDeferredView with fn extension_id(
  self : DeepDeferredView,
) -> String {
  self.inner.extension_id()
}

///|
impl @posoco.Extension for DeepDeferredView with fn manifest(
  self : DeepDeferredView,
) -> @posoco.ExtensionManifest {
  { ..self.inner.manifest(), prompt_contributors: [], }
}

///|
/// Deep-defer a host-selected set of extensions during composition. The set
/// is typically the union of loaded profiles' members; hosts can keep an
/// extension resident by leaving it out.
///
/// Returns:
/// - the stripped prompt text keyed by `extension_id`: the wrapped
///   extension's `manifest().prompt_contributors` `system_prompt()` texts,
///   concatenated in contributor order with a newline separator (empty
///   sections skipped, per the contributor contract). The host wires this
///   text into `Profiles::build` so activation can inject it; an extension
///   whose contributors produce nothing is absent from the map.
/// - the views the host must register instead of the originals: extensions
///   contributing prompt sections come back as deep-deferred views;
///   extensions without one pass through unchanged. Registering an original
///   would put its prompt back into every request.
pub fn deep_defer_extensions(
  exts~ : Array[&@posoco.Extension],
) -> (Map[String, String], Array[&@posoco.Extension]) {
  let prompts : Map[String, String] = Map::from_array([])
  let views : Array[&@posoco.Extension] = []
  for ext in exts {
    let manifest = ext.manifest()
    if manifest.prompt_contributors.length() == 0 {
      views.push(ext)
    } else {
      let mut text = ""
      for contributor in manifest.prompt_contributors {
        let section = contributor.system_prompt()
        if section.length() > 0 {
          if text.length() > 0 {
            text = text + "\n"
          }
          text = text + section
        }
      }
      if text.length() > 0 {
        prompts[ext.extension_id()] = text
      }
      views.push(DeepDeferredView::{ inner: ext, } as &@posoco.Extension)
    }
  }
  (prompts, views)
}
