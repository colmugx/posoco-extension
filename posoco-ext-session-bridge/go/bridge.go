// Package sessionbridge carries a read-only Session feed over a host-provided
// same-user Unix socket or Windows named pipe. It never owns Agents or journals.
package sessionbridge

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const Protocol = "posoco.session/1"
const Capability = "session.observe.v1"
const ReplayCapability = "session.replay.v1"
const MaxFrameSize = 4 << 20

var ErrProtocol = errors.New("invalid Posoco session bridge protocol")
var ErrResnapshot = errors.New("Session stream requires a new owner snapshot")

// IsReplayCommand reports whether a command belongs to the read-only
// transcript replay family an observe owner may also serve.
func IsReplayCommand(command string) bool {
	return command == "transcript_index" || command == "transcript_page" || command == "transcript_source"
}

// ErrCodeSessionNotComposed is the reject-frame code meaning the owner
// Runtime never composed the requested Session. No live writer exists for
// that Session, so a viewer may safely compose it locally instead of
// failing closed.
const ErrCodeSessionNotComposed = "session_not_composed"

// ErrSessionNotComposed is the typed client counterpart of the wire code
// above. Callers use errors.Is to decide on a local writable fallback.
var ErrSessionNotComposed = errors.New("Session is not composed in the owner Runtime")

type Envelope struct {
	Type             string
	Protocol         string
	Host             string
	ClientInstanceID string
	OwnerInstanceID  string
	RuntimeEpoch     string
	Capabilities     []string
	RequestID        string
	Command          string
	Args             json.RawMessage
	Result           json.RawMessage
	Event            json.RawMessage
	Error            string
}

type codec struct {
	r  *bufio.Reader
	w  io.Writer
	mu sync.Mutex
}

func newCodec(r io.Reader, w io.Writer) *codec {
	return &codec{r: bufio.NewReaderSize(r, 64<<10), w: w}
}
func (c *codec) read() (map[string]json.RawMessage, error) {
	var data []byte
	for {
		p, err := c.r.ReadSlice('\n')
		if len(data)+len(p) > MaxFrameSize+1 {
			return nil, ErrProtocol
		}
		data = append(data, p...)
		if err == nil {
			if len(data) < 2 || data[0] != '{' {
				return nil, ErrProtocol
			}
			var f map[string]json.RawMessage
			if err := json.Unmarshal(data, &f); err != nil {
				return nil, ErrProtocol
			}
			return f, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) && len(data) == 0 {
			return nil, io.EOF
		}
		if errors.Is(err, io.EOF) {
			return nil, ErrProtocol
		}
		return nil, err
	}
}
func (c *codec) write(f any) error {
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	if len(data) > MaxFrameSize {
		return ErrProtocol
	}
	data = append(data, '\n')
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(data) > 0 {
		n, e := c.w.Write(data)
		if e != nil {
			return e
		}
		if n <= 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}
func stringField(f map[string]json.RawMessage, key string) string {
	var value string
	_ = json.Unmarshal(f[key], &value)
	return value
}
func hasCap(raw json.RawMessage, want ...string) bool {
	var values []string
	_ = json.Unmarshal(raw, &values)
	for _, w := range want {
		found := false
		for _, v := range values {
			if v == w {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

type Owner struct{ InstanceID, RuntimeEpoch string }

// Subscribe MUST install its bounded event subscription before taking the
// snapshot. A closed event channel forces reconnection/resnapshot; it must
// never silently discard an overflowing broadcast.
type Subscription struct {
	Snapshot json.RawMessage
	Events   <-chan json.RawMessage
	Close    func()
}
type Subscribe func(context.Context, string) (Subscription, error)

// Replay serves one validated replay-family request for the requested
// session. The result is the raw harness reply payload; an error becomes a
// typed reject frame. Serving joins the owner's existing bounded replay
// discipline (queueing, supersede), never a private unbounded path.
type Replay func(context.Context, string, string, json.RawMessage) (json.RawMessage, error)

// ServeConn only accepts session.observe. OS peer authentication is enforced
// by the host's local listener, never by trusting a client-provided identity.
func ServeConn(ctx context.Context, conn net.Conn, owner Owner, subscribe Subscribe) error {
	return ServeConnWithReplay(ctx, conn, owner, subscribe, nil)
}

// ServeConnWithReplay routes on the first request: session.observe starts the
// snapshot+event stream (which never reads again), a replay-family request
// starts a request/response loop (which never streams). One connection stays
// single-purpose; the event path is unchanged.
func ServeConnWithReplay(ctx context.Context, conn net.Conn, owner Owner, subscribe Subscribe, replay Replay) error {
	defer conn.Close()
	if owner.InstanceID == "" || owner.RuntimeEpoch == "" || subscribe == nil {
		return ErrProtocol
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	c := newCodec(conn, conn)
	hello, err := c.read()
	if err != nil {
		return err
	}
	if stringField(hello, "type") != "hello" || stringField(hello, "protocol") != Protocol ||
		stringField(hello, "host") == "" || stringField(hello, "client_instance_id") == "" ||
		!hasCap(hello["capabilities"], Capability) {
		_ = c.write(map[string]any{"type": "reject", "error": "incompatible Session bridge"})
		return ErrProtocol
	}
	caps := []string{Capability}
	if replay != nil {
		caps = append(caps, ReplayCapability)
	}
	if err := c.write(map[string]any{"type": "welcome", "protocol": Protocol,
		"owner_instance_id": owner.InstanceID, "runtime_epoch": owner.RuntimeEpoch,
		"capabilities": caps}); err != nil {
		return err
	}
	request, err := c.read()
	if err != nil {
		return err
	}
	var args map[string]string
	_ = json.Unmarshal(request["args"], &args)
	sessionID := args["session_id"]
	requestID := stringField(request, "request_id")
	command := stringField(request, "command")
	if stringField(request, "type") != "request" || sessionID == "" || requestID == "" {
		_ = c.write(map[string]any{"type": "reject", "error": "read-only session.observe required"})
		return ErrProtocol
	}
	if replay != nil && IsReplayCommand(command) {
		return serveReplayLoop(ctx, c, replay, request, command, sessionID, requestID)
	}
	if command != "session.observe" {
		_ = c.write(map[string]any{"type": "reject", "error": "read-only session.observe required"})
		return ErrProtocol
	}
	sub, err := subscribe(ctx, sessionID)
	if err != nil {
		reject := map[string]any{"type": "reject", "error": err.Error(), "request_id": requestID}
		if errors.Is(err, ErrSessionNotComposed) {
			reject["code"] = ErrCodeSessionNotComposed
		}
		_ = c.write(reject)
		return err
	}
	if sub.Close != nil {
		defer sub.Close()
	}
	var snap map[string]json.RawMessage
	if json.Unmarshal(sub.Snapshot, &snap) != nil ||
		stringField(snap, "type") != "session.snapshot" ||
		stringField(snap, "session_id") != sessionID ||
		stringField(snap, "runtime_epoch") != owner.RuntimeEpoch {
		return ErrProtocol
	}
	if err := c.write(map[string]any{"type": "response", "request_id": requestID, "result": sub.Snapshot}); err != nil {
		return err
	}
	_ = conn.SetDeadline(time.Time{})
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-sub.Events:
			if !ok {
				return ErrResnapshot
			}
			var f map[string]json.RawMessage
			if json.Unmarshal(event, &f) != nil || stringField(f, "session_id") != sessionID ||
				stringField(f, "runtime_epoch") != owner.RuntimeEpoch {
				return ErrProtocol
			}
			_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if err := c.write(map[string]any{"type": "event", "event": json.RawMessage(event)}); err != nil {
				return err
			}
		}
	}
}

// serveReplayLoop answers replay-family requests one at a time until the
// client closes the connection or the owner context ends. Each request is
// validated against the family before it reaches the owner's replay path.
func serveReplayLoop(ctx context.Context, c *codec, replay Replay, first map[string]json.RawMessage, command, sessionID, requestID string) error {
	request := first
	for {
		if !IsReplayCommand(command) {
			_ = c.write(map[string]any{"type": "reject", "request_id": requestID,
				"error": "read-only transcript replay required"})
			return ErrProtocol
		}
		result, err := replay(ctx, sessionID, command, request["args"])
		if err != nil {
			_ = c.write(map[string]any{"type": "reject", "request_id": requestID, "error": err.Error()})
		} else if err := c.write(map[string]any{"type": "response", "request_id": requestID, "result": result}); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		var readErr error
		request, readErr = c.read()
		if readErr != nil {
			return readErr
		}
		var args map[string]string
		_ = json.Unmarshal(request["args"], &args)
		command = stringField(request, "command")
		sessionID = args["session_id"]
		requestID = stringField(request, "request_id")
		if stringField(request, "type") != "request" || sessionID == "" || requestID == "" {
			return ErrProtocol
		}
	}
}

// ObserveConn returns the authoritative snapshot before any streamed events.
// Its session is read-only; a disconnect never creates a competing Agent.
type Observer struct {
	conn      net.Conn
	codec     *codec
	Snapshot  json.RawMessage
	Epoch     string
	SessionID string
}

func (o *Observer) Close() error { return o.conn.Close() }
func (o *Observer) Next() (json.RawMessage, error) {
	frame, err := o.codec.read()
	if err != nil {
		return nil, err
	}
	if stringField(frame, "type") != "event" {
		return nil, ErrProtocol
	}
	var event map[string]json.RawMessage
	if json.Unmarshal(frame["event"], &event) != nil ||
		stringField(event, "session_id") != o.SessionID ||
		stringField(event, "runtime_epoch") != o.Epoch {
		return nil, ErrProtocol
	}
	return frame["event"], nil
}
func ObserveConn(ctx context.Context, conn net.Conn, sessionID, clientID string) (*Observer, error) {
	fail := func(err error) (*Observer, error) { _ = conn.Close(); return nil, err }
	if sessionID == "" || clientID == "" {
		return fail(ErrProtocol)
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	c := newCodec(conn, conn)
	if err := c.write(map[string]any{"type": "hello", "protocol": Protocol, "host": "posoco-ext",
		"client_instance_id": clientID, "capabilities": []string{Capability}}); err != nil {
		return fail(err)
	}
	welcome, err := c.read()
	if err != nil {
		return fail(err)
	}
	if stringField(welcome, "type") == "reject" {
		return fail(ErrProtocol)
	}
	epoch := stringField(welcome, "runtime_epoch")
	if stringField(welcome, "type") != "welcome" || stringField(welcome, "protocol") != Protocol ||
		epoch == "" || !hasCap(welcome["capabilities"], Capability) {
		return fail(ErrProtocol)
	}
	if err := c.write(map[string]any{"type": "request", "request_id": "attach",
		"command": "session.observe", "args": map[string]string{"session_id": sessionID}}); err != nil {
		return fail(err)
	}
	reply, err := c.read()
	if err != nil {
		return fail(err)
	}
	if stringField(reply, "type") == "reject" {
		if stringField(reply, "code") == ErrCodeSessionNotComposed {
			return fail(fmt.Errorf("%w: %s", ErrSessionNotComposed, stringField(reply, "error")))
		}
		return fail(fmt.Errorf("%w: %s", ErrProtocol, stringField(reply, "error")))
	}
	if stringField(reply, "type") != "response" || stringField(reply, "request_id") != "attach" {
		return fail(ErrProtocol)
	}
	var snap map[string]json.RawMessage
	if json.Unmarshal(reply["result"], &snap) != nil ||
		stringField(snap, "type") != "session.snapshot" ||
		stringField(snap, "session_id") != sessionID ||
		stringField(snap, "runtime_epoch") != epoch {
		return fail(ErrProtocol)
	}
	_ = conn.SetDeadline(time.Time{})
	return &Observer{conn: conn, codec: c, Snapshot: reply["result"], Epoch: epoch, SessionID: sessionID}, nil
}

// ReplayClient is a single-purpose replay connection: every Call sends one
// replay-family request and reads its reply. The bound session is enforced
// on every Call so an observer can never page another Session's journal
// through this client.
type ReplayClient struct {
	conn      net.Conn
	codec     *codec
	mu        sync.Mutex
	sessionID string
	nextID    int
}

func (r *ReplayClient) Close() error { return r.conn.Close() }

func (r *ReplayClient) Call(ctx context.Context, command string, args json.RawMessage) (json.RawMessage, error) {
	if !IsReplayCommand(command) {
		return nil, ErrProtocol
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(args, &fields) != nil {
		return nil, ErrProtocol
	}
	var session string
	_ = json.Unmarshal(fields["session_id"], &session)
	if session != r.sessionID {
		return nil, ErrProtocol
	}
	stop := context.AfterFunc(ctx, func() { _ = r.conn.Close() })
	defer stop()
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextID++
	requestID := fmt.Sprintf("replay-%d", r.nextID)
	if err := r.codec.write(map[string]any{"type": "request", "request_id": requestID,
		"command": command, "args": json.RawMessage(args)}); err != nil {
		return nil, err
	}
	reply, err := r.codec.read()
	if err != nil {
		return nil, err
	}
	if stringField(reply, "type") == "reject" {
		return nil, fmt.Errorf("session replay: %s", stringField(reply, "error"))
	}
	if stringField(reply, "type") != "response" || stringField(reply, "request_id") != requestID {
		return nil, ErrProtocol
	}
	return reply["result"], nil
}

// DialReplay performs the bridge handshake advertising the replay capability
// and returns a client bound to one session. It never attaches the event
// stream; observers keep their observe connection separate.
func DialReplay(ctx context.Context, conn net.Conn, sessionID, clientID string) (*ReplayClient, error) {
	fail := func(err error) (*ReplayClient, error) { _ = conn.Close(); return nil, err }
	if sessionID == "" || clientID == "" {
		return fail(ErrProtocol)
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	c := newCodec(conn, conn)
	if err := c.write(map[string]any{"type": "hello", "protocol": Protocol, "host": "posoco-ext",
		"client_instance_id": clientID, "capabilities": []string{Capability, ReplayCapability}}); err != nil {
		return fail(err)
	}
	welcome, err := c.read()
	if err != nil {
		return fail(err)
	}
	if stringField(welcome, "type") != "welcome" || stringField(welcome, "protocol") != Protocol ||
		stringField(welcome, "runtime_epoch") == "" || !hasCap(welcome["capabilities"], ReplayCapability) {
		return fail(ErrProtocol)
	}
	_ = conn.SetDeadline(time.Time{})
	return &ReplayClient{conn: conn, codec: c, sessionID: sessionID}, nil
}
