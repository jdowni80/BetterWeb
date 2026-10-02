(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const r of document.querySelectorAll('link[rel="modulepreload"]'))s(r);new MutationObserver(r=>{for(const a of r)if(a.type==="childList")for(const u of a.addedNodes)u.tagName==="LINK"&&u.rel==="modulepreload"&&s(u)}).observe(document,{childList:!0,subtree:!0});function e(r){const a={};return r.integrity&&(a.integrity=r.integrity),r.referrerPolicy&&(a.referrerPolicy=r.referrerPolicy),r.crossOrigin==="use-credentials"?a.credentials="include":r.crossOrigin==="anonymous"?a.credentials="omit":a.credentials="same-origin",a}function s(r){if(r.ep)return;r.ep=!0;const a=e(r);fetch(r.href,a)}})();const f=document.querySelector("#app");f.innerHTML=`
  <header class="hero">
    <h1 class="brand">Better<span>Web</span></h1>
    <p class="tagline">
      Search ranked for human craft — not ads, SEO farms, or AI filler.
      CraftRank owns the score. Lightpanda fetches. Servo &amp; Ladybird browse.
    </p>
    <div class="engines" id="engines"></div>
  </header>

  <form class="search-row" id="search-form">
    <input id="q" type="search" placeholder="Search the indexed web…" value="heater wiring" autocomplete="off" />
    <button class="btn-primary" type="submit">Search</button>
  </form>
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
`;const m=document.querySelector("#engines"),p=document.querySelector("#results"),o=document.querySelector("#meta"),d=document.querySelector("#ingest-meta"),i=document.querySelector("#q");async function c(n,t){const e=await fetch(n,t);if(!e.ok){const s=await e.text();throw new Error(s||e.statusText)}return e.json()}function g(n){m.innerHTML=n.map(t=>`
      <div class="engine ${t.available?"on":"off"}" title="${t.detail}">
        <span class="dot"></span>
        <span>${t.name}</span>
        <span>${t.role}</span>
      </div>`).join("")}function h(n,t){if(!n.length){p.innerHTML=`<p class="empty">No matches for “${t}”.</p>`;return}p.innerHTML=n.map((e,s)=>{const r=e.badges.map(a=>`<span class="badge ${a}">${a.replaceAll("_"," ")}</span>`).join("");return`
      <article class="card" style="animation-delay:${s*40}ms">
        <h2><a href="${e.url}" target="_blank" rel="noreferrer">${e.title}</a></h2>
        <div class="url">${e.url}</div>
        <p class="snippet">${e.snippet}</p>
        <div class="row">
          ${r}
          <span class="badge">${e.fetch_engine}</span>
          <button class="btn-ghost" data-open="servo" data-url="${e.url}">Open in Servo</button>
          <button class="btn-ghost" data-open="ladybird" data-url="${e.url}">Open in Ladybird</button>
          <span class="score">score ${e.betterweb_score} · craft ${e.craft}</span>
        </div>
      </article>`}).join("")}async function y(){const n=await c("/api/engines");g(n.engines);const t=n.engines.filter(e=>e.available).map(e=>e.name);o.textContent=`Engines ready: ${t.join(", ")||"none"}`}async function l(n){o.textContent=`Searching “${n}”…`;const t=await c(`/api/search?q=${encodeURIComponent(n)}`);o.textContent=`${t.count} results · ${t.ranking}`,h(t.hits,n)}document.querySelector("#search-form").addEventListener("submit",n=>{n.preventDefault(),l(i.value.trim())});document.querySelector("#ingest-form").addEventListener("submit",async n=>{n.preventDefault();const t=document.querySelector("#ingest-url").value.trim();d.textContent="Fetching…";try{const e=await c("/api/ingest",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:t,judge:!1,prefer_lightpanda:!0})});d.textContent=`Indexed via ${e.fetch_engine}: ${e.document.title}`,i.value.trim()&&l(i.value.trim())}catch(e){d.textContent=`Ingest failed: ${e instanceof Error?e.message:String(e)}`}});document.querySelector("#reload-seed").addEventListener("click",async()=>{const n=await c("/api/seed/reload",{method:"POST"});d.textContent=`Seed reloaded (${n.reloaded} docs)`,l(i.value.trim()||"heater")});p.addEventListener("click",async n=>{const t=n.target,e=t.getAttribute("data-open"),s=t.getAttribute("data-url");if(!(!e||!s))try{await c("/api/open",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({engine:e,url:s})}),o.textContent=`Opened in ${e}`}catch(r){o.textContent=`${e} unavailable: ${r instanceof Error?r.message:String(r)}`}});y().then(()=>l(i.value.trim()));
