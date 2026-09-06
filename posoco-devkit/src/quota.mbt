///|
/// One authoritative quota reading as stated by a provider. Nothing here is
/// estimated locally: `used_percent` exists only when the provider stated an
/// official percentage, and `reset_at_ms` only when the provider stated a
/// reset time (balance-style providers have neither).
///
/// `window` is a provider-owned opaque label string (examples seen: "5h",
/// "weekly", "balance"); devkit defines no label vocabulary and never
/// interprets labels.
///
/// `amount` carries `(value, currency)` for balance-style readings whose
/// semantics are "remaining funds", not "fraction of a window used".
/// `available` is the provider's own yes/no on whether the account can
/// currently serve requests, when it states one.
pub(all) struct QuotaReading {
  window : String
  used_percent : Double?
  amount : (String, String)?
  available : Bool?
  reset_at_ms : Int64?
  fetched_at_ms : Int64
} derive(Eq, @debug.Debug)

///|
/// A source of authoritative provider quota readings. Implementations live
/// in provider adapter extensions, where the credentials and base URLs the
/// probe needs already reside; consumers (rate-limit guards, status bars)
/// depend only on this trait. `read` returning `Err` means the reading is
/// unavailable — never a fallback estimate. Window labels are provider-owned
/// opaque strings (examples seen: "5h", "weekly", "balance"); devkit defines
/// no label vocabulary and never interprets labels.
pub(open) trait QuotaSource {
  async fn read(Self) -> Result[Array[QuotaReading], String]
}

///|
/// Process-wide registry of named quota sources. Provider adapter extensions
/// register their source under their provider id on every factory
/// `build`/`refresh` that yields a configured provider, so each registration
/// is the latest credential snapshot (last write wins). Pull-style consumers
/// such as the `/status` command look the currently active provider id up at
/// command time and read the source live. There is deliberately no
/// unregistration on `Unconfigured` builds: a stale entry is never read
/// because consumers only query the active provider id.
let quota_registry_cell : Ref[Map[String, &QuotaSource]] = Ref::{
  val: Map::from_array([]),
}

///|
/// Register `source` under `id`, replacing any previous registration for
/// that id (last write wins).
pub fn quota_registry_register(id : String, source : &QuotaSource) -> Unit {
  quota_registry_cell.val[id] = source
}

///|
/// The source registered under `id`, or `None` when nothing is registered.
pub fn quota_registry_lookup(id : String) -> &QuotaSource? {
  quota_registry_cell.val.get(id)
}

///|
/// Drop the registration under `id`; a no-op for unknown ids.
pub fn quota_registry_unregister(id : String) -> Unit {
  quota_registry_cell.val.remove(id)
}
