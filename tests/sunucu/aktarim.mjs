const B = 'https://api.oalabs.dev', W = 'wss://api.oalabs.dev';
const box = 'test_' + Math.random().toString(36).slice(2).padEnd(22, 'x') + 'abcdefgh';
const wait = (ms) => new Promise(r => setTimeout(r, ms * 4));
function conn(d) {
  const ws = new WebSocket(`${W}/v1/kopru/ws/${box}?d=${d}`);
  const got = [];
  ws.onmessage = (e) => got.push(e.data === 'pong' ? { t: 'pong' } : JSON.parse(e.data));
  return new Promise((res, rej) => { ws.onopen = () => res({ ws, got }); ws.onerror = rej; });
}
const ok = (c, m) => { console.log((c ? 'GEÇTİ ' : 'KALDI ') + m); if (!c) process.exitCode = 1; };

const A = await conn('cihazA0001');
await wait(200);
ok(A.got[0]?.t === 'hello', 'A hello aldı');
// B yokken A ileti gönderir -> kuyruk
A.ws.send(JSON.stringify({ t: 'msg', to: 'cihazB0001', data: 'SIFRELI1', id: 'm1' }));
await wait(200);
ok(A.got.some(m => m.t === 'ack' && m.id === 'm1' && m.live === false), 'B yokken kuyruğa alındı');
const Bc = await conn('cihazB0001');
await wait(300);
ok(Bc.got.some(m => m.t === 'msg' && m.data === 'SIFRELI1' && m.from === 'cihazA0001' && m.queued), 'B bağlanınca bekleyen iletiyi aldı');
ok(A.got.some(m => m.t === 'presence' && m.d === 'cihazB0001' && m.on), 'A, B\'nin geldiğini gördü');
ok(Bc.got[0]?.online?.includes('cihazA0001'), 'B hello listesinde A var');
// canlı ileti
Bc.ws.send(JSON.stringify({ t: 'msg', to: 'cihazA0001', data: 'SIFRELI2', id: 'm2' }));
await wait(200);
ok(A.got.some(m => m.t === 'msg' && m.data === 'SIFRELI2'), 'A canlı iletiyi aldı');
ok(Bc.got.some(m => m.t === 'ack' && m.id === 'm2' && m.live), 'B canlı ack aldı');
// ping
Bc.ws.send('ping'); await wait(150); ok(Bc.got.some(m => m.t === 'pong'), 'ping yanıtlandı');
// B ayrılır
Bc.ws.close(); await wait(300);
ok(A.got.some(m => m.t === 'presence' && m.d === 'cihazB0001' && m.on === false), 'A, B\'nin ayrıldığını gördü');
// dosya
const data = new Uint8Array(300000).map((_, i) => i % 251);
let r = await fetch(`${B}/v1/kopru/file/${box}/dosya12345`, { method: 'PUT', body: data, headers: { 'Content-Length': String(data.length) } });
ok(r.status === 200, 'dosya yüklendi ' + r.status);
r = await fetch(`${B}/v1/kopru/file/${box}/dosya12345`);
const back = new Uint8Array(await r.arrayBuffer());
ok(back.length === data.length && back.every((v, i) => v === data[i]), 'dosya aynen geri geldi');
r = await fetch(`${B}/v1/kopru/file/${box}/dosya12345`, { method: 'DELETE' });
r = await fetch(`${B}/v1/kopru/file/${box}/dosya12345`);
ok(r.status === 404, 'silindi');
r = await fetch(`${B}/v1/kopru/ws/kisa`);
ok(r.status === 404 || r.status === 426, 'geçersiz kutu reddedildi ' + r.status);
r = await fetch(`${B}/v1/kopru/ws/${box}`);
ok(r.status === 426, 'WebSocket olmadan 426');
A.ws.close();
process.exit();
