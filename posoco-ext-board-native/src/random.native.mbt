///|
/// Native OS entropy probe used only for the ephemeral Board instance token.
extern "c" fn board_random_bytes_probe(n : Int) -> Bytes = "board_random_bytes"
