///|
/// Process-local configuration shared by the Board runtime. S0 only records
/// stable defaults; no server or browser lifecycle is started yet.
pub(all) struct BoardConfig {
  auto_start : Bool
  auto_open : Bool
  bind_host : String
  event_buffer : Int32
  client_queue_depth : Int32
} derive(Eq, Debug)

///|
pub extend BoardConfig with Eq::{equal, not_equal}

///|
pub extend BoardConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn BoardConfig::BoardConfig(
  auto_start~ : Bool = false,
  auto_open~ : Bool = false,
  bind_host~ : String = "127.0.0.1",
  event_buffer~ : Int32 = 4096,
  client_queue_depth~ : Int32 = 256,
) -> BoardConfig {
  { auto_start, auto_open, bind_host, event_buffer, client_queue_depth, }
}
