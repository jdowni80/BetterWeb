(function(){const r=document.createElement("link").relList;if(r&&r.supports&&r.supports("modulepreload"))return;for(const n of document.querySelectorAll('link[rel="modulepreload"]'))s(n);new MutationObserver(n=>{for(const a of n)if(a.type==="childList")for(const u of a.addedNodes)u.tagName==="LINK"&&u.rel==="modulepreload"&&s(u)}).observe(document,{childList:!0,subtree:!0});function e(n){const a={};return n.integrity&&(a.integrity=n.integrity),n.referrerPolicy&&(a.referrerPolicy=n.referrerPolicy),n.crossOrigin==="use-credentials"?a.credentials="include":n.crossOrigin==="anonymous"?a.credentials="omit":a.credentials="same-origin",a}function s(n){if(n.ep)return;n.ep=!0;const a=e(n);fetch(n.href,a)}})();const f=document.querySelector("#app");f.innerHTML=`
  <header class="hero">
    <h1 class="brand">Better<span>Web</span></h1>
    <p class="tagline">
      Live web discovery, ranked by BetterWeb — human craft over ads, SEO farms, and AI filler.
      CraftRank owns the score. Lightpanda can fetch. Servo &amp; Ladybird browse.
    </p>
    <div class="engines" id="engines"></div>
  </header>

  <form class="search-row" id="search-form">
    <input id="q" type="search" placeholder="Search the live web…" value="vacuum tube heater wiring" autocomplete="off" />
    <button class="btn-primary" type="submit">Search</button>
  </form>
  <div class="row mode-row">
    <label class="mode"><input type="radio" name="mode" value="live" checked /> Live web</label>
    <label class="mode"><input type="radio" name="mode" value="local" /> Local seed only</label>
  </div>
  <div class="meta" id="meta">Loading engines…</div>
  <div class="results" id="results"></div>

  <section class="ingest">
    <h3>Ingest a URL</h3>
    <p class="tagline">Prefers Lightpanda (non-Chromium). Falls back to plain HTTP if needed.</p>
    <form class="ingest-row" id="ingest-form">
      <input id="ingest-url" type="url" placeholder="https://…" required />
      <button class="btn-ghost" type="submit">Fetch + index</button>
      <button class="btn-ghost" type="button" id="reload-seed">Reload seed</button>
    </form>
    <div class="meta" id="ingest-meta"></div>
  </section>
`;const g=document.querySelector("#engines"),c=document.querySelector("#results"),i=document.querySelector("#meta"),d=document.querySelector("#ingest-meta"),p=document.querySelector("#q");function h(){const t=document.querySelector('input[name="mode"]:checked');return(t==null?void 0:t.value)||"live"}async function l(t,r){const e=await fetch(t,r);if(!e.ok){const s=await e.text();throw new Error(s||e.statusText)}return e.json()}function b(t){g.innerHTML=t.map(r=>`
      <div class="engine ${r.available?"on":"off"}" title="${r.detail}">
        <span class="dot"></span>
        <span>${r.name}</span>
        <span>${r.role}</span>
      </div>`).join("")}function o(t){return t.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;")}function v(t,r){if(!t.length){c.innerHTML=`<p class="empty">No matches for “${o(r)}”.</p>`;return}c.innerHTML=t.map((e,s)=>{const n=e.badges.map(a=>`<span class="badge ${a}">${o(a.replaceAll("_"," "))}</span>`).join("");return`
      <article class="card" style="animation-delay:${s*40}ms">
        <h2><a href="${o(e.url)}" target="_blank" rel="noreferrer">${o(e.title)}</a></h2>
        <div class="url">${o(e.url)}</div>
        <p class="snippet">${o(e.snippet)}</p>
        <div class="row">
          ${n}
          <span class="badge">${o(e.fetch_engine)}</span>
          <button class="btn-ghost" data-open="servo" data-url="${o(e.url)}">Open in Servo</button>
          <button class="btn-ghost" data-open="ladybird" data-url="${o(e.url)}">Open in Ladybird</button>
          <span class="score">score ${e.betterweb_score} · craft ${e.craft}</span>
        </div>
      </article>`}).join("")}async function y(){const t=await l("/api/engines");b(t.engines);const r=t.engines.filter(e=>e.available).map(e=>e.name);i.textContent=`Engines ready: ${r.join(", ")||"none"}`}async function m(t){if(!t)return;const r=h();i.textContent=r==="live"?`Discovering & ranking live results for “${t}”…`:`Searching local seed for “${t}”…`,c.innerHTML='<p class="empty">Working…</p>';try{const e=await l(`/api/search?q=${encodeURIComponent(t)}&mode=${encodeURIComponent(r)}&limit=8`),s=e.mode==="live"?` · ${e.candidates??"?"} candidates · ${e.fetched??"?"} fetched`:"",n=e.errors&&e.errors.length?` · ${e.errors.length} fetch warning(s)`:"";i.textContent=`${e.count} results${s}${n} · ${e.ranking}`,v(e.hits,t)}catch(e){i.textContent=`Search failed: ${e instanceof Error?e.message:String(e)}`,c.innerHTML=""}}document.querySelector("#search-form").addEventListener("submit",t=>{t.preventDefault(),m(p.value.trim())});document.querySelector("#ingest-form").addEventListener("submit",async t=>{t.preventDefault();const r=document.querySelector("#ingest-url").value.trim();d.textContent="Fetching…";try{const e=await l("/api/ingest",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:r,judge:!1,prefer_lightpanda:!0})});d.textContent=`Indexed via ${e.fetch_engine}: ${e.document.title}`}catch(e){d.textContent=`Ingest failed: ${e instanceof Error?e.message:String(e)}`}});document.querySelector("#reload-seed").addEventListener("click",async()=>{const t=await l("/api/seed/reload",{method:"POST"});d.textContent=`Seed reloaded (${t.reloaded} docs)`});c.addEventListener("click",async t=>{const r=t.target,e=r.getAttribute("data-open"),s=r.getAttribute("data-url");if(!(!e||!s))try{await l("/api/open",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({engine:e,url:s})}),i.textContent=`Opened in ${e}`}catch(n){i.textContent=`${e} unavailable: ${n instanceof Error?n.message:String(n)}`}});y().then(()=>m(p.value.trim()));
