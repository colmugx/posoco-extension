///|
/// MoonBit toolchain resolution — the target-independent logic, shared by
/// native, wasm and js. The existence probing and the per-extension cache
/// live on the execution edges (`MbtxTools::ensure_toolchain` +
/// `toolchain_dir_usable`: `posoco_ext_mbtx.native.mbt` for native/wasm,
/// `posoco_ext_mbtx.js.mbt` for js, `fallback.mbt` for the rest).

///|
/// A located toolchain: `bin_dir` plus the two binaries the pipeline needs.
/// `moon` locates its own moonc/lib/core relative to its executable, so
/// handing children the right binary path is the whole job.
#warnings("-unused_field")
priv struct ResolvedToolchain {
  bin_dir : String
  moon : String
  moonrun : String
}

///|
/// Pure path-level resolution: derive the ordered candidate bin dirs
/// (explicit override, then PATH entries in order, then `~/.moon/bin`) and
/// map the first one onto a ResolvedToolchain. No existence probing here —
/// `ensure_toolchain` walks the full list with probes and caches the first
/// usable one.
#warnings("-unused_value")
fn resolve_toolchain(
  bin_override? : String? = None,
  path_env? : String? = None,
  home_dir? : String? = None,
) -> ResolvedToolchain? {
  let candidates = toolchain_candidates(bin_override~, path_env~, home_dir~)
  if candidates.length() == 0 {
    return None
  }
  Some(resolved_toolchain(candidates[0]))
}

///|
/// Ordered candidate bin directories: override first (empty string is not a
/// directory), then each PATH entry in order (":"-separated POSIX PATH;
/// empty entries are skipped), then `<home>/.moon/bin` last.
fn toolchain_candidates(
  bin_override? : String? = None,
  path_env? : String? = None,
  home_dir? : String? = None,
) -> Array[String] {
  let candidates : Array[String] = []
  match bin_override {
    Some(dir) => if dir.length() > 0 { candidates.push(dir) }
    None => ()
  }
  match path_env {
    Some(env) =>
      for entry in env.split(":") {
        let entry = entry.to_owned()
        if entry.length() > 0 {
          candidates.push(entry)
        }
      }
    None => ()
  }
  match home_dir {
    Some(home) => candidates.push("\{home}/.moon/bin")
    None => ()
  }
  candidates
}

///|
fn resolved_toolchain(bin_dir : String) -> ResolvedToolchain {
  { bin_dir, moon: "\{bin_dir}/moon", moonrun: "\{bin_dir}/moonrun", }
}

///|
/// Injection seam over `ensure_toolchain`: `path_env`/`home_dir` default to
/// the host environment in `ensure_toolchain` (per execution edge).
#warnings("-unused_value")
async fn MbtxTools::ensure_toolchain_from(
  self : MbtxTools,
  path_env~ : String?,
  home_dir~ : String?,
) -> ResolvedToolchain raise @posoco.RuntimeError {
  match self.resolved {
    Some(bin_dir) => return resolved_toolchain(bin_dir)
    None => ()
  }
  let candidates = toolchain_candidates(
    bin_override=self.toolchain_bin,
    path_env~,
    home_dir~,
  )
  for candidate in candidates {
    if toolchain_dir_usable(candidate) {
      self.cache_resolved(candidate)
      return resolved_toolchain(candidate)
    }
  }
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx: no MoonBit toolchain found: no configured override, and no usable moon on PATH or in ~/.moon/bin",
  )
}
