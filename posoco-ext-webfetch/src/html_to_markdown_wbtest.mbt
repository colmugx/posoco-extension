///|
let fx_headings : String = "<html><head><title>Headings</title></head><body><h1>Top</h1><h2>Second</h2><h3>Third</h3><h6>Deep</h6></body></html>"

///|
let fx_inline : String = "<p>Hello <strong>big</strong> <em>small</em> and <b>bold</b> world</p>"

///|
let fx_lists : String = "<ol><li>one<ul><li>a</li><li>b</li></ul></li><li>two</li></ol>"

///|
let fx_links : String = "<p><a href=\"sub/x\">S</a> <a href=\"https://other.com/y(a)\">Y</a> <a href=\"./x\">D</a> <a href=\"../x\">U</a> <a href=\"javascript:void(0)\">Z</a> <a href=\"sub/y\">a [b] c</a> <a href=\"https://ex.com/docs/page\">Self</a></p>"

///|
let fx_link_empty : String = "<p><a href=\"only/url\"></a></p>"

///|
let fx_code_lang : String = "<pre><code class=\"language-rust\">fn main() {\n    let x = 1;\n}</code></pre>"

///|
let fx_code_ticks : String = "<pre>plain ``` fenced\nmore ```` four</pre>"

///|
let fx_code_inline : String = "<p>use <code>foo()</code> and <code>a`b</code></p>"

///|
let fx_table : String = "<table><thead><tr><th>N</th><th>Desc</th></tr></thead><tbody><tr><td>a|b</td><td>line1<br>line2</td></tr><tr><td>x</td></tr></tbody></table>"

///|
let fx_img : String = "<p>See <img src=\"x.png\" alt=\"diagram\"> and <img src=\"y.png\" alt=\"\"> and <img src=\"z.png\"></p>"

///|
let fx_discard : String = "<html><body><nav><a href=\"/nav\">NavLink</a></nav><p>Keep me</p><footer><p>FooterText</p></footer><script>var x=1;</script><style>.a{color:red}</style><aside>Sidebar</aside><form><input><button>Go</button></form></body></html>"

///|
let fx_entities : String = "<p>A &amp; B &lt;tag&gt; C&nbsp;D &quot;q&quot;</p>"

///|
let fx_malformed : String = "<p>one<p>two</div><div>three</div><b>bold"

///|
let fx_quote : String = "<blockquote><p>Quoted <em>text</em></p><p>Second</p></blockquote>"

///|
let fx_breaks : String = "<p>a<br>b</p><hr><p>c</p>"

///|
let fx_og_title : String = "<html><head><meta property=\"og:title\" content=\"OG Page\"></head><body><p>x</p></body></html>"

///|
let fx_h1_title : String = "<html><body><h1>Heading One</h1><p>x</p></body></html>"

///|
let fx_no_title : String = "<html><body><p>just text</p></body></html>"

///|
test "html headings" {
  let res = html_to_markdown(fx_headings, base="https://ex.com/docs/page")
  inspect(
    res.title,
    content=(
      #|Headings
    ),
  )
  inspect(
    res.markdown,
    content=(
      #|# Top
      #|
      #|## Second
      #|
      #|### Third
      #|
      #|###### Deep
    ),
  )
}

///|
test "html paragraph inline emphasis" {
  let res = html_to_markdown(fx_inline, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|Hello **big** *small* and **bold** world
    ),
  )
}

///|
test "html nested list ol ul" {
  let res = html_to_markdown(fx_lists, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|1. one
      #|  - a
      #|  - b
      #|2. two
    ),
  )
}

///|
test "html links" {
  let res = html_to_markdown(fx_links, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|[S](https://ex.com/docs/sub/x) [Y](https://other.com/y\(a\)) [D](https://ex.com/docs/x) [U](https://ex.com/x) Z [a \[b\] c](https://ex.com/docs/sub/y) [Self](https://ex.com/docs/page)
    ),
  )
}

///|
test "html link empty anchor" {
  let res = html_to_markdown(fx_link_empty, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|https://ex.com/docs/only/url
    ),
  )
}

///|
test "html code block with language" {
  let res = html_to_markdown(fx_code_lang, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|```rust
      #|fn main() {
      #|    let x = 1;
      #|}
      #|```
    ),
  )
}

///|
test "html code block containing backticks" {
  let res = html_to_markdown(fx_code_ticks, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|`````
      #|plain ``` fenced
      #|more ```` four
      #|`````
    ),
  )
}

///|
test "html inline code" {
  let res = html_to_markdown(fx_code_inline, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|use `foo()` and ``a`b``
    ),
  )
}

///|
test "html table escaping" {
  let res = html_to_markdown(fx_table, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|| N | Desc |
      #|| --- | --- |
      #|| a\|b | line1 line2 |
      #|| x |
    ),
  )
}

///|
test "html img alt" {
  let res = html_to_markdown(fx_img, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|See diagram and and
    ),
  )
}

///|
test "html dropped subtrees" {
  let res = html_to_markdown(fx_discard, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|Keep me
    ),
  )
}

///|
test "html entities decoded" {
  let res = html_to_markdown(fx_entities, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|A & B <tag> C D "q"
    ),
  )
}

///|
test "html malformed markup" {
  let res = html_to_markdown(fx_malformed, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|one
      #|
      #|two
      #|
      #|three**bold**
    ),
  )
}

///|
test "html blockquote" {
  let res = html_to_markdown(fx_quote, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|> Quoted *text*
      #|>
      #|> Second
    ),
  )
}

///|
test "html br and hr" {
  let res = html_to_markdown(fx_breaks, base="https://ex.com/docs/page")
  inspect(
    res.markdown,
    content=(
      #|a
      #|b
      #|
      #|---
      #|
      #|c
    ),
  )
}

///|
test "html title from og fallback" {
  let res = html_to_markdown(fx_og_title, base="https://ex.com/docs/page")
  inspect(
    res.title,
    content=(
      #|OG Page
    ),
  )
}

///|
test "html title from h1 fallback" {
  let res = html_to_markdown(fx_h1_title, base="https://ex.com/docs/page")
  inspect(
    res.title,
    content=(
      #|Heading One
    ),
  )
}

///|
test "html title from base fallback" {
  let res = html_to_markdown(fx_no_title, base="https://ex.com/docs/page")
  inspect(
    res.title,
    content=(
      #|page
    ),
  )
}

///|
test "html empty document" {
  let res = html_to_markdown("", base="https://ex.com/docs/page")
  inspect(
    res.title,
    content=(
      #|page
    ),
  )
  inspect(res.markdown, content="")
}

///|
test "html large page stays fast" {
  let chunk = "<div class=\"row\"><p>Item <a href=\"./detail/thing\">link</a> and <code>x()</code> text with <b>bold</b> words &amp; entities</p><ul><li>a</li><li>b</li></ul><table><tr><th>k</th><td>v &amp; v</td></tr></table><blockquote><p>note</p></blockquote></div>"
  let b = StringBuilder()
  b.write_string("<html><head><title>Big</title></head><body>")
  for _t in 0..<500 {
    b.write_string(chunk)
  }
  b.write_string("</body></html>")
  let res = html_to_markdown(b.to_string(), base="https://ex.com/docs/page")
  inspect(
    res.title,
    content=(
      #|Big
    ),
  )
  inspect(
    res.markdown.length() > 40_000,
    content=(
      #|true
    ),
  )
}
