// Targeted service state-machine tests. OS permission/IME behavior requires UAT.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./harmony-test-sdk.cjs').typescript();
const source = fs.readFileSync(path.join(__dirname,
  '../ohos/entry/src/main/ets/services/ClipboardSync.ets'), 'utf8')
  .replace(/^import .*;$/mg, '').replace('export class ClipboardSync', 'class ClipboardSync');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
const flush = async () => { for (let i = 0; i < 16; i++) await Promise.resolve(); };
function fixture() {
  const state = { text: 'local A', seq: 0, remote: '', sent: [], writes: [], prompts: 0,
    grant: true, listener: null, read: null, readSeqRace: false, reads: 0, allowed: true, statuses: [] };
  const data = text => ({ hasType: () => true, getPrimaryText: () => text });
  const board = {
    on: (_, cb) => { state.listener = cb; }, off: () => { state.listener = null; },
    getData: async () => {
      state.reads++;
      if (state.read) return state.read();
      if (state.readSeqRace) { state.seq++; state.readSeqRace = false; }
      return data(state.text);
    },
    setData: async value => {
      if (state.write) await state.write();
      state.text = value.getPrimaryText(); state.writes.push(state.text);
      if (state.listener) state.listener();
    }
  };
  const native = { isClipboardAllowed: () => state.allowed, getRemoteClipboardSeq: () => state.seq,
    getRemoteClipboardText: () => state.remote,
    sendClipboardText: text => { state.sent.push(text); return 0; } };
  const sandbox = {
    pasteboard: { getSystemPasteboard: () => board, createData: (_, text) => data(text),
      MIMETYPE_TEXT_PLAIN: 'text/plain' },
    abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
      checkAccessTokenSync: () => state.grant ? 0 : -1,
      requestPermissionsFromUser: async () => { state.prompts++; }
    }) },
    bundleManager: { BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
      getBundleInfoForSelfSync: () => ({ appInfo: { accessTokenId: 1 } }) },
    setInterval: () => 1, clearInterval: () => {}
  };
  vm.runInNewContext(js + '; this.Bridge = ClipboardSync;', sandbox);
  const bridge = new sandbox.Bridge();
  const start = () => bridge.start(native, {}, () => true, status => state.statuses.push(status));
  return { state, bridge, start, data };
}
(async () => {
  const f = fixture(); f.start(); await flush();
  assert.deepEqual(f.state.sent, ['local A']);
  f.state.seq = 1; f.state.remote = 'remote B'; f.bridge.refresh(); await flush();
  assert.equal(f.state.text, 'remote B'); assert.deepEqual(f.state.sent, ['local A']);
  f.state.text = 'local C'; f.state.listener(); await flush();
  assert.deepEqual(f.state.sent, ['local A', 'local C']);
  f.state.seq = 2; f.state.remote = 'local A'; f.bridge.refresh(); await flush();
  assert.equal(f.state.text, 'local C', 'delayed echo must not replace newer local copy');
  assert.deepEqual(f.state.writes, ['remote B']);
  f.state.seq = 3; f.state.remote = 'local C'; f.bridge.refresh(); await flush();
  assert.deepEqual(f.state.writes, ['remote B']);
  f.bridge.setForeground(false); f.state.text = 'copied in another app';
  f.state.seq = 4; f.state.remote = 'pending remote'; f.bridge.refresh(); await flush();
  assert.equal(f.state.sent.length, 2);
  f.bridge.setForeground(true); await flush();
  assert.equal(f.state.sent.at(-1), 'copied in another app');
  assert.equal(f.state.text, 'copied in another app');
  f.bridge.refresh(); await flush(); assert.equal(f.state.text, 'copied in another app');
  f.bridge.stop(); assert.equal(f.state.listener, null);

  const denied = fixture(); denied.state.grant = false; denied.start(); await flush();
  denied.bridge.refresh(); await flush(); denied.bridge.stop(); denied.start(); await flush();
  assert.equal(denied.state.prompts, 1); assert.equal(denied.state.sent.length, 0);
  denied.state.seq = 1; denied.state.remote = 'receive without read permission';
  denied.bridge.refresh(); await flush(); assert.equal(denied.state.writes.length, 1);
  denied.state.grant = true; denied.state.text = 'permission restored';
  denied.bridge.refresh(); await flush(); assert.equal(denied.state.sent.at(-1), 'permission restored');
  denied.bridge.stop();

  const stopped = fixture(); let resolve;
  stopped.state.read = () => new Promise(r => { resolve = r; });
  stopped.start(); await flush(); stopped.bridge.stop();
  resolve(stopped.data('must not send')); await flush(); assert.equal(stopped.state.sent.length, 0);

  const racing = fixture(); racing.state.readSeqRace = true; racing.start(); await flush();
  assert.equal(racing.state.sent.length, 0, 'remote generation change during read defers send');
  racing.bridge.stop();

  const unreadable = fixture(); unreadable.state.read = async () => { throw new Error('read restricted'); };
  unreadable.state.seq = 1; unreadable.state.remote = 'remote with local read failure';
  unreadable.start(); await flush();
  assert.equal(unreadable.state.text, 'remote with local read failure');
  assert.equal(unreadable.state.sent.length, 0);
  assert.match(unreadable.state.statuses.at(-1), /本地读取暂不可用/);
  unreadable.bridge.stop();

  const empty = fixture(); empty.state.seq = 1; empty.state.remote = '';
  empty.start(); await flush(); empty.bridge.refresh(); await flush();
  assert.equal(empty.state.sent.length, 0, 'empty remote snapshot must not be overwritten by old local content');
  assert.equal(empty.state.writes.length, 0);
  empty.state.text = 'fresh after empty'; empty.bridge.refresh(); await flush();
  assert.deepEqual(empty.state.sent, ['fresh after empty']); empty.bridge.stop();

  const emptyUnreadable = fixture(); emptyUnreadable.state.seq = 1;
  emptyUnreadable.state.read = async () => { throw new Error('no read'); };
  emptyUnreadable.start(); await flush(); emptyUnreadable.state.read = null;
  emptyUnreadable.bridge.refresh(); await flush();
  assert.equal(emptyUnreadable.state.sent.length, 0, 'read recovery must baseline old local data after empty remote');
  emptyUnreadable.bridge.stop();

  const gated = fixture(); gated.state.allowed = false; gated.start(); await flush();
  assert.equal(gated.state.reads, 0); assert.equal(gated.state.writes.length, 0);
  assert.equal(gated.state.sent.length, 0); assert.match(gated.state.statuses.at(-1), /远端已禁用/);
  gated.state.allowed = true; gated.bridge.refresh(); await flush();
  assert.deepEqual(gated.state.sent, ['local A']); gated.bridge.stop();

  const revoked = fixture(); let resolveRevoked;
  revoked.state.read = () => new Promise(resolve => { resolveRevoked = resolve; });
  revoked.start(); await flush(); revoked.state.allowed = false;
  resolveRevoked(revoked.data('must not send after revoke')); await flush();
  assert.equal(revoked.state.sent.length, 0); assert.equal(revoked.state.writes.length, 0);
  revoked.bridge.stop();

  const restarted = fixture(); let settleWrite;
  restarted.state.seq = 1; restarted.state.remote = 'old remote';
  restarted.state.write = () => new Promise(resolve => { settleWrite = resolve; });
  restarted.start(); await flush(); restarted.bridge.stop();
  restarted.state.seq = 2; restarted.state.remote = 'new remote';
  restarted.start(); await flush();
  assert.equal(restarted.state.reads, 1, 'new epoch must wait for submitted OS write');
  restarted.state.write = null; settleWrite(); await flush();
  restarted.bridge.refresh(); await flush();
  assert.deepEqual(restarted.state.writes, ['old remote', 'new remote']);
  assert.equal(restarted.state.text, 'new remote'); restarted.bridge.stop();

  const restored = fixture(); let settleRead;
  restored.state.read = () => new Promise(resolve => { settleRead = resolve; });
  restored.start(); await flush(); restored.state.allowed = false; restored.bridge.refresh();
  restored.state.allowed = true; restored.bridge.refresh();
  settleRead(restored.data('invalidated across revoke and restore')); await flush();
  assert.equal(restored.state.sent.length, 0); restored.bridge.stop();

  const budget = fixture(); budget.start(); await flush();
  for (let i = 0; i < 6; i++) {
    budget.state.text = String(i).repeat(2 * 1024 * 1024);
    budget.bridge.refresh(); await flush();
  }
  assert.ok(budget.bridge.pendingEchoes.reduce((total, value) => total + value.length, 0) <= 8 * 1024 * 1024);
  budget.state.text = 'x'; budget.bridge.refresh(); await flush();
  budget.state.text = 'y'; budget.bridge.refresh(); await flush();
  budget.state.text = 'x'; budget.bridge.refresh(); await flush();
  assert.equal(budget.bridge.pendingEchoes.filter(value => value === 'x').length, 1);
  budget.bridge.stop();
  console.log('PASS: sync, echo/conflict, permission/recovery, cancellation/races, read failure, empty snapshots, remote gate, ownership budget');
})().catch(error => { console.error(error); process.exitCode = 1; });
