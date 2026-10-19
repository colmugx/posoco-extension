///|
fn[T, E : @debug.Debug] Result::checked(self : Result[T, E]) -> T raise {
  match self {
    Ok(value) => value
    Err(error) => fail("expected Ok, received \{Repr(error)}")
  }
}

///|
fn[T] Option::checked(self : T?) -> T raise {
  match self {
    Some(value) => value
    None => fail("expected Some")
  }
}
