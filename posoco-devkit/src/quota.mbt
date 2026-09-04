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
