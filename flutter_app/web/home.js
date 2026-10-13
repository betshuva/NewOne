(() => {
  'use strict';

  function initializeLanding() {
    const tabs = Array.from(document.querySelectorAll('[data-demo-tab]'));
    const panels = Array.from(document.querySelectorAll('[data-demo-panel]'));

    function selectTab(name, focus = false) {
      const selected = tabs.find(tab => tab.dataset.demoTab === name);
      if (!selected) return;
      tabs.forEach(tab => {
        const active = tab === selected;
        tab.setAttribute('aria-selected', String(active));
        tab.tabIndex = active ? 0 : -1;
      });
      panels.forEach(panel => {
        panel.hidden = panel.dataset.demoPanel !== name;
      });
      if (focus) selected.focus();
    }

    tabs.forEach((tab, index) => {
      tab.addEventListener('click', event => {
        event.preventDefault();
        selectTab(tab.dataset.demoTab);
      });
      tab.addEventListener('keydown', event => {
        const rtl = getComputedStyle(tab).direction === 'rtl';
        let next;
        if (event.key === 'ArrowLeft') next = index + (rtl ? 1 : -1);
        else if (event.key === 'ArrowRight') next = index + (rtl ? -1 : 1);
        else if (event.key === 'Home') next = 0;
        else if (event.key === 'End') next = tabs.length - 1;
        else if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          selectTab(tab.dataset.demoTab);
          return;
        }
        else return;
        event.preventDefault();
        next = (next + tabs.length) % tabs.length;
        selectTab(tabs[next].dataset.demoTab, true);
      });
    });
    selectTab(tabs.find(tab => tab.getAttribute('aria-selected') === 'true')?.dataset.demoTab
      || tabs.find(tab => tab.dataset.demoTab === 'chat')?.dataset.demoTab
      || tabs[0]?.dataset.demoTab);

    function showFeedback(control, text) {
      const panel = control.closest('[data-demo-panel]');
      const feedback = panel?.querySelector('[data-demo-feedback]');
      if (!feedback) return;
      feedback.setAttribute('role', 'status');
      feedback.setAttribute('aria-live', 'polite');
      feedback.textContent = text;
    }

    document.querySelectorAll('[data-poll-option]').forEach(option => {
      option.addEventListener('click', event => {
        event.preventDefault();
        const poll = option.closest('[data-demo-poll]') || option.closest('[data-demo-panel]');
        poll?.querySelectorAll('[data-poll-option]').forEach(other => {
          const selected = other === option;
          other.setAttribute('aria-pressed', String(selected));
          other.classList.toggle('selected', selected);
        });
        const label = option.getAttribute('aria-label') || option.textContent.trim()
          || option.dataset.pollOption;
        showFeedback(option, `הדמיה: בחרת ב״${label}״. הבחירה מקומית לדוגמה זו.`);
      });
    });

    document.querySelectorAll('[data-demo-filter]').forEach(control => {
      control.addEventListener('click', event => {
        event.preventDefault();
        const selected = control.getAttribute('aria-pressed') !== 'true';
        control.setAttribute('aria-pressed', String(selected));
        control.classList.toggle('selected', selected);
        const label = control.dataset.demoFilter || control.textContent.trim();
        showFeedback(control, `הדמיה: ״${label}״ ${selected ? 'נבחר' : 'לא נבחר'}. הבחירה מקומית לדוגמה זו.`);
      });
    });

    const demoFeedback = {
      voice: 'הדמיה: הודעה קולית עם נגן וחיווי חזותי בזמן ההשמעה.',
      poll: 'הדמיה: אפשר לבחור תשובה לסקר בעזרת האפשרויות שמופיעות כאן.',
      filter: 'הדמיה: בוחרים אילו סוגי תוכן לקבל ומשנים את הבחירה בהגדרות.',
      listing: 'הדמיה: בלוח מחפשים לקנות, מפרסמים למכירה או מוסרים ללא תשלום — ברכב, בנדל״ן, במוצרי חשמל ובקטגוריות נוספות.',
      ai: 'הדמיה: העוזר מציג תשובה מסודרת, וקישורים למקורות כאשר הם זמינים.',
    };
    document.querySelectorAll('[data-demo-action]').forEach(control => {
      if (control.matches('[data-poll-option], [data-demo-filter]')) return;
      control.addEventListener('click', event => {
        event.preventDefault();
        const text = demoFeedback[control.dataset.demoAction];
        if (text) showFeedback(control, text);
      });
    });

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
