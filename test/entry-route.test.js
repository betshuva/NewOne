'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { hasStoredToken, resolveEntryRoute, createAppLoader } =
  require('../flutter_app/web/entry-route');
const base = 'https://betshuva.com/betshuva-app/';
const route = (suffix = '', options = {}) =>
  resolveEntryRoute({ href: base + suffix, baseHref: base, ...options });

test('plain guests go to the public landing without an app boot', () => {
  assert.deepEqual(route(), { bootApp: false, url: base + 'home.html' });
  assert.deepEqual(route('index.html'), { bootApp: false, url: base + 'home.html' });
});

test('only a stored preference string identifies a returning app visitor', () => {
  for (const value of [null, '', 'null', '{}', 'false', '""', '"   "', 'malformed']) {
    assert.equal(hasStoredToken(value), false);
  }
  assert.equal(hasStoredToken('"returning-account-token"'), true);
  assert.equal(route('', { storedToken: '"expired-token"' }).bootApp, true);
});

test('explicit entry, deep links, unknown queries and hashes stay with the app', () => {
  for (const suffix of [
    '?entry=login', '?entry=register', '?entry=intro', '?app=1',
    '?groupInvite=token', '?invite=old', '?verifiedEmail=user%40example.org',
    '?screen=calendar', '?backup=connected', '?futureIntegration=value',
    '?entry=unknown', '#/calendar', 'reset-password?token=reset', 'app/',
  ]) {
    const actual = route(suffix);
    assert.equal(actual.bootApp, true, suffix);
    assert.equal(actual.url, base + suffix, suffix);
  }
});

test('installed app adds app=1 without rewriting existing query bytes or hashes', () => {
  assert.deepEqual(route('', { standalone: true }), {
    bootApp: true, url: base + '?app=1',
  });
  const suffix = '?groupInvite=token&encoded=a%20b%2fc&empty=#/calendar';
  assert.equal(route(suffix, { standalone: true }).url,
    base + '?groupInvite=token&encoded=a%20b%2fc&empty=&app=1#/calendar');
  assert.equal(route('?app=0&entry=login', { standalone: true }).url,
    base + '?app=0&entry=login');
});

function loaderFixture(ready = Promise.resolve()) {
  const events = new Map(), scripts = [], timers = new Map(), calls = [];
  const target = {
    addEventListener: (name, callback) => events.set(name, callback),
    removeEventListener: name => events.delete(name),
  };
  const loader = createAppLoader({
    window: target,
    document: { createElement: () => ({}), body: { appendChild: script => scripts.push(script) } },
    ready, bootstrapSrc: base + 'flutter_bootstrap.js?v=qa-build',
    onLoading: () => calls.push('loading'), onReady: () => calls.push('ready'),
    onError: () => calls.push('error'),
    setTimer: callback => { timers.set(1, callback); return 1; },
    clearTimer: id => timers.delete(id),
  });
  return { loader, events, scripts, timers, calls };
}
const flush = () => new Promise(resolve => setImmediate(resolve));

test('bootstrap waits for cache cleanup and starts once until first frame', async () => {
  let release;
  const fixture = loaderFixture(new Promise(resolve => { release = resolve; }));
  const first = fixture.loader.start(), second = fixture.loader.start();
  assert.equal(first, second);
  await flush();
  assert.equal(fixture.scripts.length, 0);
  release(); await flush();
  assert.equal(fixture.scripts.length, 1);
  assert.equal(fixture.scripts[0].src, base + 'flutter_bootstrap.js?v=qa-build');
  assert.deepEqual(fixture.calls, ['loading']);
  fixture.events.get('flutter-first-frame')(); await first;
  assert.deepEqual(fixture.calls, ['loading', 'ready']);
  assert.equal(fixture.events.size, 0);
  assert.equal(fixture.timers.size, 0);
  assert.equal(fixture.loader.start(), first);
});

test('cache-cleanup failure does not prevent a valid app launch', async () => {
  const fixture = loaderFixture(Promise.reject(new Error('storage unavailable')));
  const pending = fixture.loader.start(); await flush();
  assert.equal(fixture.scripts.length, 1);
  fixture.events.get('flutter-first-frame')(); await pending;
});

test('bootstrap failure reports an error and never creates a second engine', async () => {
  const fixture = loaderFixture();
  const pending = fixture.loader.start();
  const rejected = assert.rejects(pending, /bootstrap_load_failed/);
  await flush(); fixture.scripts[0].onerror(); await rejected;
  assert.deepEqual(fixture.calls, ['loading', 'error']);
  assert.equal(fixture.events.size, 0);
  assert.equal(fixture.timers.size, 0);
  assert.equal(fixture.loader.start(), pending);
  assert.equal(fixture.scripts.length, 1);
});

test('engine errors and stalled startup offer the same retry state', async () => {
  for (const method of ['reported', 'timeout']) {
    const fixture = loaderFixture();
    const pending = fixture.loader.start();
    const rejected = assert.rejects(pending);
    if (method === 'reported') fixture.loader.reportFailure(new Error('engine failed'));
    else fixture.timers.get(1)();
    await rejected; await flush();
    assert.deepEqual(fixture.calls, ['loading', 'error']);
    assert.equal(fixture.scripts.length, 0);
  }
});

async function indexFixture(suffix = '', token = null) {
  const scripts = [], listeners = new Map(), redirects = [], nodes = {};
  const elements = ['betshuva-launch-shell', 'betshuva-launch-status', 'betshuva-launch-retry'];
  for (const id of elements) nodes[id] = { hidden: id.includes('retry'), addEventListener() {} };
  const sandbox = {
    URL, Promise, console,
    setTimeout: () => 1, clearTimeout() {},
    navigator: {}, localStorage: { getItem: () => token },
    matchMedia: () => ({ matches: false }),
    location: { href: base + suffix, replace: url => redirects.push(url), reload() {} },
    history: { replaceState() {} },
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: name => listeners.delete(name),
    document: {
      baseURI: base, getElementById: id => nodes[id],
      createElement: () => ({}), body: { appendChild: script => scripts.push(script) },
    },
    fetch: () => assert.fail('public startup must not request external services'),
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../flutter_app/web/entry-route.js'), 'utf8'), sandbox);
  const html = fs.readFileSync(path.join(__dirname, '../flutter_app/web/index.html'), 'utf8');
  for (const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
    vm.runInContext(match[1], sandbox);
  }
  assert.equal(scripts.length, 1);
  assert.match(scripts[0].src, /^entry-route\.js\?v=/);
  scripts[0].onload(); await flush();
  return { sandbox, scripts, listeners, redirects, nodes };
}

test('actual index sends a new guest to home without Flutter or Firebase imports', async () => {
  const fixture = await indexFixture();
  assert.deepEqual(fixture.redirects, [base + 'home.html']);
  assert.equal(fixture.scripts.length, 1);
  assert.equal(typeof fixture.sandbox.betshuvaGetWebPushToken, 'function');
  assert.equal(typeof fixture.sandbox.betshuvaCopyImage, 'function');
});

test('actual index boots explicit registration and removes overlay on first frame', async () => {
  const fixture = await indexFixture('?entry=register');
  assert.deepEqual(fixture.redirects, []);
  assert.equal(fixture.scripts.length, 2);
  assert.match(fixture.scripts[1].src, /flutter_bootstrap\.js\?v=/);
  assert.equal(fixture.nodes['betshuva-launch-shell'].hidden, false);
  fixture.listeners.get('flutter-first-frame')();
  await fixture.sandbox.betshuvaStartApp();
  assert.equal(fixture.nodes['betshuva-launch-shell'].hidden, true);
});

test('actual index exposes visible retry after a returning app fails to load', async () => {
  const fixture = await indexFixture('', '"returning-token"');
  fixture.scripts[1].onerror(); await flush();
  assert.equal(fixture.nodes['betshuva-launch-retry'].hidden, false);
  assert.match(fixture.nodes['betshuva-launch-status'].textContent, /לנסות שוב/);
});
