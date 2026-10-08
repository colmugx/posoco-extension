///|
fn board_placeholder_page() -> String {
  let page =
    #|<!doctype html><html><head><meta charset="utf-8"><title>Posoco Board diagnostics</title></head>
    #|<body><main><h1>Board diagnostics</h1><p id="status">connecting</p><pre id="events"></pre></main>
    #|<script>(()=>{
    #|const status=document.getElementById('status'), output=document.getElementById('events');
    #|const token=new URLSearchParams(location.search).get('token');
    #|if(!token){status.textContent='missing bootstrap token';return;}
    #|const key='board.cursor.'+location.host, valid=n=>Number.isSafeInteger(n)&&n>=0;
    #|let seq=0, boardrev=0, tasks=0, attempts=0, hasBoard=false, lines=[], socket=null, timer=null, stopped=false, suspended=false, delay=250;
    #|try{const saved=Number(sessionStorage.getItem(key));if(valid(saved))seq=saved;}catch(_){}
    #|const cursor=n=>{seq=n;try{sessionStorage.setItem(key,String(n));}catch(_){}};
    #|const show=s=>{status.textContent=s+' | board '+boardrev+' | tasks '+tasks+' | attempts '+attempts+' | seq '+seq;};
    #|const line=e=>('seq '+e.seq+' | rev '+e.board_revision+' | kind '+String(e.kind)+' | scope '+JSON.stringify(e.scope??null)).slice(0,512);
    #|const render=()=>{output.textContent=lines.join('\n');};
    #|const reset=(ws,s)=>{cursor(0);hasBoard=false;boardrev=0;tasks=0;attempts=0;lines=[];render();show(s);ws.close();};
    #|function connect(){
    #|  timer=null;if(stopped||suspended||socket!==null)return;
    #|  const ws=new WebSocket('ws://'+location.host+'/ws?token='+encodeURIComponent(token));socket=ws;
    #|  ws.onopen=()=>{if(socket!==ws||stopped||suspended)return;ws.send(JSON.stringify({type:'hello',protocol_version:1,last_seq:seq,has_board_snapshot:hasBoard}));show('connected; hello sent');};
    #|  ws.onmessage=ev=>{
    #|    if(socket!==ws||ws.readyState!==WebSocket.OPEN||stopped||suspended)return;
    #|    try{
    #|      const f=JSON.parse(ev.data);
    #|      if(f.type==='resync_required'){reset(ws,'resync required');return;}
    #|      if(f.type==='error'){show('protocol error: '+String(f.code).slice(0,80));stopped=true;ws.close();return;}
    #|      if(f.type==='snapshot'){
    #|        if(f.protocol_version!==1||!valid(f.last_seq)||!valid(f.board_revision)||!Array.isArray(f.payload?.events))throw Error();
    #|        const board=f.payload.board;
    #|        if(board===null||typeof board!=='object'||Array.isArray(board))throw Error();
    #|        if(!valid(board.revision)||board.revision!==f.board_revision)throw Error();
    #|        if(!Array.isArray(board.tasks)||!Array.isArray(board.attempts))throw Error();
    #|        const events=f.payload.events, first=f.last_seq-events.length+1;
    #|        if(events.length===0&&f.last_seq!==0)throw Error();
    #|        if(events.length>0){
    #|          if(first<1)throw Error();
    #|          for(let i=0;i<events.length;i++){const e=events[i];if(e.type!=='event'||!valid(e.seq)||e.seq!==first+i)throw Error();}
    #|          lines=events.slice(-100).map(line);
    #|        }else{lines=[];}
    #|        boardrev=f.board_revision;tasks=board.tasks.length;attempts=board.attempts.length;hasBoard=true;
    #|        cursor(f.last_seq);render();show('snapshot');delay=250;
    #|      }else if(f.type==='event'){
    #|        if(!valid(f.seq))throw Error();if(f.seq<=seq)return;
    #|        if(f.seq!==seq+1){reset(ws,'sequence gap; reconnecting');return;}
    #|        cursor(f.seq);if(String(f.kind).startsWith('board.'))hasBoard=false;lines.push(line(f));lines=lines.slice(-100);render();show('live');delay=250;
    #|      }
    #|    }catch(_){reset(ws,'invalid frame; reconnecting');}
    #|  };
    #|  ws.onerror=()=>{if(socket===ws)show('connection error');};
    #|  ws.onclose=()=>{if(socket!==ws)return;socket=null;if(stopped)return;show('disconnected; reconnecting');if(timer===null){timer=setTimeout(connect,delay);delay=Math.min(delay*2,10000);}};
    #|}
    #|addEventListener('pagehide',()=>{suspended=true;if(timer!==null)clearTimeout(timer);timer=null;const old=socket;socket=null;if(old)old.close();});
    #|addEventListener('pageshow',e=>{if(e.persisted&&suspended){suspended=false;delay=250;connect();}});
    #|connect();
    #|})();</script></body></html>
  page
}
