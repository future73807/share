// 端到端音频验证:驱动 Chrome 标签页(音源播放 + 观众入房)并测量远端音频电平
const WebSocket = require('ws');
const http = require('http');

function getJSON(path) {
  return new Promise((res, rej) => {
    http.get('http://127.0.0.1:9222' + path, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res(JSON.parse(d)));
    }).on('error', rej);
  });
}

function connect(wsUrl, timeoutMs = 4000) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(wsUrl);
    const t = setTimeout(() => { ws.terminate(); rej(new Error('ws 连接超时')); }, timeoutMs);
    ws.on('open', () => { clearTimeout(t); res(ws); });
    ws.on('error', e => { clearTimeout(t); rej(e); });
  });
}

function evalOn(ws, expr, timeoutMs = 15000) {
  return new Promise((res, rej) => {
    const mid = Math.floor(Math.random() * 1e9);
    const t = setTimeout(() => rej(new Error('eval 超时')), timeoutMs);
    const handler = m => {
      const msg = JSON.parse(m.toString());
      if (msg.id === mid) {
        ws.removeListener('message', handler);
        clearTimeout(t);
        if (msg.error) rej(new Error(JSON.stringify(msg.error)));
        else if (msg.result && msg.result.exceptionDetails)
          rej(new Error('页面异常: ' + (msg.result.exceptionDetails.exception?.description || '').slice(0, 300)));
        else res(msg.result?.value);
      }
    };
    ws.on('message', handler);
    ws.send(JSON.stringify({ id: mid, method: 'Runtime.evaluate',
      params: { expression: expr, returnByValue: true, awaitPromise: true, userGesture: true } }));
  });
}

(async () => {
  const pages = (await getJSON('/json')).filter(p => p.type === 'page');
  console.log('标签页数:', pages.length);

  // ── 1. 音源页:开始播放并自测生成电平 ──
  let toneResult = '无 tone 标签';
  for (const page of pages) {
    if (!page.url.includes('tone.html')) continue;
    const ws = await connect(page.webSocketDebuggerUrl);
    toneResult = await evalOn(ws, `(async () => {
      const btn = document.getElementById('b');
      if (!btn) return { err: 'no-button', url: location.href.slice(0, 50) };
      if (btn.textContent.includes('开始')) btn.click();
      if (!window.__tone) {
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        const o = ctx.createOscillator(); const g = ctx.createGain();
        const an = ctx.createAnalyser(); an.fftSize = 1024;
        o.frequency.value = 440; g.gain.value = 0.3;
        o.connect(g); g.connect(an); g.connect(ctx.destination); o.start();
        window.__tone = { ctx, an, buf: new Float32Array(an.fftSize) };
      }
      await new Promise(r => setTimeout(r, 300));
      window.__tone.an.getFloatTimeDomainData(window.__tone.buf);
      let peak = 0; window.__tone.buf.forEach(v => peak = Math.max(peak, Math.abs(v)));
      return { playing: document.getElementById('s').textContent.includes('播放中'),
               ctxState: window.__tone.ctx.state, tonePeak: +peak.toFixed(3) };
    })()`);
    ws.close();
    break;
  }
  console.log('1) 音源:', JSON.stringify(toneResult));

  // ── 2. 观众页:入房(如未入)并等 P2P ──
  let viewerWs = null, viewerInfo = '无观众标签';
  for (const page of pages) {
    if (page.url.includes('tone.html')) continue;
    const ws = await connect(page.webSocketDebuggerUrl).catch(() => null);
    if (!ws) continue;
    let kind = 'other';
    try {
      kind = await evalOn(ws, `document.querySelector('.join-card') ? 'join' :
        (document.querySelector('.meeting-room') ? 'meeting' : 'other')`, 4000);
    } catch (e) { ws.close(); continue; }
    if (kind === 'join') {
      const r = await evalOn(ws, `(async () => {
        const f = document.querySelectorAll('.input-field');
        const set = (el, v) => {
          const st = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          st.call(el, v); el.dispatchEvent(new Event('input', { bubbles: true }));
        };
        set(f[0], '1001'); set(f[1], 'ToneViewer');
        document.querySelector('.join-button').click();
        await new Promise(r2 => setTimeout(r2, 9000));
        return 'joined:' + !!document.querySelector('.meeting-room');
      })()`);
      console.log('2) 观众入房:', JSON.stringify(r));
    }
    if (kind === 'meeting') {
      viewerWs = ws; viewerInfo = '已入房';
      break;
    }
    ws.close();
  }

  // ── 3. 观众端:等 6 秒测音频字节增长 ──
  if (viewerWs) {
    const r = await evalOn(viewerWs, `(async () => {
      const pc = window.__ss ? Array.from(window.__ss.peerConnections.values())[0] : null;
      if (!pc) return { pc: 0 };
      const snap = async () => {
        const stats = await pc.getStats();
        let a = 0, v = 0;
        stats.forEach(s => {
          if (s.type === 'inbound-rtp' && s.kind === 'audio') a = s.bytesReceived;
          if (s.type === 'inbound-rtp' && s.kind === 'video') v = s.bytesReceived;
        });
        return { a, v };
      };
      const s1 = await snap();
      await new Promise(r2 => setTimeout(r2, 6000));
      const s2 = await snap();
      return { pcState: pc.connectionState, audioIn1: s1.a, audioIn2: s2.a,
               audioFlowing: s2.a > s1.a, delta: s2.a - s1.a };
    })()`);
    console.log('3) 观众音频:', JSON.stringify(r));
    viewerWs.close();
  } else {
    console.log('3) 观众:', viewerInfo);
  }
  process.exit(0);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
