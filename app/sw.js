// MyEden Group CMS · service worker: makes the CMS installable as an app.
// Nothing is cached, so every page and every update always comes straight from the server;
// when there is no connection, opening the app shows a short "you are offline" page instead of a browser error.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  if (e.request.mode !== 'navigate') return;
  e.respondWith(fetch(e.request).catch(() => new Response(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MyEden Group CMS · offline</title>' +
    '<body style="margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,sans-serif;background:#f2f5fb;color:#0f1d36;text-align:center">' +
    '<div><img src="../assets/icons/icon-192.png" width="96" height="96" alt=""><h1 style="font-size:20px">You are offline</h1>' +
    '<p style="color:#5c6a82">MyEden Group CMS needs an internet connection. Reconnect and try again.</p>' +
    '<button onclick="location.reload()" style="padding:10px 18px;border-radius:10px;border:0;background:#0072bc;color:#fff;font:inherit">Try again</button></div>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8' } })));
});
