///|
/// `/model quick-pick` support.
///
/// Quick-pick aggregates quota readings across every provider that
/// contributed slots (slot presence is the login signal), through
/// host-injected sources first, then the devkit registry. Readings are
/// facts, never estimated: Err and timeout simply omit the provider.

///|
/// Reserved `/model` slot-argument keyword; wins over any real slot id.
let quick_pick_keyword : String = "quick-pick"

///|
/// Per-source read deadline; tasks run concurrently so command latency is
/// bounded by one timeout.
let quick_pick_source_timeout_ms : Int = 2500

///|
/// Distinct provider ids behind the current slots, in first-seen slot order.
fn RouterModelPort::distinct_provider_ids(
  self : RouterModelPort,
) -> Array[String] {
  let provider_ids : Array[String] = []
  let seen : Map[String, Unit] = Map::from_array([])
  for slot_id in self.slot_order {
    match self.slots.get(slot_id) {
      Some(slot) =>
        if !seen.contains(slot.provider_id) {
          seen[slot.provider_id] = ()
          provider_ids.push(slot.provider_id)
        }
      None => ()
    }
  }
  provider_ids
}

///|
/// Pull quota readings for every provider that contributed a slot, in
/// first-seen slot order. Each source is read concurrently under its own
/// timeout; only successful reads land in the returned map, so a failing or
/// slow provider is omitted rather than estimated.
async fn RouterModelPort::collect_provider_quota(
  self : RouterModelPort,
) -> Map[String, Array[@devkit.QuotaReading]] noraise {
  let provider_ids = self.distinct_provider_ids()
  let sources : Array[(String, &@devkit.QuotaSource)] = []
  for id in provider_ids {
    match self.extra_quota_sources.get(id) {
      Some(source) => sources.push((id, source))
      None =>
        match @devkit.quota_registry_lookup(id) {
          Some(source) => sources.push((id, source))
          None => ()
        }
    }
  }
  let readings : Map[String, Array[@devkit.QuotaReading]] = Map::from_array([])
  @async.with_task_group(group => {
    for (id, source) in sources {
      ignore(
        group.spawn(
          () => {
            let result = @async.with_timeout_opt(quick_pick_source_timeout_ms, () => {
              source.read() catch {
                _ => Err("quota pull failed")
              }
            })
            match result {
              Some(Ok(list)) => readings[id] = list
              _ => ()
            }
          },
          allow_failure=true,
        ),
      )
    }
  }) catch {
    _ => ()
  }
  readings
}

///|
/// Encode one quota reading verbatim: provider-stated fields only, absent
/// optionals as JSON null, no invented values.
fn quota_reading_json(reading : @devkit.QuotaReading) -> Json {
  Json::object(
    Map::from_array([
      ("window", Json::string(reading.window)),
      (
        "used_percent",
        match reading.used_percent {
          Some(value) => Json::number(value)
          None => Json::null()
        },
      ),
      (
        "amount",
        match reading.amount {
          Some((value, currency)) =>
            Json::object(
              Map::from_array([
                ("value", Json::string(value)),
                ("currency", Json::string(currency)),
              ]),
            )
          None => Json::null()
        },
      ),
      (
        "available",
        match reading.available {
          Some(value) => Json::boolean(value)
          None => Json::null()
        },
      ),
      (
        "reset_at_ms",
        match reading.reset_at_ms {
          Some(value) => Json::number(value.to_double())
          None => Json::null()
        },
      ),
      ("fetched_at_ms", Json::number(reading.fetched_at_ms.to_double())),
    ]),
  )
}
