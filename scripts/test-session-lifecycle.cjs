// Targeted lifecycle tests against SessionKeepAlive.ets. These exercise the
// actual service class with mocked OS callbacks and deterministic timers.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./harmony-test-sdk.cjs').typescript();

const source = fs.readFileSync(path.join(__dirname,
  '../ohos/entry/src/main/ets/services/SessionKeepAlive.ets'), 'utf8')
  .replace(/^import .*;$/mg, '')
  .replace('export class SessionKeepAlive', 'class SessionKeepAlive');
const js = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;

function fixture() {
  let nextTimerId = 1;
  const timers = new Map();
  const suspendCallbacks = new Map();
  const cancelledRequests = [];
  let nextRequestId = 1;
  const state = { timers, suspendCallbacks, cancelledRequests, requested: [], logs: [] };
  const sandbox = {
    backgroundTaskManager: {
      requestSuspendDelay: (reason, callback) => {
        const requestId = nextRequestId++;
        state.requested.push({ requestId, reason });
        suspendCallbacks.set(requestId, callback);
        return { requestId, actualDelayTime: 60000 };
      },
      cancelSuspendDelay: requestId => {
        cancelledRequests.push(requestId);
        suspendCallbacks.delete(requestId);
      }
    },
    setTimeout: (callback, delay) => {
      const id = nextTimerId++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout: id => { timers.delete(id); },
    console: {
      info: message => state.logs.push(String(message)),
      warn: message => state.logs.push(String(message))
    }
  };
  vm.runInNewContext(js + '; this.KeepAlive = SessionKeepAlive;', sandbox);
  return {
    KeepAlive: sandbox.KeepAlive,
    state,
    fireTimer(delay) {
      const entry = [...timers.entries()].find(([, timer]) => timer.delay === delay);
      assert.ok(entry, `expected a timer scheduled for ${delay}ms`);
      const [id, timer] = entry;
      timers.delete(id);
      timer.callback();
    },
    fireSuspendCallback(requestId) {
      const callback = suspendCallbacks.get(requestId);
      assert.ok(callback, `expected suspend callback ${requestId}`);
      callback();
    }
  };
}

function handlers(state) {
  return {
    onBackgroundTimeout: () => { state.backgroundTimeouts++; },
    onForegroundResume: () => {
      state.resumes++;
      state.pendingSeenDuringResume = state.KeepAlive.isPendingResume();
    },
    onVisibilityChange: foreground => { state.visibility.push(foreground); }
  };
}

function counters(KeepAlive) {
  return { KeepAlive, backgroundTimeouts: 0, resumes: 0,
    pendingSeenDuringResume: false, visibility: [] };
}

// Ability backgrounded before login finishes and before Session registers
// its callbacks. Registering while hidden must replay hidden state and arm
// the bounded background hold; a later foreground cancels the hold.
{
  const f = fixture();
  f.KeepAlive.onAppBackground();
  const state = counters(f.KeepAlive);
  f.KeepAlive.setActive(true, ...Object.values(handlers(state)));
  assert.equal(f.KeepAlive.isActive(), true);
  assert.ok(state.visibility.includes(false), 'late registration receives hidden state');
  assert.equal(f.state.requested.length, 1, 'late registration starts background hold');
  assert.equal(f.state.timers.size, 1);
  f.KeepAlive.onAppForeground();
  assert.equal(f.KeepAlive.isActive(), true);
  assert.equal(f.KeepAlive.isPendingResume(), false);
  assert.equal(state.backgroundTimeouts, 0);
  assert.equal(state.resumes, 0, 'ordinary foreground return does not reconnect');
  assert.ok(state.visibility.includes(true));
  assert.equal(f.state.timers.size, 0, 'foreground clears hold timer');
  assert.deepEqual(f.state.cancelledRequests, [1]);
}

// A registered session that returns before expiry stays connected and does
// not use the resumable timeout path.
{
  const f = fixture();
  const state = counters(f.KeepAlive);
  const h = handlers(state);
  f.KeepAlive.setActive(true, h.onBackgroundTimeout, h.onForegroundResume, h.onVisibilityChange);
  f.KeepAlive.onAppBackground();
  f.KeepAlive.onAppForeground();
  assert.equal(state.backgroundTimeouts, 0);
  assert.equal(state.resumes, 0);
  assert.equal(f.KeepAlive.isActive(), true);
  assert.equal(f.KeepAlive.isPendingResume(), false);
  assert.equal(f.state.timers.size, 0);
}

// Expiry tears down once, keeps a pending-resume latch visible to the resume
// callback, then consumes it so another foreground cannot repeat the resume.
{
  const f = fixture();
  const state = counters(f.KeepAlive);
  const h = handlers(state);
  f.KeepAlive.setActive(true, h.onBackgroundTimeout, h.onForegroundResume, h.onVisibilityChange);
  f.KeepAlive.onAppBackground();
  f.fireTimer(58500);
  assert.equal(state.backgroundTimeouts, 1);
  assert.equal(f.KeepAlive.isActive(), false);
  assert.equal(f.KeepAlive.isPendingResume(), true);
  f.KeepAlive.onAppForeground();
  assert.equal(state.resumes, 1);
  assert.equal(state.pendingSeenDuringResume, true);
  assert.equal(f.KeepAlive.isPendingResume(), false);
  f.KeepAlive.onAppForeground();
  assert.equal(state.resumes, 1, 'one timeout can only trigger one resume');
}

// Explicit stop clears handlers and the resumable latch; foreground after
// user disconnect must never call the previous session's resume callback.
{
  const f = fixture();
  const state = counters(f.KeepAlive);
  const h = handlers(state);
  f.KeepAlive.setActive(true, h.onBackgroundTimeout, h.onForegroundResume, h.onVisibilityChange);
  f.KeepAlive.onAppBackground();
  f.KeepAlive.setActive(false);
  assert.equal(f.KeepAlive.isActive(), false);
  assert.equal(f.KeepAlive.isPendingResume(), false);
  assert.equal(f.state.timers.size, 0);
  f.KeepAlive.onAppForeground();
  assert.equal(state.backgroundTimeouts, 0);
  assert.equal(state.resumes, 0);
  assert.equal(f.KeepAlive.isPendingResume(), false);
}

console.log('PASS: late background registration, foreground cancellation, timeout resume, explicit stop');
