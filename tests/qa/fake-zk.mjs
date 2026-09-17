#!/usr/bin/env node
/* A minimal fake ZKTeco terminal (TCP) for A13: answers CMD_CONNECT, hands one
   40-byte attendance record on CMD_PREPARE_BUFFER, and acknowledges everything
   else. Usage: node fake-zk.mjs [port] — default 43700. */
import net from 'node:net';

const port = Number(process.argv[2] ?? 43700);
const MAGIC = Buffer.from([0x50, 0x50, 0x82, 0x7d]);
const CMD_CONNECT = 1000, CMD_PREPARE_BUFFER = 1503, CMD_DATA = 1501, ACK_OK = 2000;
const SESSION = 0x1234;

function checksum(payload) {
  let sum = 0;
  for (let i = 0; i + 1 < payload.length; i += 2) sum += payload.readUInt16LE(i);
  if (payload.length % 2) sum += payload[payload.length - 1];
  while (sum > 0xffff) sum = (sum & 0xffff) + (sum >>> 16);
  return (~sum) & 0xffff;
}
function packet(cmd, replyId, data = Buffer.alloc(0)) {
  const payload = Buffer.alloc(8 + data.length);
  payload.writeUInt16LE(cmd, 0);
  payload.writeUInt16LE(SESSION, 4);
  payload.writeUInt16LE(replyId, 6);
  data.copy(payload, 8);
  payload.writeUInt16LE(checksum(payload), 2);
  const out = Buffer.alloc(8 + payload.length);
  MAGIC.copy(out, 0); out.writeUInt32LE(payload.length, 4); payload.copy(out, 8);
  return out;
}
/* ZK time encoding: ((((y-2000)*12+(m-1))*31+(d-1))*24+h)*60+min)*60+s */
function encodeTime(y, m, d, h, mi, s) {
  return ((((((y - 2000) * 12 + (m - 1)) * 31 + (d - 1)) * 24 + h) * 60 + mi) * 60 + s) >>> 0;
}
function record40(pin, time, state) {
  const r = Buffer.alloc(40);
  r.writeUInt16LE(1, 0);
  r.write(pin, 2, 24, 'ascii');
  r.writeUInt32LE(time, 27);
  r[31] = state;
  return r;
}
const RECORD = record40('QA-UNMAPPED', encodeTime(2026, 7, 1, 8, 0, 0), 0);

const server = net.createServer((sock) => {
  let buf = Buffer.alloc(0);
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 8) {
      if (!buf.subarray(0, 4).equals(MAGIC)) { sock.destroy(); return; }
      const len = buf.readUInt32LE(4);
      if (buf.length < 8 + len) return;
      const payload = buf.subarray(8, 8 + len); buf = buf.subarray(8 + len);
      const cmd = payload.readUInt16LE(0), replyId = payload.readUInt16LE(6);
      let reply;
      if (cmd === CMD_CONNECT) reply = packet(ACK_OK, replyId);
      else if (cmd === CMD_PREPARE_BUFFER) reply = packet(CMD_DATA, replyId, RECORD);
      else reply = packet(ACK_OK, replyId);
      console.log(`fake-zk: cmd ${cmd} -> reply ${reply.readUInt16LE(8)}`);
      sock.write(reply);
    }
  });
  sock.on('error', () => {});
});
server.listen(port, '127.0.0.1', () => console.log(`fake-zk listening on 127.0.0.1:${port}`));
