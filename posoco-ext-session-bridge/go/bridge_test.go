package sessionbridge

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "net"
    "testing"
    "time"
)

func event(session,kind,epoch string,cursor int,busy bool)json.RawMessage{
    b,_:=json.Marshal(map[string]any{
        "type":kind,"session_id":session,"runtime_epoch":epoch,
        "cursor":cursor,"high_water_cursor":cursor,
        "cursor_advance":kind!="session.snapshot","busy":busy,
    })
    return b
}

func TestObserveWorkingAndLiveOutput(t *testing.T){
    ownerPeer,viewerPeer:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second)
    defer cancel()
    events:=make(chan json.RawMessage,3)
    done:=make(chan error,1)
    go func(){
        done<-ServeConn(ctx,ownerPeer,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(_ context.Context,id string)(Subscription,error){
                if id!="session-a"{return Subscription{},errors.New("not owned")}
                return Subscription{Snapshot:event(id,"session.snapshot","epoch",3,true),
                    Events:events},nil
            })
    }()
    viewer,err:=ObserveConn(ctx,viewerPeer,"session-a","viewer")
    if err!=nil{t.Fatal(err)}
    defer viewer.Close()
    var state struct{Busy bool}
    if err:=json.Unmarshal(viewer.Snapshot,&state);err!=nil{
        t.Fatal(err)
    }
    // The wire uses lower-case busy and Go matches fields case-insensitively.
    if !state.Busy{t.Fatal("second terminal did not see existing working state")}
    events<-event("session-a","assistant.text_delta","epoch",4,true)
    events<-event("session-a","turn.completed","epoch",5,false)
    for _,want:=range []string{"assistant.text_delta","turn.completed"}{
        raw,err:=viewer.Next()
        if err!=nil{t.Fatal(err)}
        var frame map[string]json.RawMessage
        _=json.Unmarshal(raw,&frame)
        if kind:=stringField(frame,"type");kind!=want{t.Fatalf("got %q, want %q",kind,want)}
    }
    close(events)
    _=viewer.Close()
    select{
    case <-done:
    case <-time.After(2*time.Second):t.Fatal("subscription did not terminate")
    }
}

func TestMutationRefusedBeforeSubscription(t *testing.T){
    server,client:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),2*time.Second)
    defer cancel()
    touched:=make(chan struct{},1)
    done:=make(chan error,1)
    go func(){
        done<-ServeConn(ctx,server,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(context.Context,string)(Subscription,error){
                touched<-struct{}{}
                return Subscription{},errors.New("should not attach")
            })
    }()
    c:=newCodec(client,client)
    err:=c.write(map[string]any{"type":"hello","protocol":Protocol,"host":"go",
        "client_instance_id":"client","capabilities":[]string{Capability}})
    if err!=nil{t.Fatal(err)}
    welcome,err:=c.read()
    if err!=nil||stringField(welcome,"type")!="welcome"{t.Fatalf("handshake: %v",err)}
    err=c.write(map[string]any{"type":"request","request_id":"req","command":"turn_start",
        "args":map[string]string{"prompt":"do not run"}})
    if err!=nil{t.Fatal(err)}
    refusal,err:=c.read()
    if err!=nil||stringField(refusal,"type")!="reject"{t.Fatalf("mutation not refused: %+v %v",refusal,err)}
    if err:=<-done;!errors.Is(err,ErrProtocol){t.Fatalf("owner did not fail closed: %v",err)}
    select{case <-touched:t.Fatal("mutating request reached owner subscription");default:}
    _=client.Close()
}

func TestForeignSessionNeverCreatesOwner(t *testing.T){
    server,client:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),2*time.Second)
    defer cancel()
    go func(){
        _=ServeConn(ctx,server,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(context.Context,string)(Subscription,error){return Subscription{},errors.New("session not owned")})
    }()
    if _,err:=ObserveConn(ctx,client,"foreign-session","client");!errors.Is(err,ErrProtocol){
        t.Fatalf("foreign session accepted: %v",err)
    }
}

// A typed not-composed refusal must survive the wire: the owner writes the
// machine-readable code, and the viewer's error unwraps to the sentinel so
// hosts can fall back to a local writable Session safely.
func TestNotComposedRejectCarriesTypedSentinel(t *testing.T){
    server,client:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),2*time.Second)
    defer cancel()
    go func(){
        _=ServeConn(ctx,server,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(context.Context,string)(Subscription,error){
                return Subscription{},fmt.Errorf("%w: Session is not composed in this Runtime",ErrSessionNotComposed)
            })
    }()
    _,err:=ObserveConn(ctx,client,"never-composed","client")
    if !errors.Is(err,ErrSessionNotComposed){
        t.Fatalf("typed refusal lost on the wire: %v",err)
    }
    _=server.Close()
}

func TestReplayConnectionPagesHistory(t *testing.T){
    ownerPeer,viewerPeer:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second)
    defer cancel()
    type call struct{session,command string;args json.RawMessage}
    calls:=make(chan call,4)
    done:=make(chan error,1)
    go func(){
        done<-ServeConnWithReplay(ctx,ownerPeer,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(_ context.Context,id string)(Subscription,error){
                return Subscription{},errors.New("observe unexpected on replay connection")
            },
            func(_ context.Context,session,command string,args json.RawMessage)(json.RawMessage,error){
                calls<-call{session,command,args}
                return json.RawMessage(`{"blocks":2}`),nil
            })
    }()
    client,err:=DialReplay(ctx,viewerPeer,"session-a","viewer")
    if err!=nil{t.Fatal(err)}
    defer client.Close()
    result,err:=client.Call(ctx,"transcript_page",json.RawMessage(`{"session_id":"session-a","first":0,"limit":100}`))
    if err!=nil{t.Fatal(err)}
    if string(result)!=`{"blocks":2}`{t.Fatalf("unexpected page payload %s",result)}
    if _,err:=client.Call(ctx,"transcript_index",json.RawMessage(`{"session_id":"session-a"}`));err!=nil{
        t.Fatal(err)
    }
    select{
    case got:=<-calls:
        if got.session!="session-a"||got.command!="transcript_page"||
           string(got.args)!=`{"session_id":"session-a","first":0,"limit":100}`{
            t.Fatalf("owner saw %+v",got)
        }
    default:
        t.Fatal("owner replay callback never ran")
    }
    _=client.Close()
    select{
    case <-done:
    case <-time.After(2*time.Second):t.Fatal("replay connection did not terminate")
    }
}

func TestReplayClientRefusesForeignSessionAndWrites(t *testing.T){
    ownerPeer,viewerPeer:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second)
    defer cancel()
    go func(){
        _=ServeConnWithReplay(ctx,ownerPeer,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(_ context.Context,_ string)(Subscription,error){
                return Subscription{},errors.New("observe unexpected on replay connection")
            },
            func(_ context.Context,_,_ string,_ json.RawMessage)(json.RawMessage,error){
                return json.RawMessage(`{}`),nil
            })
        _=ownerPeer.Close()
    }()
    client,err:=DialReplay(ctx,viewerPeer,"session-a","viewer")
    if err!=nil{t.Fatal(err)}
    defer client.Close()
    if _,err:=client.Call(ctx,"transcript_page",json.RawMessage(`{"session_id":"session-b"}`));!errors.Is(err,ErrProtocol){
        t.Fatalf("foreign session accepted: %v",err)
    }
    if _,err:=client.Call(ctx,"turn_start",json.RawMessage(`{"session_id":"session-a"}`));!errors.Is(err,ErrProtocol){
        t.Fatalf("write command accepted: %v",err)
    }
}

func TestReplayNeedsOwnerSupport(t *testing.T){
    ownerPeer,viewerPeer:=net.Pipe()
    ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second)
    defer cancel()
    go func(){
        _=ServeConn(ctx,ownerPeer,Owner{InstanceID:"owner",RuntimeEpoch:"epoch"},
            func(_ context.Context,_ string)(Subscription,error){
                return Subscription{},errors.New("unused")
            })
    }()
    if _,err:=DialReplay(ctx,viewerPeer,"session-a","viewer");!errors.Is(err,ErrProtocol){
        t.Fatalf("replay dial without owner support: %v",err)
    }
}
