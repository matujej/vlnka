// Vlnka: aplikace se otevře i bez signálu; vždy se nejdřív zkusí čerstvá verze ze sítě.
const CACHE = "vlnka-v2";
const SHELL = ["./", "index.html", "style.css", "app.js", "manifest.webmanifest",
  "icons/waves.svg", "icons/icon-192.png", "icons/icon-512.png", "icons/apple-touch-icon.png", "vendor/hls.min.js"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return; // streamy a API neřešíme
  e.respondWith(
    fetch(e.request).then(r => {
      const copy = r.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return r;
    }).catch(() => caches.match(e.request))
  );
});
