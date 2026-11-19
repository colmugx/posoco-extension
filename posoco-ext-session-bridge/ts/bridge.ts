// Host-neutral Bun/Node adapter for posoco.session/1.
// A caller MUST pass a same-user authenticated Unix socket / named pipe.
// No TCP listener or Agent/SessionStore is created by this module.
import type { Socket } from "node:net";

export const protocol = "posoco.session/1";
export const capability = "session.observe.v1";
const frameLimit = 4 << 20;
const queueLimit = 256;

export type WireFrame = {
  type: string;
  protocol?: string;
  host?: string;
  client_instance_id?: string;
  owner_instance_id?: string;
  runtime_epoch?: string;
  capabilities?: string[];
  request_id?: string;
  command?: string;
  args?: { session_id: string };
  result?: SessionEvent;
  event?: SessionEvent;
  error?: string;
};

export type SessionEvent = {
  type: string;
  session_id: string;
  runtime_epoch: string;
  cursor: number;
  high_water_cursor?: number;
  cursor_advance?: boolean;
  busy?: boolean;
  [key: string]: unknown;
};

export interface OwnerIdentity {
  instanceID: string;
  runtimeEpoch: string;
}

export interface Subscription {
  // Must subscribe BEFORE obtaining the snapshot. The host must buffer
  // live events until the initial snapshot has been sent.
  snapshot: SessionEvent;
  events: AsyncIterable<SessionEvent>;
  close(): void;
}

type Waiter = { resolve: (frame: WireFrame) => void; reject: (error: Error) => void };

class Frames {
  private buffer = Buffer.alloc(0);
  private readonly queue: WireFrame[] = [];
  private readonly waiting: Waiter[] = [];
  private failure: Error | undefined;
  constructor(private readonly socket: Socket) {
    socket.on("data", (chunk: Buffer) => this.feed(chunk));
    socket.on("error", (err: Error) => this.fail(err));
    socket.on("close", () => this.fail(new Error("owner stream closed; resnapshot required")));
  }
  private fail(error: Error): void {
    if (this.failure !== undefined) return;
    this.failure = error;
    this.socket.destroy();
    for (const w of this.waiting.splice(0)) w.reject(error);
  }
  private feed(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const at = this.buffer.indexOf(10);
      if (at < 0) {
        if (this.buffer.length > frameLimit) this.fail(new Error("oversized Posoco frame"));
        return;
      }
      if (at > frameLimit) { this.fail(new Error("oversized Posoco frame")); return; }
      const line = this.buffer.subarray(0, at);
      this.buffer = this.buffer.subarray(at + 1);
      let frame: WireFrame;
      try {
        frame = JSON.parse(line.toString("utf8")) as WireFrame;
        if (frame === null || Array.isArray(frame) || typeof frame.type !== "string") {
          throw new Error("invalid envelope");
        }
      } catch {
        this.fail(new Error("malformed Posoco envelope"));
        return;
      }
      const waiting = this.waiting.shift();
      if (waiting !== undefined) waiting.resolve(frame);
      else if (this.queue.length >= queueLimit) {
        this.fail(new Error("slow Session viewer: bounded queue overflow"));
        return;
      } else this.queue.push(frame);
    }
  }
  async read(): Promise<WireFrame> {
    const frame = this.queue.shift();
    if (frame !== undefined) return frame;
    if (this.failure !== undefined) throw this.failure;
    return new Promise<WireFrame>((resolve, reject) => this.waiting.push({ resolve, reject }));
  }
  async write(frame: WireFrame): Promise<void> {
    if (this.failure !== undefined) throw this.failure;
    const data = Buffer.from(JSON.stringify(frame) + "\n");
    if (data.length > frameLimit) throw new Error("oversized Posoco frame");
    await new Promise<void>((resolve, reject) => {
      this.socket.write(data, (error) => error == null ? resolve() : reject(error));
    });
  }
  close(): void { this.socket.destroy(); }
}

function validSnapshot(value: SessionEvent | undefined, sessionID: string, epoch: string): value is SessionEvent {
  return value !== undefined && value.type === "session.snapshot" &&
    value.session_id === sessionID && value.runtime_epoch === epoch &&
    Number.isSafeInteger(value.cursor) && value.cursor >= 0;
}

// Serve a single read-only Session observer. No command forwarding, journal
// writes, or blind replay of indeterminate operations exists here.
export async function serveSessionSocket(
  socket: Socket,
  owner: OwnerIdentity,
  subscribe: (sessionID: string) => Promise<Subscription>,
): Promise<void> {
  const wire = new Frames(socket);
  try {
    const hello = await wire.read();
    if (hello.type !== "hello" || hello.protocol !== protocol ||
        !hello.client_instance_id || !hello.host ||
        !hello.capabilities?.includes(capability)) {
      await wire.write({ type: "reject", error: "incompatible Session observer protocol" });
      return;
    }
    await wire.write({ type: "welcome", protocol,
      owner_instance_id: owner.instanceID, runtime_epoch: owner.runtimeEpoch,
      capabilities: [capability] });
    const request = await wire.read();
    if (request.type !== "request" || request.command !== "session.observe" ||
        !request.args?.session_id || !request.request_id) {
      await wire.write({ type: "reject", error: "read-only session.observe required" });
      return;
    }
    let sub: Subscription;
    try {
      sub = await subscribe(request.args.session_id);
    } catch (err) {
      await wire.write({ type: "reject", request_id: request.request_id, error: String(err) });
      return;
    }
    try {
      if (!validSnapshot(sub.snapshot, request.args.session_id, owner.runtimeEpoch)) {
        throw new Error("incompatible Session snapshot");
      }
      await wire.write({ type: "response", request_id: request.request_id, result: sub.snapshot });
      for await (const event of sub.events) {
        if (event.session_id !== request.args.session_id ||
            event.runtime_epoch !== owner.runtimeEpoch) {
          throw new Error("foreign Session event");
        }
        await wire.write({ type: "event", event });
      }
    } finally { sub.close(); }
  } finally { wire.close(); }
}

export interface SessionViewer {
  snapshot: SessionEvent;
  owner: OwnerIdentity;
  events(): AsyncIterable<SessionEvent>;
  close(): void;
}

// The caller supplies a connected same-user pipe/socket. A disconnected
// viewer does not compose an Agent or retry accepted mutations.
export async function observeSessionSocket(
  socket: Socket,
  sessionID: string,
  clientID: string,
): Promise<SessionViewer> {
  const wire = new Frames(socket);
  try {
    if (!sessionID || !clientID) throw new Error("missing Session/client identity");
    await wire.write({ type: "hello", protocol, host: "posoco-ext",
      client_instance_id: clientID, capabilities: [capability] });
    const welcome = await wire.read();
    if (welcome.type !== "welcome" || welcome.protocol !== protocol ||
        !welcome.owner_instance_id || !welcome.runtime_epoch ||
        !welcome.capabilities?.includes(capability)) {
      throw new Error("incompatible Session owner");
    }
    await wire.write({ type: "request", request_id: "attach",
      command: "session.observe", args: { session_id: sessionID } });
    const response = await wire.read();
    if (response.type !== "response" || response.request_id !== "attach" ||
        !validSnapshot(response.result, sessionID, welcome.runtime_epoch)) {
      throw new Error("Session owner refused observe or returned an invalid snapshot");
    }
    const owner = { instanceID: welcome.owner_instance_id, runtimeEpoch: welcome.runtime_epoch };
    return {
      snapshot: response.result,
      owner,
      events: async function* (): AsyncIterable<SessionEvent> {
        for (;;) {
          const msg = await wire.read();
          if (msg.type !== "event" || msg.event?.session_id !== sessionID ||
              msg.event.runtime_epoch !== owner.runtimeEpoch) {
            throw new Error("Session feed changed identity; resnapshot required");
          }
          yield msg.event;
        }
      },
      close: () => wire.close(),
    };
  } catch (err) {
    wire.close();
    throw err;
  }
}
