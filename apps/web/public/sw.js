const CACHE="quiz-v5";
const SHELL=["/","/manifest.json","/styles.css","/js/quiz-core.js","/js/practice-core.js","/js/practice.js","/js/app.js","/icon-192.png","/icon-512.png"];

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
  if(e.request.mode==="navigate"){
    e.respondWith(fetch(e.request).catch(()=>caches.match("/")));
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
