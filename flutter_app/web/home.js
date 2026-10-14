(() => {
  'use strict';

  function initializeLanding() {
    const downloadLinks = document.querySelectorAll('[data-android-download]');
    if (!downloadLinks.length || typeof fetch !== 'function') return;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    fetch('/betshuva-app/api/version', {
      method: 'GET',
      credentials: 'omit',
      cache: 'no-store',
      signal: controller.signal,
    }).then(response => {
      if (!response.ok) throw new Error('Release information unavailable');
      return response.json();
    }).then(release => {
      if (typeof release?.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(release.version)) return;
      if (typeof release.apkUrl !== 'string') return;
      const apk = new URL(release.apkUrl, window.location.href);
      if (apk.origin !== window.location.origin
        || apk.username || apk.password || apk.search || apk.hash
        || apk.pathname !== `/betshuva-app/betshuva-${release.version}.apk`) return;
      downloadLinks.forEach(link => {
        link.href = apk.href;
        link.title = `הורדת בתשובה לאנדרואיד — גרסה ${release.version}`;
      });
      document.querySelectorAll('[data-android-version]').forEach(label => {
        label.textContent = release.version;
      });
    }).catch(() => {
      // Keep the published link already present in the HTML when offline.
    }).finally(() => clearTimeout(timer));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeLanding, {once: true});
  } else {
    initializeLanding();
  }
})();
