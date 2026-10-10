///|
test "embedded dashboard identity and manifest based public resource policy" {
  let assets = web_assets()
  for path in ["/index.html", "/index.js", "/board.css"] {
    assert_true(assets.get(path).unwrap().length() > 0)
  }
  let html = @utf8.decode(assets["/index.html"])
  assert_true(html.contains("<div id=\"app\""))
  assert_true(html.contains("/index.js"))
  assert_true(html.contains("/board.css"))
  for retired in ["Board diagnostics", "id=\"events\"", "board.cursor."] {
    assert_false(html.contains(retired))
    assert_false(@utf8.decode(assets["/index.js"]).contains(retired))
  }
  let javascript = @utf8.decode(assets["/index.js"])
  for
    lifecycle in [
      "board.attempt.queue", "board.attempt.start", "board.attempt.finish", "Choose an outcome…",
      "board.review.record", "Record review decision",
    ] {
    assert_true(javascript.contains(lifecycle))
  }
  let public_paths = board_public_asset_paths(assets)
  assert_false(public_paths.contains("/"))
  assert_false(public_paths.contains("/index.html"))
  assert_false(public_paths.contains("/missing.js"))
  assert_false(public_paths.contains("/api/bootstrap"))
  assert_false(public_paths.contains("/ws"))
  assert_true(public_paths.contains("/index.js"))
  assert_true(public_paths.contains("/board.css"))

  // Defense in depth: even a hand-built malformed manifest cannot make
  // control-plane paths public.
  let collisions : Map[String, Bytes] = {
    "/health": b"shadow",
    "/ws": b"shadow",
    "/api": b"shadow",
    "/api/bootstrap": b"shadow",
    "/api/future": b"shadow",
    "/safe.js": b"safe",
  }
  let collision_public = board_public_asset_paths(collisions)
  for path in ["/health", "/ws", "/api", "/api/bootstrap", "/api/future"] {
    assert_true(board_control_path(path))
    assert_false(collision_public.contains(path))
  }
  assert_false(board_control_path("/safe.js"))
  assert_true(collision_public.contains("/safe.js"))
}

///|
async fn board_http_raw(
  url : String,
  meth? : @http.RequestMethod = Get,
) -> (@http.Response, Bytes) {
  let (response, body) = @http.request(url, meth, {}, b"")
  (response, body.binary())
}

///|
fn board_bytes_text(bytes : Bytes) -> String {
  @utf8.decode(bytes) catch {
    _ => ""
  }
}

///|
async test "embedded static middleware cannot shadow control-plane routes" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let collisions : Map[String, Bytes] = {
        "/health": b"asset-health",
        "/ws": b"asset-ws",
        "/api": b"asset-api",
        "/api/bootstrap": b"asset-bootstrap",
        "/api/future": b"asset-future",
        "/safe.js": b"asset-safe",
      }
      let app = @moonback.App(ctx => {
        ctx.add_middleware(board_static_assets(collisions))
        ctx.get("/health", (_req, res) => res.send_text("route-health"))
        ctx.get("/ws", (_req, res) => res.send_text("route-ws"))
        ctx.get("/api", (_req, res) => res.send_text("route-api"))
        ctx.get("/api/bootstrap", (_req, res) => {
          res.send_text("route-bootstrap")
        })
        ctx.get("/api/future", (_req, res) => res.send_text("route-future"))
      })
      defer app.close()
      let listener = @moonback.listen(host="127.0.0.1", port=0)
      let endpoint : BoardEndpoint = {
        host: "127.0.0.1",
        port: listener.addr.port(),
      }
      group.spawn_bg(no_wait=true, allow_failure=true, () => app.serve(listener))
      @async.sleep(10)

      for
        (path, expected) in [
          ("/health", "route-health"),
          ("/ws", "route-ws"),
          ("/api", "route-api"),
          ("/api/bootstrap", "route-bootstrap"),
          ("/api/future", "route-future"),
        ] {
        let (response, body) = board_http_raw(endpoint.base_url() + path)
        assert_eq(response.code, 200)
        assert_eq(board_bytes_text(body), expected)
      }
      let (asset, body) = board_http_raw(endpoint.base_url() + "/safe.js")
      assert_eq(asset.code, 200)
      assert_eq(body, b"asset-safe")
    })
  })
}

///|
fn board_asset_by_suffix(suffix : String) -> (String, Bytes) raise {
  for path, content in web_assets() {
    if path.has_suffix(suffix) {
      return (path, content)
    }
  }
  fail("embedded manifest must contain a \{suffix} resource")
}

///|
async test "embedded root serves the manifest index only with the instance token" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = NativeBoardWebServer(
        backend=Some(@backend.BoardBackend::BoardBackend()),
      )
      let web : &BoardWebServer = server
      let endpoint = web.bind().unwrap()
      defer server.close()
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        let _ = web.run()
      })
      @async.sleep(10)
      let token = board_query_param(web.browser_url().unwrap(), "token").unwrap()
      let index = web_assets().get("/index.html").unwrap()
      assert_true(index.length() > 0)

      for path in ["/", "/index.html"] {
        let (response, body) = board_http_raw(
          endpoint.base_url() + path + "?token=" + token,
        )
        assert_eq(response.code, 200)
        assert_eq(
          response.headers.get("Content-Type"),
          Some("text/html; charset=utf-8"),
        )
        assert_eq(body, index)
        assert_eq(response.headers.get("Cache-Control"), Some("no-store"))
        assert_eq(
          response.headers.get("X-Content-Type-Options"),
          Some("nosniff"),
        )
        assert_false(board_bytes_text(body).contains(token))
      }

      // Missing, wrong and stale tokens never reach the embedded page.
      for
        path in [
          "/", "/index.html", "/?token=wrong", "/index.html?token=x", "/%69ndex.html",
          "/index.html/", "/nested/../index.html",
        ] {
        let (response, _) = board_http_raw(endpoint.base_url() + path)
        assert_eq(response.code, 401)
      }
    })
  })
}

///|
async test "manifest js css resources are public exact bytes with stable MIME" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = NativeBoardWebServer(
        backend=Some(@backend.BoardBackend::BoardBackend()),
      )
      let web : &BoardWebServer = server
      let endpoint = web.bind().unwrap()
      defer server.close()
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        let _ = web.run()
      })
      @async.sleep(10)

      // Every manifest resource except the root document is public byte-for-byte.
      for path, content in web_assets() {
        if path == "/index.html" {
          continue
        }
        let (response, body) = board_http_raw(endpoint.base_url() + path)
        assert_eq(response.code, 200)
        assert_eq(body, content)
      }
      let (js_path, js_bytes) = board_asset_by_suffix(".js")
      let (script, script_body) = board_http_raw(endpoint.base_url() + js_path)
      assert_eq(
        script.headers.get("Content-Type"),
        Some("text/javascript; charset=utf-8"),
      )
      assert_eq(script_body, js_bytes)
      let (css_path, css_bytes) = board_asset_by_suffix(".css")
      let (style, style_body) = board_http_raw(endpoint.base_url() + css_path)
      assert_eq(
        style.headers.get("Content-Type"),
        Some("text/css; charset=utf-8"),
      )
      assert_eq(style_body, css_bytes)

      // HEAD advertises the full length and sends an empty body.
      let (head, head_body) = board_http_raw(
        endpoint.base_url() + js_path,
        meth=Head,
      )
      assert_eq(head.code, 200)
      assert_eq(
        head.headers.get("Content-Length"),
        Some(js_bytes.length().to_string()),
      )
      assert_true(js_bytes.length() > 0)
      assert_eq(head_body, b"")
      let (root_head, root_head_body) = board_http_raw(
        endpoint.base_url() +
        "/?token=" +
        board_query_param(web.browser_url().unwrap(), "token").unwrap(),
        meth=Head,
      )
      assert_eq(root_head.code, 200)
      assert_eq(root_head_body, b"")
      let index = web_assets().get("/index.html").unwrap()
      assert_eq(
        root_head.headers.get("Content-Length"),
        Some(index.length().to_string()),
      )

      // Public assets still require the exact loopback Host.
      let tcp = @socket.Tcp::connect(
        @socket.Addr::parse(board_expected_host(endpoint)),
      )
      defer tcp.close()
      tcp.write(
        "GET \{js_path} HTTP/1.1\r\nHost: evil.invalid\r\nConnection: close\r\n\r\n",
      )
      let raw = tcp.read_until("\r\n\r\n").unwrap()
      assert_true(raw.has_prefix("HTTP/1.1 403"))
      assert_true(raw.contains("no-store"))
      assert_true(raw.contains("nosniff"))
    })
  })
}

///|
async test "unknown resources 404 with a token while health stays public and gates hold" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = NativeBoardWebServer(
        backend=Some(@backend.BoardBackend::BoardBackend()),
      )
      let web : &BoardWebServer = server
      let endpoint = web.bind().unwrap()
      defer server.close()
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        let _ = web.run()
      })
      @async.sleep(10)
      let token = board_query_param(web.browser_url().unwrap(), "token").unwrap()

      // With a valid token an unknown path falls through the static
      // middleware and routes into MoonBack's 404, still with the security
      // headers. Without a token the security middleware answers first:
      // unknown paths are not on the public manifest, so they stay 401.
      for path in ["/missing.js", "/deep/nested.js", "/missing/index.html"] {
        let (response, _) = board_http_raw(
          endpoint.base_url() + path + "?token=" + token,
        )
        assert_eq(response.code, 404)
        assert_eq(response.headers.get("Cache-Control"), Some("no-store"))
        assert_eq(
          response.headers.get("X-Content-Type-Options"),
          Some("nosniff"),
        )
        let (denied, _) = board_http_raw(endpoint.base_url() + path)
        assert_eq(denied.code, 401)
      }

      let (health, health_body) = board_http_raw(
        endpoint.base_url() + "/health",
      )
      assert_eq(health.code, 200)
      assert_eq(@json.parse(board_bytes_text(health_body)), {
        "ok": true,
        "service": "posoco-ext-board",
      })
      let (api_denied, _) = board_http_raw(
        endpoint.base_url() + "/api/bootstrap",
      )
      assert_eq(api_denied.code, 401)
      let (api, api_body) = board_http_raw(
        endpoint.base_url() + "/api/bootstrap?token=" + token,
      )
      assert_eq(api.code, 200)
      assert_eq(@json.parse(board_bytes_text(api_body)), {
        "protocol_version": 1,
        "host": "127.0.0.1",
        "port": endpoint.port.to_json(),
        "ws_path": "/ws",
      })
      // The embedded page never leaks the instance secret either.
      let (root, root_body) = board_http_raw(
        endpoint.base_url() + "/?token=" + token,
      )
      assert_eq(root.code, 200)
      assert_false(board_bytes_text(root_body).contains(token))
    })
  })
}
