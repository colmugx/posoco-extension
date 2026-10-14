///|
#external
priv type NodeProcess

///|
#module("node:child_process")
extern "js" fn node_spawn(
  command : String,
  args : FixedArray[String],
  options : Json,
) -> NodeProcess = "spawn"

///|
extern "js" fn open_node_process(
  spawn : (String, FixedArray[String], Json) -> NodeProcess,
  command : String,
  args : FixedArray[String],
  cwd : String,
  inherit_env : Bool,
) -> NodeProcess =
  #| (spawn, command, args, cwd, inherit) => {
  #|   const p = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], env: inherit ? process.env : {PATH: process.env.PATH ?? ''}, ...(cwd ? {cwd} : {}) });
  #|   const attach = stream => {
  #|     const s = {stream, q: [], bytes: 0, ended: false, error: '', waiter: null};
  #|     const wake = () => { const w = s.waiter; s.waiter = null; if (w) w(); };
  #|     stream.on('data', b => { s.q.push(b); s.bytes += b.length; if (s.bytes >= 65536) stream.pause(); wake(); });
  #|     stream.on('end', () => { s.ended = true; wake(); });
  #|     stream.on('close', () => { s.ended = true; wake(); });
  #|     stream.on('error', e => { s.error = String(e); s.ended = true; wake(); });
  #|     return s;
  #|   };
  #|   const h = {p, out: attach(p.stdout), err: attach(p.stderr), settled: false, spawnError: '', stdinError: ''};
  #|   h.exited = new Promise(resolve => {
  #|     p.on('error', e => { h.spawnError = String(e); h.settled = true; resolve(-1); });
  #|     p.on('close', (code, signal) => { h.settled = true; resolve(code ?? -1); });
  #|   });
  #|   p.stdin.on('error', e => { h.stdinError = String(e); });
  #|   return h;
  #| }

///|
extern "js" fn node_read(
  handle : NodeProcess,
  stderr : Bool,
) -> @js_async.Promise[String] =
  #| async (h, stderr) => {
  #|   const s = stderr ? h.err : h.out;
  #|   while (!s.q.length && !s.ended && !h.spawnError) await new Promise(resolve => { s.waiter = resolve; });
  #|   if (h.spawnError || s.error) throw new Error(h.spawnError || s.error);
  #|   if (!s.q.length) return '';
  #|   const b = s.q[0], chunk = b.subarray(0, 8192);
  #|   if (chunk.length === b.length) s.q.shift(); else s.q[0] = b.subarray(chunk.length);
  #|   s.bytes -= chunk.length;
  #|   if (s.bytes < 65536 && !s.ended) s.stream.resume();
  #|   return JSON.stringify(Array.from(chunk));
  #| }

///|
extern "js" fn node_write(
  handle : NodeProcess,
  bytes : FixedArray[Byte],
) -> @js_async.Promise[Unit] =
  #| (h, bytes) => new Promise((resolve, reject) => h.p.stdin.write(Buffer.from(bytes), e => e ? reject(e) : resolve()))

///|
extern "js" fn node_wait(handle : NodeProcess) -> @js_async.Promise[Int32] =
  #| async h => { const code = await h.exited; if (h.spawnError || h.stdinError) throw new Error(h.spawnError || h.stdinError); return code; }

///|
extern "js" fn node_stop(handle : NodeProcess) -> @js_async.Promise[Unit] =
  #| async h => {
  #|   h.p.stdin.destroy();
  #|   let timer;
  #|   try {
  #|     if (!h.settled) {
  #|       h.p.kill('SIGTERM');
  #|       timer = setTimeout(() => { if (!h.settled) h.p.kill('SIGKILL'); }, 1000);
  #|     }
  #|     await h.exited;
  #|   } finally {
  #|     clearTimeout(timer);
  #|     h.p.stdout.destroy(); h.p.stderr.destroy();
  #|   }
  #| }

///|
#external
priv type CancelWrap

///|
extern "js" fn cancel_wrap(signal : @js_async.AbortSignal) -> CancelWrap =
  #| signal => promise => new Promise((resolve, reject) => {
  #|   const abort = () => reject(new DOMException('process wait cancelled', 'AbortError'));
  #|   signal.addEventListener('abort', abort, {once: true});
  #|   const finish = f => value => { signal.removeEventListener('abort', abort); f(value); };
  #|   promise.then(finish(resolve), finish(reject));
  #|   if (signal.aborted) abort();
  #| })

///|
extern "js" fn CancelWrap::text(
  self : CancelWrap,
  promise : @js_async.Promise[String],
) -> @js_async.Promise[String] =
  #| (wrap, promise) => wrap(promise)

///|
extern "js" fn CancelWrap::unit(
  self : CancelWrap,
  promise : @js_async.Promise[Unit],
) -> @js_async.Promise[Unit] =
  #| (wrap, promise) => wrap(promise)

///|
extern "js" fn CancelWrap::int(
  self : CancelWrap,
  promise : @js_async.Promise[Int32],
) -> @js_async.Promise[Int32] =
  #| (wrap, promise) => wrap(promise)

///|
priv struct JsProcess {
  raw : NodeProcess
}

///|
async fn JsProcess::read(self : JsProcess, stderr : Bool) -> Bytes? {
  let text = @js_async.run_promise(signal => {
    cancel_wrap(signal).text(node_read(self.raw, stderr))
  })
  if text == "" {
    return None
  }
  let items = match @json.parse(text) {
    Array(items) => items
    _ => raise Failure::Failure("invalid process byte envelope")
  }
  Some(
    Bytes::from_array(
      items.map(item => {
        match item {
          Number(n, ..) if n >= 0.0 && n <= 255.0 && n == n.to_int().to_double() =>
            n.to_int().to_byte()
          _ => raise Failure::Failure("invalid process byte")
        }
      }),
    ),
  )
}

///|
impl GuestProcess for JsProcess with fn write(self, bytes) {
  @js_async.run_promise(signal => {
    cancel_wrap(signal).unit(node_write(self.raw, bytes.to_fixedarray()))
  })
}

///|
impl GuestProcess for JsProcess with fn stdout(self) {
  self.read(false)
}

///|
impl GuestProcess for JsProcess with fn stderr(self) {
  self.read(true)
}

///|
impl GuestProcess for JsProcess with fn wait(self) {
  @js_async.run_promise(signal => cancel_wrap(signal).int(node_wait(self.raw)))
}

///|
async fn[X] with_process(
  command : String,
  args : Array[String],
  cwd : String?,
  inherit_env : Bool,
  body : async (&GuestProcess) -> X,
) -> X {
  let raw = open_node_process(
    node_spawn,
    command,
    FixedArray::from_array(args),
    cwd.unwrap_or(""),
    inherit_env,
  )
  @async.with_task_group(group => {
    group.add_defer(() => {
      @async.protect_from_cancel(() => node_stop(raw).wait())
    })
    body(JsProcess::{ raw, })
  })
}
