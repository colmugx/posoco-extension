///|
/// The `async test` blocks that need the `moonbitlang/core/async` runtime live in
/// native-only white-box files, so on js the wbtest-only import would trip
/// `unused_package`; this keeper holds it alive on every target.
let _async_wbtest_import_keeper : Unit = ignore(@async.sleep)
