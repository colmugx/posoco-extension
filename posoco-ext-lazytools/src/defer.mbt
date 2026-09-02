///|
/// Deferring whole extensions: the gateway takes over their ToolProvider
/// views while a toolless view keeps every other port (hooks, commands,
/// memory, observers, prompt contributions) registered on the agent.

///|
/// A view of an extension whose `manifest().tools` is emptied. Everything
/// else (id and the other port arrays) is copied from the wrapped
/// extension, so composition diagnostics still attribute the extension's
/// hooks and commands to its own id.
priv struct ToollessExtView {
  inner : &@posoco.Extension
}

///|
impl @posoco.Extension for ToollessExtView with fn extension_id(
  self : ToollessExtView,
) -> String {
  self.inner.extension_id()
}

///|
impl @posoco.Extension for ToollessExtView with fn manifest(
  self : ToollessExtView,
) -> @posoco.ExtensionManifest {
  { ..self.inner.manifest(), tools: [], }
}

///|
/// Defer the tool contributions of whole extensions behind one gateway.
///
/// Returns the gateway plus, for each input extension, the view the host
/// should register instead of the original: extensions that contribute
/// tools come back as toolless views (their providers now live behind the
/// gateway), tool-free extensions pass through unchanged. The host must
/// register the views rather than the originals — pushing an original would
/// put its tools back into the model context and defeat the deferral.
///
/// Providers are indexed exactly as in `build` (one `list_tools()` call per
/// provider; a deferred name collision fails the build).
pub fn LazyTools::defer_extensions(
  exts~ : Array[&@posoco.Extension],
) -> Result[(LazyTools, Array[&@posoco.Extension]), String] {
  let providers : Array[&@posoco.ToolProvider] = []
  for ext in exts {
    for provider in ext.manifest().tools {
      providers.push(provider)
    }
  }
  match LazyTools::build(providers~) {
    Err(message) => Err(message)
    Ok(gateway) => {
      let views : Array[&@posoco.Extension] = []
      for ext in exts {
        if ext.manifest().tools.length() == 0 {
          views.push(ext)
        } else {
          views.push(ToollessExtView::{ inner: ext, } as &@posoco.Extension)
        }
      }
      Ok((gateway, views))
    }
  }
}
