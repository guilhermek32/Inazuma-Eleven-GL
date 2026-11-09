// Shared helpers for the service-level e2e scripts: lobby/stats HTTP calls
// through the gateway, a minimal NetProtocol v1 WebSocket player (Node's
// built-in WebSocket; it only sends HELLO and watches events, so its team
// stands still), polling and PASS/FAIL bookkeeping.

export const checks = [];
export function check(ok, name) {
  checks.push(!!ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  return !!ok;
}
export const allPassed = () => checks.length > 0 && checks.every(Boolean);

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function waitFor(fn, ms, every = 500) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const v = await fn();
    if (v) return v;
    await sleep(every);
  }
  return await fn();
}

export async function api(base, method, path, body) {
  const res = await fetch(base + path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* not JSON */ }
  return { status: res.status, body: json };
}

export const requestId = () => crypto.randomUUID();

export async function createAndJoin(base, half = 30, names = ["RedE2E", "BlueE2E"]) {
  const created = await api(base, "POST", "/api/lobby/v1/rooms", { nickname: names[0], half_length_s: half, request_id: requestId() });
  const joined = created.status === 201
    ? await api(base, "POST", `/api/lobby/v1/rooms/${created.body.room_code}/join`, { nickname: names[1], request_id: requestId() })
    : { status: 0, body: null };
  return { created, joined };
}

export const roomStatus = async (base, code) => (await api(base, "GET", `/api/lobby/v1/rooms/${code}`)).body?.status;

/** Every recent-match entry for matchId, scanning all pages. */
export async function recentEntries(base, matchId) {
  const found = [];
  let cursor = null;
  for (let page = 0; page < 50; page++) {
    const q = cursor ? `?limit=100&cursor=${encodeURIComponent(cursor)}` : "?limit=100";
    const r = await api(base, "GET", `/api/stats/v1/matches/recent${q}`);
    if (r.status !== 200) return null;
    found.push(...r.body.items.filter((m) => m.match_id === matchId));
    cursor = r.body.next_cursor;
    if (!cursor) break;
  }
  return found;
}

/** A protocol-level player: HELLO with `token`, then records WELCOME, events and the close. */
export function wsPlayer(base, matchId, token) {
  const url = base.replace(/^http/, "ws") + `/ws/game/${matchId}`;
  const p = { welcome: null, events: [], error: null, closeCode: null, open: false };
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => {
    p.open = true;
    const tok = new TextEncoder().encode(token);
    const hello = new Uint8Array(4 + tok.length);
    hello.set([1, 1, tok.length & 0xff, tok.length >> 8]);
    hello.set(tok, 4);
    ws.send(hello);
  };
  ws.onmessage = (m) => {
    if (typeof m.data === "string") return;
    const b = new Uint8Array(m.data);
    const dv = new DataView(m.data);
    const str16 = (at) => [new TextDecoder().decode(b.subarray(at + 2, at + 2 + dv.getUint16(at, true))), at + 2 + dv.getUint16(at, true)];
    if (b[1] === 2) {
      const [id, at] = str16(2);
      p.welcome = { matchId: id, team: b[at] };
    } else if (b[1] === 5) {
      p.events.push(str16(10)[0]);
    } else if (b[1] === 8) {
      p.error = { code: dv.getUint16(2, true), message: str16(4)[0] };
    }
  };
  ws.onclose = (e) => { p.closeCode = e.code; };
  p.close = () => ws.close();
  p.has = (type) => p.events.includes(type);
  return p;
}
