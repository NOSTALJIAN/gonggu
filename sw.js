/* MINIYENA legacy PWA worker upgrade.
 * Old installed icons may still have this worker. Serve HTML network-first,
 * invalidate stale app-shell caches, and keep offline fallback for outages.
 * The OneSignal push worker uses a different scope and is untouched.
 */
'use strict';
const CACHE = 'gonggunote-cache-6';
const PREFIX = 'gonggunote-cache-';
const APP_SCOPE = '/gonggu/';
const SHELL = ['./index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png','./apple-touch-icon.png'];
self.addEventListener('install', event => {
 event.waitUntil((async () => {
  const cache = await caches.open(CACHE);
  try { await cache.addAll(SHELL); } catch (err) { console.warn('PWA preload unavailable',err); }
  await self.skipWaiting();
 })());
});
self.addEventListener('activate', event => {
 event.waitUntil((async () => {
  const keys = await caches.keys();
  await Promise.all(keys.filter(key => key.startsWith(PREFIX) && key !== CACHE).map(key => caches.delete(key)));
  await self.clients.claim();
 })());
});
self.addEventListener('fetch', event => {
 const request = event.request;
 if(request.method !== 'GET') return;
 const url = new URL(request.url);
 if(url.origin !== self.location.origin || !url.pathname.startsWith(APP_SCOPE)) return;
 const isDocument = request.mode === 'navigate' || url.pathname === APP_SCOPE || url.pathname === APP_SCOPE + 'index.html';
 if(!isDocument) return;
 event.respondWith((async () => {
  try {
   const response = await fetch(request, {cache:'no-store'});
   if(response.ok) {
    const copy=response.clone();
    event.waitUntil(caches.open(CACHE).then(cache => cache.put(new URL('./index.html',self.registration.scope).href,copy)).catch(()=>{}));
   }
   return response;
  } catch(error) {
   return (await caches.match(new URL('./index.html',self.registration.scope).href)) || Response.error();
  }
 })());
});
