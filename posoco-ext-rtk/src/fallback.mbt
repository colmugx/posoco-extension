///|
// wasm/wasm-gc: no subprocess API exists, so the seam is inert and every
// shell call passes through unchanged.

///|
#cfg(not(any(target="native", target="js")))
fn rtk_rewrite(_rtk_path : String, _cmd : String) -> String? noraise {
  None
}

///|
#cfg(not(any(target="native", target="js")))
priv struct InertRtkRewrite {}

///|
#cfg(not(any(target="native", target="js")))
impl RTKRewrite for InertRtkRewrite with fn rewrite(
  _self : InertRtkRewrite,
  _rtk_path : String,
  _cmd : String,
) -> String? {
  None
}

///|
#cfg(not(any(target="native", target="js")))
fn rtk_default_rewriter() -> &RTKRewrite {
  InertRtkRewrite::{ }
}
