///|
/// Keep wbtest-only integration imports live on every checked target.
let _wbtest_import_keeper : Unit = {
  ignore(@async.sleep)
  ignore(@devkit.EventBus())
  ignore(@fuwaroid.Mailbox::Unbounded)
}
