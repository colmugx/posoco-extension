///|
/// Build the deferral gateway for one owner set. Deferred owners keep their
/// tool definitions in the kernel catalog and only leave the model request, so
/// the gateway needs owner ids and prompt hints — never a tool enumeration.
///
/// `extra_owners` covers groups the host registers AFTER this composition
/// (a live MCP bridge is host-owned because its transport is host-specific);
/// declaring the owner here is enough for it to be deferred when it publishes.
pub fn deferred_gateway(
  deferred~ : Array[&@posoco.Extension],
  extra_owners~ : Array[String] = [],
  hints~ : Map[String, String] = Map::from_array([]),
) -> Result[@lazytools.LazyTools, String] {
  let groups : Array[@lazytools.DeferredGroup] = []
  for ext in deferred {
    let owner = ext.extension_id()
    groups.push({
      owner,
      hint: match hints.get(owner) {
        Some(hint) => hint
        None => ""
      },
    })
  }
  for owner in extra_owners {
    let mut declared = false
    for group in groups {
      if group.owner == owner {
        declared = true
        break
      }
    }
    if !declared {
      groups.push({
        owner,
        hint: match hints.get(owner) {
          Some(hint) => hint
          None => ""
        },
      })
    }
  }
  @lazytools.LazyTools::new(groups~)
}

///|
/// One safe composition path for Posoco hosts using Profiles together with
/// LazyTools. The caller supplies the ordinary resident extensions and the
/// extensions whose tool schemas should be behind LazyTools.
///
/// The composer owns the mandatory ordering and deferral invariants:
/// - only members of loaded profiles lose their resident prompt sections;
/// - every deferred extension keeps its tool definitions registered and loses
///   only model visibility, which one LazyTools gateway declares per owner;
/// - tool provenance for usage accounting is read before any deferral;
/// - Profiles precedes the gateway in the hook chain.
///
/// The returned extensions replace BOTH input lists in Agent(exts=...).
/// Registering original deferred extensions again would expose duplicate
/// tools/prompts and is explicitly unsupported.
pub(all) struct ProfileComposition {
  exts : Array[&@posoco.Extension]
  profiles : Profiles
  deferred_ids : Array[String]
}

///|
/// Compose profile-driven progressive disclosure without requiring callers
/// to manually manufacture attribution, deep views, or gateway ordering.
///
/// Only installed, deferred members referenced by an authored manifest have
/// their manuals stripped. Other deferred extensions keep their normal
/// system-prompt contributors while their tools remain behind LazyTools.
/// The builtin 'all' includes the profile-deferred set, not unrelated tools.
pub fn compose_profiles(
  resident~ : Array[&@posoco.Extension],
  deferred~ : Array[&@posoco.Extension],
  manifests~ : Array[ProfileManifest],
  events~ : @posoco.Events? = None,
  store~ : &ProfileStore? = None,
  activation_sink~ : &ProfileActivationSink? = None,
  summarizer~ : ((Array[(String, Int32)]) -> (String, String))? = None,
  deferred_hints~ : Map[String, String] = Map::from_array([]),
  extra_deferred_owners~ : Array[String] = [],
) -> Result[ProfileComposition, String] {
  let deferred_ids : Array[String] = []
  let attribution : Map[String, String] = Map::from_array([])
  let seen_extensions : Set[String] = Set([])
  for ext in resident {
    let id = ext.extension_id()
    if seen_extensions.contains(id) {
      return Err("profiles: duplicate extension id '{id}'")
    }
    seen_extensions.insert(id)
    for provider in ext.manifest().tools {
      for tool in provider.list_tools() {
        attribution[tool.name.to_string()] = id
      }
    }
  }
  for ext in deferred {
    let id = ext.extension_id()
    if seen_extensions.contains(id) {
      return Err("profiles: duplicate extension id '{id}'")
    }
    seen_extensions.insert(id)
    for provider in ext.manifest().tools {
      for tool in provider.list_tools() {
        attribution[tool.name.to_string()] = id
      }
    }
  }
  // Preserve the extension order, not manifest order. This also ensures a
  // duplicate member listed in multiple profiles is captured only once.
  for ext in deferred {
    let id = ext.extension_id()
    let mut selected = false
    for manifest in manifests {
      if manifest.exts.contains(id) {
        selected = true
        break
      }
    }
    if selected {
      deferred_ids.push(id)
    }
  }
  let gateway = match
    deferred_gateway(
      deferred~,
      extra_owners=extra_deferred_owners,
      hints=deferred_hints,
    ) {
    Ok(gateway) => gateway
    Err(reason) => return Err(reason)
  }
  let deep : Array[&@posoco.Extension] = []
  for ext in deferred {
    if deferred_ids.contains(ext.extension_id()) {
      deep.push(ext)
    }
  }
  let (captured, deep_views) = deep_defer_extensions(exts=deep)
  let deep_by_id : Map[String, &@posoco.Extension] = Map::from_array([])
  for view in deep_views {
    deep_by_id[view.extension_id()] = view
  }
  let profiles = Profiles::build(
    manifests~,
    defer_set=deferred_ids,
    captured_prompts=captured,
    attribution~,
    events~,
    store~,
    activation_sink~,
    summarizer~,
  )
  let exts : Array[&@posoco.Extension] = []
  for ext in resident {
    exts.push(ext)
  }
  exts.push(profiles as &@posoco.Extension)
  for ext in deferred {
    match deep_by_id.get(ext.extension_id()) {
      Some(deep_view) => exts.push(deep_view)
      None => exts.push(ext)
    }
  }
  exts.push(gateway as &@posoco.Extension)
  Ok({ exts, profiles, deferred_ids, })
}
