///|
/// Estimate the token count of a text as ceil(visible chars / 4).
///
/// This is the kit-wide convention from the compact-kit family (chars/4 is
/// the shared conservative estimate; the next real LLM usage report corrects
/// it). Length is measured in UTF-16 code units.
pub fn estimate_tokens(text : String) -> Int {
  (text.length() + 3) / 4
}
