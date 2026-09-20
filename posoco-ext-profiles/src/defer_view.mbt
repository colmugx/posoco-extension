///|
/// Deep deferral (Q9/F2): profiles' member extensions are deferred past the
/// prompt layer as well as the tool layer. lazytools' toolless views keep an
/// extension's prompt contributions resident; a deep-deferred view strips
/// BOTH `tools` and `prompt_contributors`, because activation re-injects the
/// stripped prompt text once per profile — keeping it resident would
/// duplicate it in every turn (F2's double-injection trap).

///|
/// A view of an extension whose `tools` and `prompt_contributors` arrays are
/// emptied. Everything else (id and the remaining port arrays — hooks,
/// observers, sessions, commands, ...) is copied from the wrapped extension,
/// so composition still attributes the extension's other ports to it.
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
  { ..self.inner.manifest(), tools: [], prompt_contributors: [], }
}

///|
/// Deep-defer a set of extensions during composition (Q10/Q19: the deferred
/// set is the host's policy — typically the union of loaded profiles' exts;
/// hosts may additionally protect never-defer extensions by not passing them
/// here).
///
/// Returns:
/// - the stripped prompt text keyed by `extension_id`: the wrapped
///   extension's `manifest().prompt_contributors` `system_prompt()` texts,
///   concatenated in contributor order with a newline separator (empty
///   sections skipped, per the contributor contract). The host wires this
///   text into `Profiles::build` so activation can inject it; an extension
///   whose contributors produce nothing is absent from the map.
/// - the views the host must register instead of the originals: extensions
///   contributing tools OR prompt sections come back as deep-deferred
///   views; extensions with neither pass through unchanged. Registering an
///   original would put its tools and prompt back into every request and
///   defeat the deferral.
pub fn deep_defer_extensions(
  exts~ : Array[&@posoco.Extension],
) -> (Map[String, String], Array[&@posoco.Extension]) {
  let prompts : Map[String, String] = Map::from_array([])
  let views : Array[&@posoco.Extension] = []
  for ext in exts {
    let manifest = ext.manifest()
    if manifest.tools.length() == 0 &&
      manifest.prompt_contributors.length() == 0 {
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
