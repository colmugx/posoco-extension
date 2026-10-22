///|
/// Maximum number of skills returned by one `skill_search` call.
const SKILL_SEARCH_MAX_RESULTS = 8

///|
/// A query keyword shorter than this only matches whole tokens. Substring
/// matching at two characters ("at", "on") is mostly noise.
const SKILL_SEARCH_MIN_SUBSTRING_CHARS = 3

///|
/// A name hit must always outrank a description hit: the catalog is keyed by
/// name, and activation needs the exact name back.
const SKILL_SCORE_NAME_EXACT : Double = 4.0

///|
const SKILL_SCORE_NAME_PREFIX : Double = 3.0

///|
const SKILL_SCORE_NAME_SUBSTRING : Double = 2.5

///|
const SKILL_SCORE_DESCRIPTION_EXACT : Double = 2.0

///|
const SKILL_SCORE_DESCRIPTION_SUBSTRING : Double = 1.0

///|
/// CJK unified ideographs, including extension A. CJK text has no word
/// separators, so a run is indexed as overlapping 2-grams instead of being
/// segmented by a dictionary: "流水线" -> "流水" + "水线". That keeps a Chinese
/// trigger phrase matchable without embedding a segmenter and its dictionary.
fn is_cjk_ideograph(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 0x4E00 && code <= 0x9FFF) || (code >= 0x3400 && code <= 0x4DBF)
}

///|
fn is_cjk_token(token : String) -> Bool {
  match token.get_char(0) {
    Some(ch) => is_cjk_ideograph(ch)
    None => false
  }
}

///|
fn push_token(
  tokens : Array[String],
  seen : Map[String, Unit],
  token : String,
) -> Unit {
  if seen.contains(token) {
    return
  }
  seen.set(token, ())
  tokens.push(token)
}

///|
/// Lowercase keywords for one text. ASCII/digit runs are split on every other
/// character, so `moonbit-orientation` yields `moonbit` + `orientation`; CJK
/// runs yield overlapping 2-grams.
fn tokenize(text : String) -> Array[String] {
  let chars : Array[Char] = []
  for ch in text.to_lower() {
    chars.push(ch)
  }
  let tokens : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  let mut index = 0
  while index < chars.length() {
    let ch = chars[index]
    if is_cjk_ideograph(ch) {
      let mut end = index
      while end < chars.length() && is_cjk_ideograph(chars[end]) {
        end = end + 1
      }
      if end - index == 1 {
        push_token(tokens, seen, ch.to_string())
      } else {
        for i in index..<(end - 1) {
          push_token(
            tokens,
            seen,
            chars[i].to_string() + chars[i + 1].to_string(),
          )
        }
      }
      index = end
    } else if ch.is_ascii_alphabetic() || ch.is_ascii_digit() {
      let mut end = index
      while end < chars.length() &&
            (chars[end].is_ascii_alphabetic() || chars[end].is_ascii_digit()) {
        end = end + 1
      }
      if end - index >= 2 {
        let buffer = StringBuilder()
        for i in index..<end {
          buffer.write_char(chars[i])
        }
        push_token(tokens, seen, buffer.to_string())
      }
      index = end
    } else {
      index = index + 1
    }
  }
  tokens
}

///|
/// Query-side stopwords only. The index keeps every token; dropping words like
/// "use" or "when" here prevents the filler that appears in most descriptions
/// from diluting the ranking.
fn is_query_stopword(token : String) -> Bool {
  let stopwords : Array[String] = [
    "a", "an", "and", "any", "are", "as", "at", "be", "by", "can", "do", "does",
    "for", "from", "help", "how", "i", "if", "in", "into", "is", "it", "its", "me",
    "my", "need", "of", "on", "or", "please", "should", "skill", "skills", "that",
    "the", "this", "to", "use", "used", "using", "want", "was", "what", "when", "where",
    "which", "who", "why", "will", "with", "you", "your",
  ]
  stopwords.contains(token)
}

///|
fn query_tokens(query : String) -> Array[String] {
  let tokens : Array[String] = []
  for token in tokenize(query) {
    if !is_query_stopword(token) {
      tokens.push(token)
    }
  }
  tokens
}

///|
/// One skill's ranking entry for a query.
priv struct SkillMatch {
  index : Int32
  score : Double
  covered : Int32
}

///|
/// Best score for one query keyword, plus whether that hit was name-level.
fn keyword_score(
  keyword : String,
  name_tokens : Array[String],
  description_tokens : Array[String],
  name_lower : String,
  description_lower : String,
) -> (Double, Bool) {
  if name_tokens.contains(keyword) {
    return (SKILL_SCORE_NAME_EXACT, true)
  }
  let long_enough = keyword.length() >= SKILL_SEARCH_MIN_SUBSTRING_CHARS
  if long_enough {
    for name_token in name_tokens {
      if name_token.has_prefix(keyword) {
        return (SKILL_SCORE_NAME_PREFIX, true)
      }
    }
    if name_lower.contains(keyword) {
      return (SKILL_SCORE_NAME_SUBSTRING, true)
    }
  }
  if description_tokens.contains(keyword) {
    return (SKILL_SCORE_DESCRIPTION_EXACT, false)
  }
  if long_enough && description_lower.contains(keyword) {
    return (SKILL_SCORE_DESCRIPTION_SUBSTRING, false)
  }
  (0.0, false)
}

///|
/// Score one skill against the query keywords and decide whether it is a
/// candidate at all.
///
/// Coverage is deliberately partial: requiring every keyword is what made
/// `skill_search` return nothing whenever the model added one word the
/// descriptor did not share. A name-level hit, or a CJK 2-gram hit, is specific
/// enough to stand alone; otherwise half of the keywords must land.
fn score_skill(
  skill : SkillDescriptor,
  tokens : Array[String],
) -> (Double, Int32, Bool) {
  let name_tokens = tokenize(skill.name)
  let description_tokens = tokenize(skill.description)
  let name_lower = skill.name.to_lower()
  let description_lower = skill.description.to_lower()
  let mut score = 0.0
  let mut covered = 0
  let mut strong = 0
  for token in tokens {
    let (value, name_level) = keyword_score(
      token, name_tokens, description_tokens, name_lower, description_lower,
    )
    if value > 0.0 {
      score = score + value
      covered = covered + 1
      if name_level || is_cjk_token(token) {
        strong = strong + 1
      }
    }
  }
  let accepted = covered > 0 && (strong > 0 || covered * 2 >= tokens.length())
  (score, covered, accepted)
}

///|
/// Rank the catalog for one query. Ordering is fully determined by score,
/// coverage, name length, then name, so results are stable across runs.
fn Skills::rank_skills(
  self : Skills,
  tokens : Array[String],
) -> Array[SkillDescriptor] {
  let skills = self.catalog.skills
  let matches : Array[SkillMatch] = []
  for index, skill in skills {
    let (score, covered, accepted) = score_skill(skill, tokens)
    if accepted {
      matches.push({ index, score, covered, })
    }
  }
  matches.sort_by(fn(a, b) {
    let left = skills[a.index]
    let right = skills[b.index]
    if a.score != b.score {
      if a.score > b.score {
        -1
      } else {
        1
      }
    } else if a.covered != b.covered {
      if a.covered > b.covered {
        -1
      } else {
        1
      }
    } else if left.name.length() != right.name.length() {
      if left.name.length() < right.name.length() {
        -1
      } else {
        1
      }
    } else if left.name < right.name {
      -1
    } else if left.name > right.name {
      1
    } else {
      0
    }
  })
  let ranked : Array[SkillDescriptor] = []
  let mut index = 0
  while index < matches.length() && ranked.length() < SKILL_SEARCH_MAX_RESULTS {
    ranked.push(skills[matches[index].index])
    index = index + 1
  }
  ranked
}
