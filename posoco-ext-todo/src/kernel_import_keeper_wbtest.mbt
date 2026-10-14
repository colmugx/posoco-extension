///|
/// The kernel import in moon.pkg feeds the native-only white-box fixture
/// (ToolCallContext.effect_id); this keeper holds the wbtest-scoped import
/// alive on targets where that file is excluded.
let _kernel_wbtest_import_keeper : Unit = ignore(@kernel.EffectId::{ value: 0, })
