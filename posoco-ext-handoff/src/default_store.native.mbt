///|
let handoff_atomic_counter : Ref[Int] = { val: 0 }

///|
pub impl HandoffStore for DefaultHandoffStore with fn exists(_self, path) {
  let present = @fs.exists(path) catch {
    _ => return Err("handoff store exists failed: " + path)
  }
  Ok(present)
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn read(_self, path) {
  let data = @fs.read_file(path) catch {
    _ => return Err("handoff store read failed: " + path)
  }
  let text = data.text() catch {
    _ => return Err("handoff store decode failed: " + path)
  }
  Ok(text)
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn ensure_dir(_self, path) {
  @fs.mkdir(path, recursive=true) catch {
    _ => return Err("handoff store mkdir failed: " + path)
  }
  Ok(())
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn write_atomic(
  _self,
  path,
  content,
) {
  handoff_atomic_counter.val += 1
  let tmp = "\{path}.tmp-\{handoff_atomic_counter.val}"
  @fs.write_file(
    tmp,
    content,
    create_mode=OpenOrCreate,
    permission=0o644,
  ) catch {
    _ => {
      @fs.remove(tmp) catch { _ => () }
      return Err("handoff store write failed: " + path)
    }
  }
  @fs.rename(tmp, path, replace=true) catch {
    _ => {
      @fs.remove(tmp) catch { _ => () }
      return Err("handoff store rename failed: " + path)
    }
  }
  Ok(())
}
