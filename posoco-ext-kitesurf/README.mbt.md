# colmugx/posoco-ext-kitesurf

Cloudflare Browser Run Quick Actions using the Kitesurf engine, exposed as a Posoco ToolProvider.
Runs remotely on Cloudflare. No local browser, Node proxy, or workerd is required.

## Scope (v0.1.0)

- kitesurf_markdown: URL to Markdown text.
- kitesurf_accessibility_tree: URL to a compact JSON accessibility tree.
- Both tools use the Browser Run REST API and always append browser=kitesurf.
- Screenshot attachments and interactive CDP are intentionally out of scope for this PR.

## Installation

Run moon add colmugx/posoco-ext-kitesurf from your host module when published,
or use the source module from this repository during development.

## Usage

```moonbit nocheck
let tools = @kitesurf.KitesurfTools::KitesurfTools(
  config=@kitesurf.KitesurfConfig(
    account_id=account_id,
    api_token=api_token,
    allowed_hosts=["example.com"],
  ),
)
let agent = @posoco.Agent(
  exts=[model_ext, tools],
  config=config,
  events=@posoco.EventSystem(),
)
```

Inject credentials from host configuration or environment variables, never from tool arguments.
Create a Cloudflare API token with the Browser Run - Edit permission.

## Security and limitations

- Only http/https hostnames without embedded credentials or explicit ports are accepted.
- Public hostname validation is syntactic. For untrusted URLs, set allowed_hosts and enforce
  any additional egress/redirect policy outside this extension.
- Cloudflare errors expose status codes but not response bodies, token values or request headers.
- Output is capped by max_output_chars; results include a truncation indicator.
- The native HTTP transport currently materializes a JSON response before clipping output.
- No automatic fallback to Chromium; unsupported Kitesurf pages report errors.
- Neither persistent sessions nor interactive browser controls are provided in v0.1.

## Testing

```sh
moon check --target native
moon test --target native
moon fmt
moon info
```

White-box tests use a fake transport and do not need Cloudflare credentials.

## References

- https://developers.cloudflare.com/browser-run/kitesurf/
- https://developers.cloudflare.com/browser-run/quick-actions/markdown-endpoint/
- https://developers.cloudflare.com/browser-run/quick-actions/accessibility-tree-endpoint/