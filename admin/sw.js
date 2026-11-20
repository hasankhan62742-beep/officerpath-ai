/* OfficerPath AI — Admin panel service worker (minimal shell cache).
 *
 * Caches the panel shell (HTML/JS/CSS/manifest/icons) so the panel
 * opens fast and still opens when the connection drops. API calls
 * (Supabase, CDN) are never cached — only same-origin shell files.
 *
 * When the shell changes, bump CACHE below (v1 -> v2 ...) so the old
 * cache is dropped on activate; otherwise the panel can serve a stale
 * app.js after a deploy.
 */
const CACHE = 'officerpath-admin-v1';
const SHELL = [
  '/',
  '/index.html',
  '/styles.css',
  '/app.js',
  '/config.js',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll(SHELL))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // Only the panel's own origin is cached — never Supabase or the CDN.
  if (url.origin !== self.location.origin) return;
  event.respondWith(
    caches.match(event.request).then(
      (hit) =>
        hit ||
        fetch(event.request)
          .then((res) => {
            const copy = res.clone();
            caches.open(CACHE).then((cache) => cache.put(event.request, copy));
            return res;
          })
          .catch(() => caches.match('/index.html')),
    ),
  );
});
