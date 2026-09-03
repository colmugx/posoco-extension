///|
/// Quota window vocabulary shared by provider probes and limit guards. The
/// provider owns the truth about which windows exist; the names below cover
/// the shapes seen so far, and `Other` carries any provider-specific label
/// verbatim instead of guessing it into a typed slot.
pub(all) enum QuotaWindow {
  FiveHours
  Weekly
  Monthly
  Balance
  Other(String)
} derive(Eq, @debug.Debug)

///|
/// One authoritative quota reading as stated by a provider. Nothing here is
/// estimated locally: `used_percent` exists only when the provider stated an
/// official percentage, and `reset_at_ms` only when the provider stated a
/// reset time (balance-style providers have neither).
///
/// `amount` carries `(value, currency)` for balance-style readings whose
/// semantics are "remaining funds", not "fraction of a window used".
/// `available` is the provider's own yes/no on whether the account can
/// currently serve requests, when it states one.
pub(all) struct QuotaReading {
  window : QuotaWindow
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
/// unavailable — never a fallback estimate.
pub(open) trait QuotaSource {
  async fn read(Self) -> Result[Array[QuotaReading], String]
}
