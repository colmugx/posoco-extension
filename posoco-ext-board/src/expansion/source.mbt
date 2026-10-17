///|
/// `DynamicPlanSource` is the typed host seam for proposal *generation*. It
/// is deliberately narrow: generation is separate from approval and commit,
/// sees only authorized bounded context, and returns one opaque versioned
/// payload. There is no field for prompts, model configuration or arbitrary
/// metadata, and nothing here persists a request or a reply. Implementations
/// (wired by the trusted host, e.g. over an existing execution owner plus an
/// opt-in result channel) must use the S4A owner rather than constructing a runtime, must not
/// retain the context, and must treat the payload as single-use material for
/// the host's decode/validate/approve pipeline.
///
/// This package instantiates no Agent, runtime, driver or execution owner.

///|
/// Authorized bounded generation context. Only what the decoder and policy
/// need: who authorized generation, which workflow lineage and parent it is
/// bound to, which existing tasks may be referenced, and the exact bounds.
/// The permitted-dependency list is detached once here.
pub(all) struct DynamicPlanContext {
  workflow_parent : String
  workflow : String?
  authorization_id : String
  permitted_existing_dependencies : Array[String]
  max_new_tasks : Int32
  max_new_edges : Int32
  max_payload_bytes : Int32
  deadline_ms : Int64
} derive(Eq, Debug)

///|
pub extend DynamicPlanContext with Eq::{equal, not_equal}

///|
pub extend DynamicPlanContext with @debug.Debug::{to_repr}

///|
/// One generated proposal payload: an opaque versioned proposal, exactly the
/// input `decode_expansion_proposal` accepts. Nothing else may accompany it.
pub(all) struct DynamicPlanReply {
  payload : String
} derive(Eq, Debug)

///|
pub extend DynamicPlanReply with Eq::{equal, not_equal}

///|
pub extend DynamicPlanReply with @debug.Debug::{to_repr}

///|
pub(all) enum DynamicPlanSourceError {
  /// The source cannot generate now; no payload was produced.
  Unavailable
  /// The source refused generation for this context.
  Denied
} derive(Eq, Debug)

///|
pub extend DynamicPlanSourceError with Eq::{equal, not_equal}

///|
pub extend DynamicPlanSourceError with @debug.Debug::{to_repr}

///|
pub(open) trait DynamicPlanSource {
  /// Generate one proposal payload for the authorized context. Cancellation
  /// propagates as a raised error; denials and unavailability are values.
  async fn generate(Self, DynamicPlanContext) -> Result[
    DynamicPlanReply,
    DynamicPlanSourceError,
  ]
}

///|
/// Called only after approval, once per task. No expansion IDs are allocated:
/// the schema's proposal_id is the one durable whole-proposal identity.
pub(open) trait ExpansionIdAllocator {
  fn canonical_task_id(
    Self,
    proposal_id~ : String,
    key~ : String,
    index~ : Int32,
  ) -> String
}

///|
/// Deterministic proposal-scoped allocator. The name is retained for source
/// compatibility; numbering alone is not sufficient across host restarts.
pub struct NumberedExpansionAllocator {
  priv prefix_ : String
}

///|
pub fn NumberedExpansionAllocator::NumberedExpansionAllocator(
  prefix~ : String,
) -> NumberedExpansionAllocator {
  { prefix_: prefix, }
}

///|
pub impl ExpansionIdAllocator for NumberedExpansionAllocator with fn canonical_task_id(
  self,
  proposal_id~,
  key~,
  index~,
) {
  let framed : Json = [proposal_id, key, index]
  self.prefix_ + sha256_text(framed.stringify())
}

///|
pub extend NumberedExpansionAllocator with ExpansionIdAllocator::{
  canonical_task_id,
}
