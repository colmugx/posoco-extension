///|
test "PiAdaptor is a Posoco extension with one tool provider" {
  let adaptor = pi_extension()
  inspect(adaptor.extension_id(), content="posoco_ext_pi_adaptor")
  let manifest = adaptor.manifest()
  inspect(manifest.id, content="posoco_ext_pi_adaptor")
  inspect(manifest.tools.length(), content="1")
  inspect(manifest.models.length(), content="0")
}

///|
test "empty Pi host has an empty catalog" {
  let adaptor = pi_adaptor_new()
  inspect(pi_adaptor_tool_count(adaptor), content="0")
  inspect(pi_adaptor_catalog_json(adaptor), content="[]")
}

///|
test "PiCatalogSource exposes the adaptor revision and tools" {
  let adaptor = pi_adaptor_new()
  let source = PiCatalogSource(adaptor~)
  inspect(source.revision(), content="0")
  inspect(source.tools().length(), content="0")
}
