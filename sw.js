// Gesta — service worker: l'app funziona anche offline (palestra senza campo).
const VERSION = 'gesta-v3.9.6';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png', './icons/apple-touch-icon.png', './fonts/exo2.woff', './fonts/manrope.woff', './app.js?v=3.9.6'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: 'reload' })))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
      .then(() => self.clients.matchAll({ type: 'window' }))
      .then((cs) => cs.forEach((c) => c.postMessage({ v: VERSION })))
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // Il cloud (Supabase) passa sempre dalla rete e non si salva mai in copia.
  if (/\/(rest|auth|functions|realtime|storage)\/v1\//.test(req.url) || /\.supabase\.(co|in)$/.test(new URL(req.url).hostname)) return;
  // Pagina: subito la copia salvata (apertura istantanea), intanto si aggiorna dalla rete.
  // Le versioni nuove arrivano col service worker nuovo, che ricarica la pagina una volta.
  if (req.mode === 'navigate') {
    const net = fetch(req, { cache: 'no-cache' }).then((res) => {
      if (res && res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put('./index.html', copy)); }
      return res;
    });
    e.respondWith(caches.match('./index.html').then((hit) => hit || net).catch(() => net));
    e.waitUntil(net.catch(() => {}));
    return;
  }
  // Tutto il resto (icone, font): prima la copia salvata, poi la rete.
  e.respondWith(
    caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      if (res && (res.ok || res.type === 'opaque')) {
        const copy = res.clone();
        caches.open(VERSION).then((c) => c.put(req, copy));
      }
      return res;
    }).catch(() => hit))
  );
});

/* 3.8 · notifiche sul telefono */
self.addEventListener('push', function (e) {
  var d = {}; try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Gesta', {
    body: d.body || '', tag: d.tag || undefined, renotify: false,
    icon: './icons/icon-192.png', badge: './icons/icon-192.png', data: { go: d.go || 'party' }
  }));
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var go = (e.notification.data && e.notification.data.go) || 'party';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cs) {
    for (var i = 0; i < cs.length; i++) { if ('focus' in cs[i]) { cs[i].postMessage({ go: go }); return cs[i].focus(); } }
    return self.clients.openWindow('./?go=' + go);
  }));
});
