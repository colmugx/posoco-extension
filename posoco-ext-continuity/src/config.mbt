///|
/// Configuration for session continuity planning.
pub(all) struct ContinuityConfig {
  context_window : Int
  prepare_ratio : Double
  checkpoint_ratio : Double
  emergency_ratio : Double
  min_recent_messages : Int
  min_recent_tokens : Int
  min_checkpoint_tokens : Int
  search_limit : Int
  read_page_chars : Int
} derive(Eq, Debug)

///|
pub fn ContinuityConfig::default() -> ContinuityConfig {
  {
    context_window: 128000,
    prepare_ratio: 0.55,
    checkpoint_ratio: 0.70,
    emergency_ratio: 0.85,
    min_recent_messages: 8,
    min_recent_tokens: 12000,
    min_checkpoint_tokens: 8000,
    search_limit: 8,
    read_page_chars: 6000,
  }
}
