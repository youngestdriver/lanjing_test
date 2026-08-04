const CACHE="quiz-v4";
const SHELL=["/","/manifest.json","/styles.css","/js/quiz-core.js","/js/app.js"];

self.addEventListener("install",e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate",e=>{
  e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener("fetch",e=>{
  // Exam data is never cached; all business operations require the live service.
  if(e.request.url.includes("/api/")){
    e.respondWith(fetch(e.request));
    return;
  }
  // Static: cache first, network fallback
  e.respondWith(
    caches.match(e.request).then(cached=>{
      const fetched=fetch(e.request).then(r=>{
        if(r.ok){ const clone=r.clone(); caches.open(CACHE).then(c=>c.put(e.request,clone)); }
        return r;
      });
      return cached||fetched;
    })
  );
});
