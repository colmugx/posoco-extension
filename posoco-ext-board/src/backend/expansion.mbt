///|
/// S4E1 trusted headless graph expansion. The browser/wire command table is
/// deliberately not extended: an expansion is a privileged atomic operation
/// for trusted hosts and is reachable only through this typed backend
/// method, never through `handle_command`.

///|
/// Submit one atomic additive graph expansion durably. One accepted call
/// creates all detached candidate tasks in stage `Created`, appends the
/// durable expansion record (identity, workflow/parent lineage,
/// `local_ref -> canonical` mapping, normalized content digest) and
/// publishes exactly one authoritative `board.graph.expanded` event, at
/// revision + 1, in a single store transaction. Existing tasks, edges and
/// attempts never change and no Attempt is created.
///
/// Reuse of a committed expansion id is rejected with the typed
/// `duplicate_expansion` domain error regardless of content, and an
/// uncertain-durability result is reconciled by reload only: the
/// coordinator never replays an expansion automatically, so the host must
/// read `expansion_history` to reconcile the original stable proposal ID.
///
/// `at_ms = None` stamps the backend clock (`now_ms`).
pub async fn BoardBackend::expand_graph(
  self : BoardBackend,
  expansion~ : @domain.ExpansionId,
  candidates~ : Array[@domain.GraphTask],
  parent~ : @domain.BoardTaskId,
  workflow~ : String,
  at_ms~ : Int64? = None,
  expected_revision~ : Int64,
) -> Result[Array[@domain.BoardEvent], @coordinator.BoardCoordinatorError] {
  let at_ms = match at_ms {
    Some(at_ms) => at_ms
    None => (self.now_ms)()
  }
  self.coordinator.submit(
    command=@domain.ExpandGraph(
      expansion~,
      candidates=candidates.map(candidate => candidate.copy_detached()),
      parent~,
      workflow~,
      at_ms~,
      expected_revision~,
    ),
  )
}

///|
/// Detached durable expansion history of the committed board: every
/// accepted expansion's identity, lineage, local_ref mapping and normalized
/// content binding. The primary reconciliation read after an uncertain
/// durability result.
pub async fn BoardBackend::expansion_history(
  self : BoardBackend,
) -> Result[Array[@domain.ExpansionRecord], @coordinator.BoardCoordinatorError] {
  self.coordinator.expansions()
}
