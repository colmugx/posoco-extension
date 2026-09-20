# posoco-ext-jev

TypeSafe Jev `DecisionPort` provider for Posoco.

The extension is intentionally thin: it translates Posoco's provider-neutral
`DecisionRequest` protocol to Jev's hosted System One API and translates the
typed response back. It does not know about LazyTools, Skills, model routing,
permission policy, thresholds, or authority.

## Mapping

| Posoco | Jev |
|---|---|
| `DecisionQuestion::Boolean` | `noul` |
| `DecisionQuestion::Choice` | `choice` |
| `DecisionQuestion::Score` | `score` |
| `DecisionRequest.state` | `state` |
| `DecisionResult.model` | resolved Jev model |
| `DecisionUsage` | Jev input/output token usage |

All questions in one `DecisionRequest` are sent in one Jev request and share
the same state.

## Usage

```moonbit nocheck
let decision = @jev.JevDecisionPort(
  @jev.JevConfig(System::get_env("TYPESAFE_API_KEY")),
)

let agent = @posoco.Agent::new([
  model_extension,
  decision,
  lazytools,
  skills,
  permission,
])
```

The host should omit this extension entirely when no Decision provider is
configured. Posoco and DecisionPort consumers continue to work without one.

Defaults:

- base URL: `https://api.typesafe.ai`
- endpoint: `/v1/systemone`
- model: `jev-latest`
- timeout: 30 seconds

## Failure semantics

- invalid Posoco requests or Jev-incompatible Boolean criteria:
  `DecisionError::InvalidRequest`
- request construction/provider HTTP 400: `DecisionError::RequestBuild`
- HTTP 429: `DecisionError::RateLimited`
- other transport/non-2xx failures: `DecisionError::Transport`
- malformed successful responses: `DecisionError::ResponseParse`

Consumers remain responsible for fallback and for mapping probabilities into
their own deterministic policy.
