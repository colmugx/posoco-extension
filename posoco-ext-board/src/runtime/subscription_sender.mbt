///|
/// One application writer. The overflow watcher cancels and joins an in-flight
/// send before teardown, including while a large bootstrap is being written.
#warnings("-unused_value")
async fn board_send_subscription(
  client : BoardSubscription,
  send : async (@protocol.BoardServerFrame) -> Unit,
) -> Unit {
  let mut writing = false
  @async.any([
    () => {
      for frame in client.initial_frames {
        if client.dirty_seq is Some(_) {
          return
        }
        writing = true
        send(frame)
        writing = false
      }
      for ;; {
        let frame = client.next()
        if client.dirty_seq is Some(_) {
          return
        }
        writing = true
        send(frame)
        writing = false
      }
    },
    () => client.overflow.get(),
  ])
  // A cancelled fragmented WebSocket write cannot safely start another
  // message. In that case close immediately; otherwise resync is best effort.
  if !writing {
    if client.resync_required() is Some(frame) {
      @async.with_timeout(1000, () => send(frame)) catch {
        _ => ()
      }
    }
  }
}
