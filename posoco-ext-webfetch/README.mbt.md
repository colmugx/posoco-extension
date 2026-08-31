# posoco-ext-webfetch

> **Targets: native + js (bun) — full tool.**

URL fetch as a `ToolProvider` for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents: fetches an
http/https URL and returns LLM-optimized markdown — HTML is converted,
text/markdown/JSON pass through, and long pages are paged with a resumable
`offset` instead of flooding the context.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `ToolProvider` | the `webfetch` tool, declared with `ExecutionPolicy::Parallel` (inert on wasm) |
| `SystemPromptContributor` | continuation steering: re-fetch cross-host redirect targets, resume truncated pages with `offset` |
| `Extension` | composes into `Agent(exts=[...])` |

## Usage

```bash
moon add colmugx/posoco-ext-webfetch
```

```mbt nocheck
// moon.pkg: "colmugx/posoco-ext-webfetch" @webfetch

let webfetch = @webfetch.WebFetchTools()
// or the host factory: real clock in the document cache + default @http transport
let webfetch = @webfetch.webfetch_extension()
let agent = @posoco.Agent(exts=[webfetch, ..other_extensions], config~)
```

Both constructors take the same knobs (all optional): `timeout_ms` per fetch
(redirect hops included, default 30 000), `max_chars` returned per call
(default 50 000), `byte_cap` per raw download (default 5 MB), `cache`
(a `DocCache`; default built in), and `io` (an `HttpIo` override for tests
and hosts with custom transports).

`webfetch` is read-only and rides the **read class** of
`posoco-ext-permission`'s default policy.

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `url` | string, required | Absolute http/https URL, at most 2000 characters |
| `offset` | int | Character offset to continue a truncated result from (given in the footer of the previous page) |

## Output

A successful call is a three-part text document, plus a structured payload
(`url_requested`, `url_final`, `status`, `content_type`, `bytes_fetched`,
`chars_total`, `chars_returned`, `offset`, `truncated`, `elapsed_ms`,
`cached`) for observers/UIs:

```text
Title: <page title>
URL: <final URL after redirects>
Content-Type: <server content-type>

<markdown body>

… [showing characters 0–50000 of 83211; call webfetch with offset=50000 to continue]
```

The footer appears only when the body was truncated; a follow-up call with
`offset=<end>` resumes from the cached conversion without re-fetching.

## Content handling

- **HTML** is converted to markdown: headings, paragraphs, links, ordered and
  unordered lists, tables, code blocks and inline code, blockquotes, and
  bold/italic are preserved; boilerplate and scripts (`script`, `style`,
  `nav`, `header`, `footer`, `aside`, `form`, `head`, and more) are dropped;
  `<img>` contributes only its `alt` text; relative links are absolutized
  against the final URL. The title comes from `<title>`, then `og:title`,
  then the first `<h1>`, then the URL's last path segment.
- **`text/markdown`, `text/plain`, `application/json`** (including `+json`
  subtypes) pass through unchanged, titled from the final URL.
- Any other content type is a model-visible error naming the type.
- Content negotiation prefers ready-made markdown: the request sends
  `Accept: text/markdown;q=1.0, text/plain;q=0.9, application/json;q=0.9,
  text/html;q=0.8, */*;q=0.1` and identifies as
  `User-Agent: posoco-webfetch/0.1 (+https://github.com/colmugx/posoco)`.

## Redirects

Same-host redirects (same scheme, host, and port) are followed automatically,
at most 5 hops, with every hop's host re-checked against the guard below. A
redirect to a **different host** is not followed: the result is a success
naming the target so the model decides whether to trust it —

```text
Redirect: https://a.example/x redirects to https://b.example/y (different host; not followed automatically for safety). If you trust this target, call webfetch with url=https://b.example/y.
```

## Safety: SSRF guard

Every URL — including every redirect target, before any request is made — is
checked lexically. Blocked:

- `localhost`, and hosts ending in `.localhost`, `.local`, `.internal`
- IPv4 loopback (`127/8`), private (`10/8`, `172.16/12`, `192.168/16`),
  link-local (`169.254/16`), and unspecified (`0/8`) ranges
- IPv6 loopback `::1`, unspecified `::`, link-local `fe80::/10`, unique-local
  `fc00::/7`, and IPv4-embedded forms (re-checked against the IPv4 ranges)
- Nonstandard numeric host spellings a resolver would still accept: hex
  (`0x7f000001`) and `inet_aton` short forms (`127.1`, `2130706433`)

This is a **literal** guard: bare intranet names (`db01`) resolve on the
host's network, and DNS rebinding is not defended — see boundaries below.

## Caching

Converted documents are cached per **requested** URL: LRU with capacity 50
and a 15-minute TTL, so paged reads (`offset`) slice the cache instead of
re-fetching. `webfetch_extension()` injects the real clock; a directly
constructed `WebFetchTools` defaults to a constant-zero clock, so its cache
entries never expire.

## Known boundaries

- **No JavaScript rendering** — SPA shell pages come back as their empty
  HTML; use a source that serves static content.
- **No `robots.txt` enforcement** — the caller owns politeness.
- **No PDF or image content** — unsupported content types are reported, not
  extracted.
- **No DNS-rebinding defense** — only literal host names are blocked (see
  above); behind a hostile resolver, enforce egress policy at the network
  layer.
