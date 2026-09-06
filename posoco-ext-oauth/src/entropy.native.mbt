///|
/// entropy.native.mbt — native entropy probe via the C getentropy stub.
///
/// entropy_stub.c returns a fresh MoonBit Bytes of n bytes, or an empty Bytes
/// on any failure/unsupported platform so `oauth_random_bytes` falls back to
/// the LCG.
extern "c" fn oauth_random_bytes_probe(n : Int) -> Bytes = "oauth_random_bytes"
