///|
// Native backend. Exit codes are deliberately ignored: `rtk rewrite`
// documents exit 0 on success but exits 3 in practice, so stdout
// emptiness is the only stable decision input.

///|
async fn rtk_rewrite(rtk_path : String, cmd : String) -> String? noraise {
  let result = @process.run(
    rtk_path,
    ["rewrite", cmd],
    stdout=Collect,
    stderr=Discard,
  ) catch {
    _ => return None
  }
  let text = result.stdout_text() catch { _ => return None }
  let trimmed = text.trim().to_owned()
  if trimmed == "" {
    None
  } else {
    Some(trimmed)
  }
}

///|
priv struct NativeRtkRewrite {}

///|
impl RTKRewrite for NativeRtkRewrite with fn rewrite(
  _self : NativeRtkRewrite,
  rtk_path : String,
  cmd : String,
) -> String? {
  rtk_rewrite(rtk_path, cmd)
}

///|
fn rtk_default_rewriter() -> &RTKRewrite {
  NativeRtkRewrite::{ }
}
