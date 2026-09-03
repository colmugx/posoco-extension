///|
/// Whitebox helper: call host.api.appendEntry directly.
extern "js" fn wbtest_call_append_entry(
  host : JsPiHost,
  custom_type : String,
  data_json : String,
) -> Unit =
  #| (host, customType, dataJson) => {
  #|   host.api.appendEntry(customType, JSON.parse(dataJson));
  #| }

///|
/// Whitebox helper: call host.api.sendMessage / sendUserMessage directly.
extern "js" fn wbtest_call_send_message(
  host : JsPiHost,
  message_json : String,
  options_json : String,
) -> Unit =
  #| (host, messageJson, optionsJson) => {
  #|   host.api.sendMessage(JSON.parse(messageJson), JSON.parse(optionsJson));
  #| }

///|
extern "js" fn wbtest_call_send_user_message(
  host : JsPiHost,
  content : String,
  options_json : String,
) -> Unit =
  #| (host, content, optionsJson) => {
  #|   const parsed = content.startsWith("[") ? JSON.parse(content) : content;
  #|   host.api.sendUserMessage(parsed, JSON.parse(optionsJson));
  #| }

///|
test "appendEntry feeds entries, the fresh-entry drain, and the emit callback" {
  let adaptor = pi_adaptor_new()
  let seen : Array[String] = []
  pi_adaptor_set_custom_entry_callback(adaptor, fn(custom_type, data_json) {
    seen.push(custom_type + "=" + data_json)
  })
  wbtest_call_append_entry(adaptor.host, "w5-note", "{\"text\":\"a\"}")
  wbtest_call_append_entry(adaptor.host, "w5-note", "{\"text\":\"b\"}")
  inspect(
    js_entries_json(adaptor.host).contains("\"text\":\"a\""),
    content="true",
  )
  let drained = js_take_custom_entries_json(adaptor.host)
  inspect(
    drained.contains("\"customType\":\"w5-note\"") &&
    drained.contains("\"text\":\"a\"") &&
    drained.contains("\"text\":\"b\""),
    content="true",
  )
  inspect(seen.length(), content="2")
  inspect(seen[0], content="w5-note={\"text\":\"a\"}")
  // Drained: a second take sees nothing.
  inspect(js_take_custom_entries_json(adaptor.host), content="[]")
  // Seeded restore entries stay visible to the package but never re-drain.
  pi_adaptor_seed_entry(adaptor, "w5-restored", "{\"text\":\"r\"}")
  inspect(js_entries_json(adaptor.host).contains("w5-restored"), content="true")
  inspect(js_take_custom_entries_json(adaptor.host), content="[]")
  inspect(seen.length(), content="2")
}

///|
test "sendMessage consumes the envelope when the control callback accepts" {
  let adaptor = pi_adaptor_new()
  js_host_set_followup_callback(adaptor.host, fn(envelope_json) {
    ignore(envelope_json)
    "Accepted"
  })
  wbtest_call_send_message(
    adaptor.host,
    "{\"customType\":\"x\",\"content\":\"hi\"}",
    "{\"triggerTurn\":true}",
  )
  inspect(js_take_followups_json(adaptor.host), content="[]")
  inspect(js_messages_json(adaptor.host).contains("hi"), content="true")
}

///|
test "idle triggerTurn sends park for the next turn; sendUserMessage always triggers" {
  let adaptor = pi_adaptor_new()
  js_host_set_followup_callback(adaptor.host, fn(envelope_json) {
    ignore(envelope_json)
    "Parked"
  })
  // Idle sendMessage: the envelope parks in state.followUps instead of being
  // dropped (the W5 idle-drop fix).
  wbtest_call_send_message(
    adaptor.host,
    "{\"customType\":\"idle\",\"content\":\"later\"}",
    "{\"triggerTurn\":true}",
  )
  let parked = js_take_followups_json(adaptor.host)
  inspect(parked.contains("later"), content="true")
  inspect(parked.contains("\"triggerTurn\":true"), content="true")
  // triggerTurn:false never queues.
  wbtest_call_send_message(
    adaptor.host,
    "{\"customType\":\"quiet\",\"content\":\"shh\"}",
    "{\"triggerTurn\":false}",
  )
  inspect(js_take_followups_json(adaptor.host), content="[]")
  // sendUserMessage forces triggerTurn and collapses content blocks to text.
  wbtest_call_send_user_message(adaptor.host, "user hello", "{}")
  wbtest_call_send_user_message(
    adaptor.host,
    "[{\"type\":\"image\",\"data\":\"x\"},{\"type\":\"text\",\"text\":\"block\"}]",
    "{}",
  )
  let user_sent = js_take_followups_json(adaptor.host)
  inspect(user_sent.contains("user hello"), content="true")
  inspect(user_sent.contains("block"), content="true")
  inspect(user_sent.contains("image"), content="false")
}
