///|
/// planning.mbt — typed protocol planning for the Magpie gateway.
///
/// Given one catalog entry, the requested functionality, a caller protocol
/// preference, an explicit gateway-translation policy, and the resulting
/// fidelity picture, `plan_protocol` produces a structured execution plan
/// for one of the three protocols — or an explicit incompatibility. It is a
/// pure function of its inputs: identical inputs always yield an identical
/// plan, and the future execution layer can consume the plan without
/// reimplementing protocol selection.
///
/// Evidence discipline (three tiers, never mixed):
/// - `ProtocolNative` — inherent to the protocol shape itself.
/// - `GatewayLevel` — the gateway converts, semantics may be lossy.
/// - `Unknown` — no evidence either way; absence of `native_endpoints` is
///   unknown, never an explicit prohibition.
///
/// Missing metadata never fabricates support: prompt caching and signed
/// thinking are protocol-native only through a declared native Anthropic
/// Messages endpoint, and routing groups never inherit one — their upstream
/// members may change between requests.

///|
/// Requested functionality for one planning decision.
pub(all) struct MagpieRequirements {
  tools : Bool
  streaming : Bool
  images : Bool
  reasoning_output : Bool
  signed_thinking_replay : Bool
  /// Exact effort string required; `None` = no effort requirement.
  reasoning_effort : String?
  native_prompt_caching : Bool
  token_usage_integrity : Bool
  cancellation : Bool
} derive(Eq, Debug)

///|
pub extend MagpieRequirements with Eq::{not_equal, equal}

///|
pub extend MagpieRequirements with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn MagpieRequirements::MagpieRequirements(
  tools~ : Bool = false,
  streaming~ : Bool = false,
  images~ : Bool = false,
  reasoning_output~ : Bool = false,
  signed_thinking_replay~ : Bool = false,
  reasoning_effort~ : String? = None,
  native_prompt_caching~ : Bool = false,
  token_usage_integrity~ : Bool = false,
  cancellation~ : Bool = false,
) -> MagpieRequirements {
  {
    tools,
    streaming,
    images,
    reasoning_output,
    signed_thinking_replay,
    reasoning_effort,
    native_prompt_caching,
    token_usage_integrity,
    cancellation,
  }
}

///|
/// Gateway translation policy. Lossy translation is only ever chosen when
/// the caller names it here explicitly.
pub(all) enum MagpieTranslationPolicy {
  /// Only endpoints the gateway declares native for the model; a required
  /// feature that cannot be guaranteed yields an explicit incompatibility.
  NativeOnly
  /// Gateway-translated execution is acceptable even when fidelity is not
  /// guaranteed; the plan keeps the risks visible and is marked lossy.
  AllowTranslated
} derive(Eq, Debug)

///|
pub extend MagpieTranslationPolicy with Eq::{not_equal, equal}

///|
pub extend MagpieTranslationPolicy with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieTranslationPolicy with fn to_string(
  self : MagpieTranslationPolicy,
) -> String {
  match self {
    NativeOnly => "NativeOnly"
    AllowTranslated => "AllowTranslated"
  }
}

///|
pub extend MagpieTranslationPolicy with Show::{to_string, output}

///|
/// Caller protocol preference.
pub(all) enum MagpiePreference {
  /// No preference; selection follows the default rules.
  Any
  /// Prefer this protocol whenever it is eligible.
  Prefer(MagpieProtocol)
} derive(Eq, Debug)

///|
pub extend MagpiePreference with Eq::{not_equal, equal}

///|
pub extend MagpiePreference with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The fidelity features planning reasons about, in the fixed order used
/// by every capability list.
pub(all) enum MagpieFeature {
  Tools
  Streaming
  Images
  ReasoningOutput
  SignedThinkingReplay
  ReasoningEffort
  NativePromptCaching
  TokenUsageIntegrity
  Cancellation
} derive(Eq, Debug)

///|
pub extend MagpieFeature with Eq::{not_equal, equal}

///|
pub extend MagpieFeature with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieFeature with fn to_string(self : MagpieFeature) -> String {
  match self {
    Tools => "tools"
    Streaming => "streaming"
    Images => "images"
    ReasoningOutput => "reasoning output"
    SignedThinkingReplay => "signed thinking replay"
    ReasoningEffort => "reasoning effort"
    NativePromptCaching => "native prompt caching"
    TokenUsageIntegrity => "token usage integrity"
    Cancellation => "cancellation"
  }
}

///|
pub extend MagpieFeature with Show::{to_string, output}

///|
/// Where a capability's evidence comes from.
pub(all) enum MagpieCapabilitySource {
  /// Inherent to the protocol shape itself.
  ProtocolNative
  /// Explicitly declared by the catalog for this model.
  CatalogDeclared
  /// The gateway converts; semantics may be lossy.
  GatewayLevel
  /// No evidence either way.
  Unknown
} derive(Eq, Debug)

///|
pub extend MagpieCapabilitySource with Eq::{not_equal, equal}

///|
pub extend MagpieCapabilitySource with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieCapabilitySource with fn to_string(
  self : MagpieCapabilitySource,
) -> String {
  match self {
    ProtocolNative => "ProtocolNative"
    CatalogDeclared => "CatalogDeclared"
    GatewayLevel => "GatewayLevel"
    Unknown => "Unknown"
  }
}

///|
pub extend MagpieCapabilitySource with Show::{to_string, output}

///|
pub(all) enum MagpieCapabilityStatus {
  /// Usable with the stated source.
  Available
  /// Ruled out by declared facts.
  Unsupported
} derive(Eq, Debug)

///|
pub extend MagpieCapabilityStatus with Eq::{not_equal, equal}

///|
pub extend MagpieCapabilityStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieCapabilityStatus with fn to_string(
  self : MagpieCapabilityStatus,
) -> String {
  match self {
    Available => "Available"
    Unsupported => "Unsupported"
  }
}

///|
pub extend MagpieCapabilityStatus with Show::{to_string, output}

///|
/// One evaluated feature for one protocol.
pub(all) struct MagpieCapability {
  feature : MagpieFeature
  status : MagpieCapabilityStatus
  source : MagpieCapabilitySource
  detail : String
} derive(Eq, Debug)

///|
pub extend MagpieCapability with Eq::{not_equal, equal}

///|
pub extend MagpieCapability with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Evaluation of one protocol against one catalog entry: its native
/// evidence, per-feature capabilities, declared blockers (facts no
/// translation can repair), and risks. The three protocols are evaluated
/// independently by `evaluate_protocol`; `plan_protocol` composes them.
pub(all) struct MagpieProtocolEvaluation {
  protocol : MagpieProtocol
  /// Declared native endpoint path, when the catalog declares one for a
  /// non-routing-group model.
  native_path : String?
  capabilities : Array[MagpieCapability]
  /// Required features ruled out by declared facts; no policy can repair
  /// these.
  hard_blockers : Array[String]
  /// Required features with no guarantee under this protocol; policy
  /// decides whether they are acceptable.
  unguaranteed : Array[String]
  risks : Array[String]
} derive(Eq, Debug)

///|
pub extend MagpieProtocolEvaluation with Eq::{not_equal, equal}

///|
pub extend MagpieProtocolEvaluation with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
/// How the selected endpoint will actually be reached.
pub(all) enum MagpieEndpointKind {
  /// The gateway declares this protocol natively for this model.
  Native
  /// Execution passes through gateway translation or dynamic routing.
  GatewayTranslated
} derive(Eq, Debug)

///|
pub extend MagpieEndpointKind with Eq::{not_equal, equal}

///|
pub extend MagpieEndpointKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieEndpointKind with fn to_string(
  self : MagpieEndpointKind,
) -> String {
  match self {
    Native => "Native"
    GatewayTranslated => "GatewayTranslated"
  }
}

///|
pub extend MagpieEndpointKind with Show::{to_string, output}

///|
/// Confidence of the selected plan.
pub(all) enum MagpiePlanConfidence {
  /// Backed by a declared native endpoint on a concrete model.
  DeclaredNative
  /// No native declaration; viability inferred from model-level evidence.
  Inferred
} derive(Eq, Debug)

///|
pub extend MagpiePlanConfidence with Eq::{not_equal, equal}

///|
pub extend MagpiePlanConfidence with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpiePlanConfidence with fn to_string(
  self : MagpiePlanConfidence,
) -> String {
  match self {
    DeclaredNative => "DeclaredNative"
    Inferred => "Inferred"
  }
}

///|
pub extend MagpiePlanConfidence with Show::{to_string, output}

///|
/// A structured execution plan for one protocol. Pure output: the future
/// execution layer consumes this without re-deriving protocol selection.
pub(all) struct MagpieProtocolPlan {
  model_id : String
  protocol : MagpieProtocol
  /// Declared native path, when the selection is endpoint-native.
  endpoint_path : String?
  kind : MagpieEndpointKind
  confidence : MagpiePlanConfidence
  /// Requested features, in the fixed feature order.
  capabilities : Array[MagpieCapability]
  risks : Array[String]
  /// Explicit requirement rejections that made other protocols ineligible.
  unsupported : Array[String]
  /// Why this protocol was selected.
  reasons : Array[String]
  /// True only when the caller explicitly opted into lossy translation.
  lossy_opt_in : Bool
} derive(Eq, Debug)

///|
pub extend MagpieProtocolPlan with Eq::{not_equal, equal}

///|
pub extend MagpieProtocolPlan with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Per-protocol blockers of an incompatibility.
pub(all) struct MagpieProtocolBlocker {
  protocol : MagpieProtocol
  reasons : Array[String]
} derive(Eq, Debug)

///|
pub extend MagpieProtocolBlocker with Eq::{not_equal, equal}

///|
pub extend MagpieProtocolBlocker with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Explicit incompatibility: no protocol satisfies the requirements under
/// the given policy. The message names each protocol's blockers, so hosts
/// can phrase recovery precisely.
pub(all) struct MagpieIncompatibility {
  model_id : String
  requirements : MagpieRequirements
  policy : MagpieTranslationPolicy
  blockers : Array[MagpieProtocolBlocker]
} derive(Eq, Debug)

///|
pub extend MagpieIncompatibility with Eq::{not_equal, equal}

///|
pub extend MagpieIncompatibility with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) enum MagpiePlanOutcome {
  Planned(MagpieProtocolPlan)
  Incompatible(MagpieIncompatibility)
} derive(Eq, Debug)

///|
pub extend MagpiePlanOutcome with Eq::{not_equal, equal}

///|
pub extend MagpiePlanOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The fixed evaluation order of requested features.
fn feature_order() -> Array[MagpieFeature] {
  [
    Tools,
    Streaming,
    Images,
    ReasoningOutput,
    SignedThinkingReplay,
    ReasoningEffort,
    NativePromptCaching,
    TokenUsageIntegrity,
    Cancellation,
  ]
}

///|
/// Evaluates one protocol independently against a catalog entry. Pure:
/// identical inputs yield identical evaluations.
pub fn evaluate_protocol(
  entry : MagpieCatalogEntry,
  protocol : MagpieProtocol,
  requirements~ : MagpieRequirements,
) -> MagpieProtocolEvaluation {
  let meta = entry.meta
  // Routing groups resolve members at request time: native declarations
  // never extend to them, whatever the catalog says.
  let declared_native = if meta.is_routing_group {
    None
  } else {
    meta.native_path_for(protocol)
  }
  let translated = declared_native is None
  let capabilities : Array[MagpieCapability] = []
  let hard_blockers : Array[String] = []
  let unguaranteed : Array[String] = []
  let risks : Array[String] = []
  if meta.is_routing_group {
    risks.push(
      "routing group resolves upstream members per request; native protocol guarantees cannot extend to the group",
    )
  } else if declared_native is None {
    risks.push(
      "no native \{protocol} endpoint declared; missing metadata is unknown, not a prohibition",
    )
  }
  if meta.context_window is None && meta.context_length is None {
    risks.push("input context size is unknown for this model")
  }
  for feature in feature_order() {
    let requested = match feature {
      Tools => requirements.tools
      Streaming => requirements.streaming
      Images => requirements.images
      ReasoningOutput => requirements.reasoning_output
      SignedThinkingReplay => requirements.signed_thinking_replay
      ReasoningEffort => requirements.reasoning_effort is Some(_)
      NativePromptCaching => requirements.native_prompt_caching
      TokenUsageIntegrity => requirements.token_usage_integrity
      Cancellation => requirements.cancellation
    }
    if !requested {
      continue
    }
    match feature {
      Tools =>
        capabilities.push(
          transport_capability(
            feature, translated, "all three protocols define tool calling",
          ),
        )
      Streaming =>
        capabilities.push(
          transport_capability(
            feature, translated, "all three protocols stream natively",
          ),
        )
      Cancellation =>
        capabilities.push(
          transport_capability(
            feature, translated, "cancellation closes the active stream or request",
          ),
        )
      TokenUsageIntegrity =>
        if translated {
          capabilities.push({
            feature,
            status: Available,
            source: GatewayLevel,
            detail: "usage blocks exist in every protocol, but the conversion is gateway-level",
          })
          risks.push(
            "token usage integrity: cache creation/read accounting may not survive gateway translation",
          )
        } else {
          capabilities.push({
            feature,
            status: Available,
            source: ProtocolNative,
            detail: "the native endpoint reports usage in protocol shape",
          })
        }
      Images =>
        match meta.modalities_input {
          Some(inputs) =>
            if inputs.contains("image") {
              capabilities.push({
                feature,
                status: Available,
                source: CatalogDeclared,
                detail: "catalog declares image input",
              })
            } else {
              capabilities.push({
                feature,
                status: Unsupported,
                source: CatalogDeclared,
                detail: "catalog declares text-only input",
              })
              hard_blockers.push(
                "images required but the catalog declares text-only input",
              )
            }
          None => {
            capabilities.push({
              feature,
              status: Available,
              source: Unknown,
              detail: "input modalities are not declared",
            })
            unguaranteed.push(
              "images required but input modalities are not declared",
            )
            risks.push("image support is unknown; modalities are not declared")
          }
        }
      ReasoningOutput =>
        match meta.reasoning_declared {
          Some(true) =>
            capabilities.push({
              feature,
              status: Available,
              source: CatalogDeclared,
              detail: "catalog declares reasoning support",
            })
          Some(false) => {
            capabilities.push({
              feature,
              status: Unsupported,
              source: CatalogDeclared,
              detail: "catalog declares reasoning disabled",
            })
            hard_blockers.push(
              "reasoning output required but the catalog declares reasoning disabled",
            )
          }
          None => {
            capabilities.push({
              feature,
              status: Available,
              source: Unknown,
              detail: "reasoning support is not declared",
            })
            unguaranteed.push(
              "reasoning output required but reasoning is not declared",
            )
          }
        }
      ReasoningEffort =>
        match requirements.reasoning_effort {
          None => ()
          Some(effort) =>
            match meta.reasoning_levels {
              Some(levels) =>
                if levels.contains(effort) {
                  capabilities.push({
                    feature,
                    status: Available,
                    source: CatalogDeclared,
                    detail: "catalog advertises effort \"\{effort}\"",
                  })
                } else {
                  capabilities.push({
                    feature,
                    status: Unsupported,
                    source: CatalogDeclared,
                    detail: "advertised efforts are \{levels.join(", ")}",
                  })
                  hard_blockers.push(
                    "effort \"\{effort}\" required but not in the advertised levels \{levels.join(", ")}",
                  )
                }
              None => {
                capabilities.push({
                  feature,
                  status: Available,
                  source: Unknown,
                  detail: "no effort levels are advertised; the requested effort stays unverified",
                })
                unguaranteed.push(
                  "effort \"\{effort}\" required but no levels are advertised",
                )
                risks.push(
                  "reasoning effort \"\{effort}\" cannot be verified against advertised levels",
                )
              }
            }
        }
      SignedThinkingReplay =>
        if protocol is Messages && declared_native is Some(_) {
          capabilities.push({
            feature,
            status: Available,
            source: ProtocolNative,
            detail: "Anthropic Messages carries thinking blocks natively on the declared endpoint",
          })
        } else if protocol is Messages {
          capabilities.push({
            feature,
            status: Available,
            source: GatewayLevel,
            detail: "Messages shape carries thinking blocks, but no native endpoint is declared",
          })
          unguaranteed.push(
            "signed thinking replay has no declared native Messages endpoint",
          )
          risks.push(
            "signed thinking replay through gateway translation may not preserve thinking signatures",
          )
        } else {
          capabilities.push({
            feature,
            status: Available,
            source: Unknown,
            detail: "no protocol-native signed-thinking evidence for \{protocol}",
          })
          unguaranteed.push(
            "signed thinking replay is protocol-native only via Anthropic Messages",
          )
        }
      NativePromptCaching =>
        if protocol is Messages && declared_native is Some(_) {
          capabilities.push({
            feature,
            status: Available,
            source: ProtocolNative,
            detail: "native Messages applies cache_control markers over a stable prefix",
          })
        } else {
          capabilities.push({
            feature,
            status: Available,
            source: Unknown,
            detail: "prompt caching has no protocol-native evidence outside a declared native Messages endpoint",
          })
          unguaranteed.push(
            "native prompt caching requires a declared native Messages endpoint",
          )
          risks.push(
            "gateway translation must not be assumed to preserve cache_control semantics or prefix stability",
          )
        }
    }
  }
  {
    protocol,
    native_path: declared_native,
    capabilities,
    hard_blockers,
    unguaranteed,
    risks,
  }
}

///|
/// Shared shape for features every protocol carries natively: native on a
/// declared endpoint, gateway-level when translated.
fn transport_capability(
  feature : MagpieFeature,
  translated : Bool,
  native_detail : String,
) -> MagpieCapability {
  if translated {
    {
      feature,
      status: Available,
      source: GatewayLevel,
      detail: "\{native_detail}; the conversion is gateway-level",
    }
  } else {
    {
      feature,
      status: Available,
      source: ProtocolNative,
      detail: native_detail,
    }
  }
}

///|
/// Plans the best execution for one catalog entry: evaluates all three
/// protocols independently, applies the translation policy and caller
/// preference, and either returns a structured plan or an explicit
/// incompatibility with per-protocol blockers.
///
/// Selection rules, in priority order and all deterministic:
/// 1. Protocols with declared-fact blockers are never eligible; no policy
///    repairs declared facts.
/// 2. `NativeOnly` accepts only declared-native endpoints and only plans
///    that guarantee every required feature; `AllowTranslated` accepts the
///    rest with risks visible (the explicit lossy opt-in).
/// 3. When signed thinking or native prompt caching is required and a
///    declared native Messages endpoint exists, that protocol wins.
/// 4. Otherwise the caller preference wins among eligible protocols.
/// 5. Remaining ties prefer declared-native endpoints, then the stable
///    protocol order Messages, Responses, ChatCompletions.
pub fn plan_protocol(
  entry : MagpieCatalogEntry,
  requirements~ : MagpieRequirements,
  preference~ : MagpiePreference = Any,
  policy~ : MagpieTranslationPolicy = NativeOnly,
) -> MagpiePlanOutcome {
  let evaluations = [
    evaluate_protocol(entry, Messages, requirements~),
    evaluate_protocol(entry, Responses, requirements~),
    evaluate_protocol(entry, ChatCompletions, requirements~),
  ]
  let eligible : Array[MagpieProtocolEvaluation] = []
  let unsupported : Array[String] = []
  let blockers : Array[MagpieProtocolBlocker] = []
  for evaluation in evaluations {
    if evaluation.hard_blockers.length() > 0 {
      for reason in evaluation.hard_blockers {
        unsupported.push("\{evaluation.protocol}: \{reason}")
      }
      blockers.push({
        protocol: evaluation.protocol,
        reasons: evaluation.hard_blockers,
      })
      continue
    }
    let unguaranteed = evaluation.unguaranteed.length() > 0
    let native_declared = evaluation.native_path is Some(_)
    // NativeOnly demands a declared native endpoint and full guarantees;
    // AllowTranslated accepts the rest with the risks kept visible.
    if !(policy is AllowTranslated || (!unguaranteed && native_declared)) {
      let policy_reasons = if !native_declared && policy is NativeOnly {
        ["no declared native endpoint under the NativeOnly policy"]
      } else {
        []
      }
      let combined = evaluation.unguaranteed.copy()
      for reason in policy_reasons {
        combined.push(reason)
      }
      for reason in combined {
        unsupported.push("\{evaluation.protocol}: \{reason}")
      }
      blockers.push({ protocol: evaluation.protocol, reasons: combined, })
      continue
    }
    eligible.push(evaluation)
  }
  if eligible is [] {
    return Incompatible({
      model_id: entry.meta.model_id,
      requirements,
      policy,
      blockers,
    })
  }
  let reasons : Array[String] = []
  let wants_cache_fidelity = requirements.signed_thinking_replay ||
    requirements.native_prompt_caching
  let chosen = if wants_cache_fidelity {
    match
      find_first(eligible.iter(), fn(e) {
        e.protocol is Messages && e.native_path is Some(_)
      }) {
      Some(messages) => {
        reasons.push(
          "signed thinking or native prompt caching is required; native Messages is preferred",
        )
        guard messages.native_path is Some(path) else {
          abort("cache-fidelity branch requires a declared native path")
        }
        reasons.push("native \{path} endpoint declared for this model")
        Some(messages)
      }
      None => pick_with_reasons(eligible, preference, reasons)
    }
  } else {
    pick_with_reasons(eligible, preference, reasons)
  }
  guard chosen is Some(evaluation) else {
    // Unreachable: `eligible` is non-empty, so a pick always exists.
    return Incompatible({
      model_id: entry.meta.model_id,
      requirements,
      policy,
      blockers: [],
    })
  }
  let translated = evaluation.native_path is None
  if translated {
    reasons.push(
      "no eligible declared-native endpoint; selection proceeds at gateway level",
    )
  }
  if entry.meta.is_routing_group {
    reasons.push(
      "routing-group identity comes from the catalog; execution rides the gateway's dynamic routing",
    )
  }
  let risks = evaluation.risks.copy()
  if translated {
    risks.push(
      "gateway translation re-encodes requests; protocol-native fidelity is not guaranteed",
    )
  }
  let lossy = translated && policy is AllowTranslated
  if lossy {
    risks.push("caller explicitly accepted lossy translation for this plan")
  }
  Planned({
    model_id: entry.meta.model_id,
    protocol: evaluation.protocol,
    endpoint_path: evaluation.native_path,
    kind: if translated {
      GatewayTranslated
    } else {
      Native
    },
    confidence: if translated {
      Inferred
    } else {
      DeclaredNative
    },
    capabilities: evaluation.capabilities,
    risks,
    unsupported,
    reasons,
    lossy_opt_in: lossy,
  })
}

///|
/// Applies the caller preference, then declared-native-before-translated,
/// then the stable protocol order, recording the reasons as they apply.
fn pick_with_reasons(
  eligible : Array[MagpieProtocolEvaluation],
  preference : MagpiePreference,
  reasons : Array[String],
) -> MagpieProtocolEvaluation? {
  match preference {
    Prefer(protocol) =>
      match find_first(eligible.iter(), fn(e) { e.protocol == protocol }) {
        Some(preferred) => {
          reasons.push("caller prefers \{protocol} among eligible protocols")
          return Some(preferred)
        }
        None =>
          reasons.push(
            "caller preference \{protocol} is not eligible; default selection applies",
          )
      }
    Any => reasons.push("no protocol preference; default selection rules apply")
  }
  match find_first(eligible.iter(), fn(e) { e.native_path is Some(_) }) {
    Some(native) => {
      reasons.push("declared-native endpoints outrank translated ones")
      Some(native)
    }
    None =>
      match eligible {
        [first, ..] => {
          reasons.push(
            "stable protocol order: Messages, Responses, ChatCompletions",
          )
          Some(first)
        }
        [] => None
      }
  }
}
