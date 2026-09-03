///|
/// The native-only white-box tests are the sole users of the wbtest-only
/// `cond_var` and `posoco-devkit` imports, so on js they would trip
/// `unused_package`; this keeper holds them (and the async runtime) alive
/// on every target.
let _wbtest_import_keeper : Unit = {
  ignore(@async.sleep)
  ignore(@cond_var.Cond::Cond())
  ignore(@devkit.EventBus())
}
