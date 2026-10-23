///|
/// Execute a complete .mbtx script. Imports and main use normal MoonBit syntax.
pub async fn Runtime::run(
  self : Runtime,
  source : String,
  input : Json,
  invocation_id~ : String,
  tools~ : Array[String] = [],
  on_call? : async (String, Json) -> Outcome,
  timeout_ms~ : Int32 = 120000,
  handshake_ms~ : Int32 = 30000,
  max_frame_bytes~ : Int32 = 65536,
  max_pending~ : Int32 = 8,
  max_calls~ : Int32 = 128,
  max_output_bytes~ : Int32 = 1048576,
) -> InvocationResult {
  self.execute(
    Source(source),
    input,
    invocation_id~,
    tools~,
    on_call?,
    timeout_ms~,
    handshake_ms~,
    max_frame_bytes~,
    max_pending~,
    max_calls~,
    max_output_bytes~,
  )
}

///|
/// Execute an existing script. The Moon launcher also accepts local main packages
/// and Wasm artifacts; Moonx accepts .mbtx files only here.
pub async fn Runtime::run_file(
  self : Runtime,
  path : String,
  input : Json,
  invocation_id~ : String,
  tools~ : Array[String] = [],
  on_call? : async (String, Json) -> Outcome,
  timeout_ms~ : Int32 = 120000,
  handshake_ms~ : Int32 = 30000,
  max_frame_bytes~ : Int32 = 65536,
  max_pending~ : Int32 = 8,
  max_calls~ : Int32 = 128,
  max_output_bytes~ : Int32 = 1048576,
) -> InvocationResult {
  self.execute(
    File(path),
    input,
    invocation_id~,
    tools~,
    on_call?,
    timeout_ms~,
    handshake_ms~,
    max_frame_bytes~,
    max_pending~,
    max_calls~,
    max_output_bytes~,
  )
}
