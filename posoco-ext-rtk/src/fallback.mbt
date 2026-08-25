///|
// wasm/wasm-gc: no subprocess API exists, so the seam is inert and every
// shell call passes through unchanged.

///|
#cfg(not(any(target="native", target="js")))
fn rtk_rewrite(_rtk_path : String, _cmd : String) -> String? noraise {
  None
}
