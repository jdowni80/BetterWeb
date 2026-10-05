(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))r(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const h of i.addedNodes)h.tagName==="LINK"&&h.rel==="modulepreload"&&r(h)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function r(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();const w=document.querySelector("#app");w.innerHTML=`
  <a class="skip-link" href="#main">Skip to main content</a>

  <header class="site-header">
    <a class="brand-mark" href="/" aria-label="BetterWeb home">Better<span>Web</span></a>
    <div class="engine-strip" id="engines" aria-label="Engine status"></div>
  </header>

  <main id="main" class="shell">
    <section class="hero" aria-labelledby="hero-title">
      <h1 id="hero-title">Better<span>Web</span></h1>
      <p class="lede">
        Search the live web, ranked for human craft — not ads, SEO farms, or AI filler.
      </p>

      <form class="search-form" id="search-form" role="search">
        <label class="search-label" for="q">Search query</label>
        <div class="search-field">
          <svg class="search-icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7"></circle>
            <path d="m20 20-3.5-3.5"></path>
          </svg>
          <input
            id="q"
            name="q"
            type="search"
            placeholder="Try: vacuum tube heater wiring"
            value="vacuum tube heater wiring"
            autocomplete="off"
            enterkeyhint="search"
          />
          <button type="button" class="icon-btn" id="clear-q" aria-label="Clear search" hidden>×</button>
          <button class="btn btn-primary" type="submit" id="search-btn">Search web</button>
        </div>

        <div class="search-actions">
          <div
            class="segmented"
            id="mode-control"
            data-value="live"
            role="radiogroup"
            aria-label="Search mode"
          >
            <span class="thumb" aria-hidden="true"></span>
            <label class="seg">
              <input type="radio" name="mode" value="live" checked />
              <span>Live web</span>
            </label>
            <label class="seg">
              <input type="radio" name="mode" value="local" />
              <span>Local seed</span>
            </label>
          </div>
          <span class="hint">Press <kbd class="kbd">⌘</kbd><kbd class="kbd">K</kbd> to focus search</span>
        </div>
      </form>
    </section>

    <div class="status-line" id="meta" role="status" aria-live="polite">Loading engines…</div>
    <section class="results" id="results" aria-live="polite" aria-busy="false"></section>

    <section class="panel" aria-labelledby="ingest-title">
      <h2 id="ingest-title">Ingest a URL</h2>
      <p>Fetch with Lightpanda when available, then add the page to your local index.</p>
      <form class="ingest-row" id="ingest-form">
        <label class="search-label" for="ingest-url">Page URL</label>
        <input id="ingest-url" name="url" type="url" placeholder="https://example.com/article" required />
        <button class="btn btn-secondary btn-sm" type="submit">Fetch + index</button>
        <button class="btn btn-tertiary btn-sm" type="button" id="reload-seed">Reload seed</button>
      </form>
      <div class="hint" id="ingest-meta" role="status" aria-live="polite"></div>
    </section>
  </main>
`;const $=document.querySelector("#engines"),l=document.querySelector("#results"),c=document.querySelector("#meta"),m=document.querySelector("#ingest-meta"),o=document.querySelector("#q"),y=document.querySelector("#clear-q"),u=document.querySelector("#search-btn"),k=document.querySelector("#mode-control");let p;function v(){const e=document.querySelector('input[name="mode"]:checked');return(e==null?void 0:e.value)||"live"}function S(){k.dataset.value=v()}function s(e){return e.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&#39;")}function b(e){try{const t=new URL(e);if(t.protocol==="http:"||t.protocol==="https:")return s(t.href)}catch{}return"#"}function L(e){return["human_craft","high_thought","niche","rare_gem"].includes(e)?"badge-ok":e==="propaganda"?"badge-warn":["ai_slop","bot_spam","malicious"].includes(e)?"badge-danger":"badge-neutral"}async function d(e,t){const n=await fetch(e,t);if(!n.ok){const r=await n.text();throw new Error(r||n.statusText)}return n.json()}function q(e){$.innerHTML=e.map(t=>`
      <span class="engine-chip ${t.available?"on":""}" title="${s(t.detail)}">
        <span class="dot" aria-hidden="true"></span>
        ${s(t.name)}
      </span>`).join("")}function E(){l.innerHTML=`
    <div class="skeleton-list" aria-hidden="true">
      ${Array.from({length:4}).map(()=>`
        <div class="skeleton-row">
          <span class="sk title"></span>
          <span class="sk url"></span>
          <span class="sk line"></span>
          <span class="sk line short"></span>
        </div>`).join("")}
    </div>`}function x(e){var t;l.innerHTML=`
    <div class="empty">
      <h2>No results yet</h2>
      <p>Nothing ranked for “${s(e)}”. Try a more specific phrase, or switch to local seed.</p>
      <button type="button" class="btn btn-secondary" id="empty-retry">Search again</button>
    </div>`,(t=document.querySelector("#empty-retry"))==null||t.addEventListener("click",()=>{o.focus()})}function C(e){var t;l.innerHTML=`
    <div class="error-box">
      <h2>Search couldn’t finish</h2>
      <p>${s(e)}</p>
      <button type="button" class="btn btn-secondary" id="error-retry">Try again</button>
    </div>`,(t=document.querySelector("#error-retry"))==null||t.addEventListener("click",()=>{g(o.value.trim())})}function T(e){l.innerHTML=e.map(t=>{const n=t.badges.map(r=>`<span class="badge ${L(r)}">${s(r.replaceAll("_"," "))}</span>`).join("");return`
      <article class="result">
        <h2 class="result-title">
          <a href="${b(t.url)}" target="_blank" rel="noreferrer">
            ${s(t.title)}
          </a>
        </h2>
        <div class="result-url">${s(t.url)}</div>
        <p class="result-snippet">${s(t.snippet)}</p>
        <div class="result-meta">
          ${n}
          <span class="badge badge-neutral">${s(t.fetch_engine.replaceAll("_"," "))}</span>
          <button type="button" class="btn btn-tertiary btn-sm" data-open="servo" data-url="${b(t.url)}">Open in Servo</button>
          <button type="button" class="btn btn-tertiary btn-sm" data-open="ladybird" data-url="${b(t.url)}">Open in Ladybird</button>
          <span class="score">score ${s(String(t.betterweb_score))} · craft ${s(String(t.craft))}</span>
        </div>
      </article>`}).join("")}function f(){y.hidden=o.value.length===0}async function A(){const e=await d("/api/engines");q(e.engines);const t=e.engines.filter(n=>n.available).map(n=>n.name);c.textContent=`Ready · ${t.join(" · ")||"core only"}`}async function g(e){if(!e){o.focus();return}const t=v();u.disabled=!0,u.textContent="Searching…",l.setAttribute("aria-busy","true"),c.textContent=t==="live"?`Discovering and ranking “${e}”…`:`Searching local seed for “${e}”…`,window.clearTimeout(p),p=window.setTimeout(()=>{l.getAttribute("aria-busy")==="true"&&E()},300);try{const n=await d(`/api/search?q=${encodeURIComponent(e)}&mode=${encodeURIComponent(t)}&limit=8`);window.clearTimeout(p);const r=n.mode==="live"?` · ${n.candidates??"?"} candidates · ${n.fetched??"?"} fetched`:"",a=n.errors&&n.errors.length?` · ${n.errors.length} fetch warning(s)`:"";c.textContent=`${n.count} results${r}${a} · ${n.ranking}`,n.hits.length?T(n.hits):x(e)}catch(n){window.clearTimeout(p);const r=n instanceof Error?n.message:String(n);c.textContent="Search failed",C(r)}finally{l.setAttribute("aria-busy","false"),u.disabled=!1,u.textContent="Search web"}}document.querySelector("#search-form").addEventListener("submit",e=>{e.preventDefault(),g(o.value.trim())});document.querySelectorAll('input[name="mode"]').forEach(e=>{e.addEventListener("change",()=>S())});y.addEventListener("click",()=>{o.value="",f(),o.focus()});o.addEventListener("input",f);window.addEventListener("keydown",e=>{(e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==="k"&&(e.preventDefault(),o.focus(),o.select())});document.querySelector("#ingest-form").addEventListener("submit",async e=>{e.preventDefault();const t=document.querySelector("#ingest-url").value.trim();m.textContent="Fetching page…";try{const n=await d("/api/ingest",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:t,judge:!1,prefer_lightpanda:!0})});m.textContent=`Indexed via ${n.fetch_engine}: ${n.document.title}`}catch(n){m.textContent=`Ingest failed: ${n instanceof Error?n.message:String(n)}`}});document.querySelector("#reload-seed").addEventListener("click",async()=>{const e=await d("/api/seed/reload",{method:"POST"});m.textContent=`Seed reloaded (${e.reloaded} docs)`});l.addEventListener("click",async e=>{const t=e.target,n=t.getAttribute("data-open"),r=t.getAttribute("data-url");if(!(!n||!r))try{await d("/api/open",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({engine:n,url:r})}),c.textContent=`Opened in ${n}`}catch(a){c.textContent=`${n} unavailable: ${a instanceof Error?a.message:String(a)}`}});S();f();A().then(()=>g(o.value.trim()));
