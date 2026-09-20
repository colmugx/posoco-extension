///|
/// posoco-ext-profiles — profile intent packages for Posoco agents.
///
/// A profile is a named intent package: one manifest grouping related
/// extensions so the model can bring their full surface into the session in
/// a single step. Activation = append one UserMessage carrying the frozen
/// `profile <id> activated` header plus the members' stripped prompt
/// manuals (tools stay behind the lazytools gateway), and one devkit
/// EventBus event. The extension keeps ZERO in-memory activation state —
/// the transcript is the single source of truth (Q18).

///|
/// One uniform profile view. The builtin `all` and every manifest become
/// the same value shape, so lookup, enumeration, menu-free activation, and
/// injection run through one code path with no `all` special-casing (Q11).
priv struct ProfileEntry {
  id : String
  description : String
  members : Array[String]
  /// Ext ids the manifest references that were neither deep-deferred nor
  /// composed (Q13). Empty entries activate nothing extra.
  dangling : Array[String]
}

///|
/// The profiles extension. Opaque: compose via `Profiles::build`.
pub struct Profiles {
  /// Authorable manifests. Grows when `/profile save` commits a manifest —
  /// immediately visible to lookup/enumeration/activation (Q19). The
  /// builtin `all` lives outside this array but every read path unifies
  /// both through `entries()`.
  priv catalog : Array[ProfileEntry]
  /// The one program-decided builtin preset: members = the deep-deferred
  /// set. Not authorable (Q16), activated like any profile (Q11).
  priv builtin_all : ProfileEntry
  /// The composition-time deep-deferred set (the host's Q10 policy
  /// product). Fixed after build; injection coverage = defer_set ∩ members
  /// (Q19's anti-double-injection guard).
  priv defer_set : Array[String]
  /// ext_id → stripped prompt manual (the `deep_defer_extensions` product
  /// the host wires in).
  priv captured_prompts : Map[String, String]
  /// tool name → ext id — the host's composition-time static snapshot
  /// (Q15), never a usage log.
  priv attribution : Map[String, String]
  /// Load-time warnings for manifests referencing uncomposed exts (Q13).
  priv dangling_warnings : Array[String]
  priv bus : @devkit.EventBus?
  priv store : &ProfileStore?
  priv session_store : &@posoco.SessionStore?
  priv summarizer : ((Array[(String, Int)]) -> (String, String))?
  /// Composed UiPort, wired once at `on_compose` (Q17). Composition wiring,
  /// not activation state.
  priv mut ui : &@posoco.UiPort?
  /// Per-session tool usage counters: session_id → tool name → count. The
  /// input to `/profile save`. Together with `catalog` this is the ONLY
  /// mutable state; there is deliberately no activated-set field (Q18).
  priv usage : Map[String, Map[String, Int]]
}

///|
/// Compose the profiles extension. Every input is a composition-time
/// constant; nothing here touches a session. The host resolves the
/// two-level manifest directory (project overriding user, ids deduplicated)
/// before calling; the deferred set and attribution table come from the
/// same composition pass.
pub fn Profiles::build(
  manifests~ : Array[ProfileManifest],
  defer_set~ : Array[String],
  captured_prompts~ : Map[String, String],
  attribution~ : Map[String, String],
  bus? : @devkit.EventBus? = None,
  store? : &ProfileStore? = None,
  session_store? : &@posoco.SessionStore? = None,
  summarizer? : ((Array[(String, Int)]) -> (String, String))? = None,
) -> Profiles {
  let deferred = defer_set.copy()
  let catalog : Array[ProfileEntry] = []
  let warnings : Array[String] = []
  let seen : Map[String, Unit] = Map::from_array([])
  for manifest in manifests {
    // `all` is reserved (Q16) and duplicate ids collapse (first wins) — a
    // defensive guard for host merge bugs, not a policy path.
    if manifest.id == reserved_profile_id || seen.contains(manifest.id) {
      continue
    }
    seen[manifest.id] = ()
    let dangling = dangling_ext_ids(manifest.exts, deferred, attribution)
    if !dangling.is_empty() {
      warnings.push(
        "profile '\{manifest.id}' references uncomposed extensions: \{dangling.join(", ")}",
      )
    }
    catalog.push({
      id: manifest.id,
      description: manifest.description,
      members: manifest.exts.copy(),
      dangling,
    })
  }
  {
    catalog,
    builtin_all: {
      id: reserved_profile_id,
      description: ALL_PROFILE_DESCRIPTION,
      members: deferred,
      dangling: [],
    },
    defer_set: deferred,
    captured_prompts,
    attribution,
    dangling_warnings: warnings,
    bus,
    store,
    session_store,
    summarizer,
    ui: None,
    usage: Map::from_array([]),
  }
}

///|
/// All profile entries: the builtin `all` first, then the catalog in
/// manifest order (runtime saves append at the end). One list, one read
/// path — lookup, enumeration and activation never branch on `all` (Q11).
fn Profiles::entries(self : Profiles) -> Array[ProfileEntry] {
  let all : Array[ProfileEntry] = [self.builtin_all]
  for entry in self.catalog {
    all.push(entry)
  }
  all
}

///|
fn Profiles::find_entry(self : Profiles, id : String) -> ProfileEntry? {
  for entry in self.entries() {
    if entry.id == id {
      return Some(entry)
    }
  }
  None
}

///|
/// Every activatable id: `all` plus catalog ids in catalog order (Q16's
/// unknown-id enumeration).
fn Profiles::available_ids(self : Profiles) -> Array[String] {
  self.entries().map(fn(entry) { entry.id })
}

///|
/// Load-time manifest warnings (Q13): profiles referencing extensions that
/// were neither deep-deferred nor composed. Non-fatal — the menu annotates
/// the entry and activation proceeds without the missing members.
pub fn Profiles::warnings(self : Profiles) -> Array[String] {
  self.dangling_warnings.copy()
}

///|
/// Ext ids not covered by the composition: outside the deep-deferred set
/// AND absent from the attribution table's values (Q13's
/// `defer_set ∪ attribution values` membership check).
fn dangling_ext_ids(
  exts : Array[String],
  defer_set : Array[String],
  attribution : Map[String, String],
) -> Array[String] {
  exts.filter(fn(ext_id) {
    if defer_set.contains(ext_id) {
      return false
    }
    for _, value in attribution {
      if value == ext_id {
        return false
      }
    }
    true
  })
}
