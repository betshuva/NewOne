(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else if (root) root.betshuvaEntryRoute = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function hasStoredToken(value) {
    if (typeof value !== 'string') return false;
    try {
      const token = JSON.parse(value);
      return typeof token === 'string' && token.trim().length > 0;
    } catch (_) {
      return false;
    }
  }

  // The public landing is only for a plain, unauthenticated browser entry.
  // Any existing query, fragment or dedicated path belongs to the application.
  function resolveEntryRoute({ href, baseHref, storedToken, standalone = false }) {
    const current = new URL(href);
    const base = new URL(baseHref, current);
    const rootPath = base.pathname.endsWith('/')
      ? base.pathname : base.pathname + '/';
    const isRoot = current.origin === base.origin &&
      (current.pathname === rootPath ||
       current.pathname === rootPath + 'index.html');
    if (isRoot && !current.search && !current.hash &&
        !standalone && !hasStoredToken(storedToken)) {
      return { bootApp: false, url: new URL('home.html', base).href };
    }
    if (standalone && current.origin === base.origin &&
        !current.searchParams.has('app')) {
      current.search = current.search ? current.search + '&app=1' : '?app=1';
    }
    return { bootApp: true, url: current.href };
  }

  // A failed launch is retried by a page reload, not by initializing a second
  // Flutter engine in a page which might already contain a partially loaded one.
  function createAppLoader({
    window: target,
    document,
    ready,
    bootstrapSrc,
    onLoading = () => {},
    onReady = () => {},
    onError = () => {},
    timeoutMs = 60000,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  }) {
    let pending;
    let failLaunch = () => {};
    function start() {
      if (pending) return pending;
      pending = new Promise((resolve, reject) => {
        let settled = false;
        let timer;
        const cleanup = () => {
          clearTimer(timer);
          target.removeEventListener('flutter-first-frame', firstFrame);
          target.removeEventListener('betshuva-app-load-error', reportedError);
        };
        const fail = error => {
          if (settled) return;
          settled = true;
          cleanup();
          onError(error);
          reject(error);
        };
        const firstFrame = () => {
          if (settled) return;
          settled = true;
          cleanup();
          onReady();
          resolve();
        };
        const reportedError = event => fail(event.detail || new Error('app_load_failed'));
        failLaunch = fail;
        target.addEventListener('flutter-first-frame', firstFrame);
        target.addEventListener('betshuva-app-load-error', reportedError);
        timer = setTimer(() => fail(new Error('app_load_timeout')), timeoutMs);
        onLoading();
        Promise.resolve(ready).catch(() => {}).then(() => {
          if (settled) return;
          try {
            const script = document.createElement('script');
            script.src = bootstrapSrc;
            script.async = true;
            script.onerror = () => fail(new Error('bootstrap_load_failed'));
            document.body.appendChild(script);
          } catch (error) {
            fail(error);
          }
        });
      });
      return pending;
    }
    return { start, reportFailure: error => failLaunch(error) };
  }

  return { hasStoredToken, resolveEntryRoute, createAppLoader };
});
