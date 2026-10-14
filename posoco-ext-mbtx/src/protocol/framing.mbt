///|
pub suberror ProtocolError {
  Invalid(String)
} derive(Debug)

///|
pub extend ProtocolError with Debug::{to_repr}

///|
pub struct Decoder {
  bytes : Array[Byte]
  max_frame_bytes : Int32
}

///|
pub fn Decoder::Decoder(max_frame_bytes~ : Int32 = 65536) -> Decoder {
  { bytes: [], max_frame_bytes, }
}

///|
pub fn Decoder::feed(
  self : Decoder,
  chunk : Bytes,
) -> Array[Json] raise ProtocolError {
  let frames = []
  for byte in chunk {
    if byte == 10 {
      let text = @utf8.decode(Bytes::from_array(self.bytes)) catch {
        _ => raise Invalid("frame is not valid UTF-8")
      }
      self.bytes.clear()
      let frame = @json.parse(text) catch {
        _ => raise Invalid("frame is not valid JSON")
      }
      frames.push(frame)
    } else {
      if self.bytes.length() >= self.max_frame_bytes {
        raise Invalid("frame byte limit exceeded")
      }
      self.bytes.push(byte)
    }
  }
  frames
}

///|
pub fn Decoder::finish(self : Decoder) -> Unit raise ProtocolError {
  if !self.bytes.is_empty() {
    raise Invalid("EOF in unfinished frame")
  }
}

///|
pub fn encode_frame(
  value : Json,
  max_frame_bytes~ : Int32 = 65536,
) -> Bytes raise ProtocolError {
  let bytes = @utf8.encode(value.stringify())
  if bytes.length() > max_frame_bytes {
    raise Invalid("frame byte limit exceeded")
  }
  bytes + b"\n"
}
