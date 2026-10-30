///|
/// Board control-plane paths are reserved from the embedded static namespace.
/// Keep the whole `/api` namespace reserved for future authenticated HTTP APIs.
fn board_control_path_view(path : StringView) -> Bool {
  path == "/health" ||
  path == "/ws" ||
  path == "/api" ||
  path.has_prefix("/api/")
}

///|
fn board_control_path(path : String) -> Bool {
  board_control_path_view(path[:])
}

///|
/// Public static paths come from the actual embedded manifest. `/index.html`
/// and `/` stay token-gated, while control-plane paths are never public even
/// if a malformed or hand-built asset map contains a collision.
fn board_public_asset_paths(assets : Map[String, Bytes]) -> Set[String] {
  Set::from_iter(
    assets
    .keys()
    .filter(path => {
      path != "/" && path != "/index.html" && !board_control_path(path)
    }),
  )
}

///|
/// Static resources must never shadow Board control-plane routes. The asset
/// generator rejects these collisions too; this runtime guard is intentional
/// defense in depth for hand-built or stale manifests.
fn board_static_assets(assets : Map[String, Bytes]) -> @moonback.Middleware {
  let resources = @static.from_assets(assets, rewrite_trailing_slash_index=true)
  @moonback.Middleware(next => {
    let serve = (resources.0)(next)
    (req, res) => {
      if board_control_path_view(req.path) {
        next(req, res)
      } else {
        serve(req, res)
      }
    }
  })
}

