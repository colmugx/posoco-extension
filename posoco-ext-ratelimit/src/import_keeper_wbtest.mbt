///|
/// Keep wbtest-only integration imports live on every checked target.
let _wbtest_import_keeper : Unit = {
  ignore(@core_async.now())
  ignore(@fuwaroid.Mailbox::Unbounded)
}
