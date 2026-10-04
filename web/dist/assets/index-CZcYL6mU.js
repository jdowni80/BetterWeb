(function(){const n=document.createElement("link").relList;if(n&&n.supports&&n.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))r(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const b of i.addedNodes)b.tagName==="LINK"&&b.rel==="modulepreload"&&r(b)}).observe(document,{childList:!0,subtree:!0});function t(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function r(a){if(a.ep)return;a.ep=!0;const i=t(a);fetch(a.href,i)}})();const S=document.querySelector("#app");S.innerHTML=`
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
`;const w=document.querySelector("#engines"),l=document.querySelector("#results"),c=document.querySelector("#meta"),m=document.querySelector("#ingest-meta"),o=document.querySelector("#q"),g=document.querySelector("#clear-q"),u=document.querySelector("#search-btn"),$=document.querySelector("#mode-control");let p;function y(){const e=document.querySelector('input[name="mode"]:checked');return(e==null?void 0:e.value)||"live"}function v(){$.dataset.value=y()}function s(e){return e.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;")}function k(e){return["human_craft","high_thought","niche","rare_gem"].includes(e)?"badge-ok":e==="propaganda"?"badge-warn":["ai_slop","bot_spam","malicious"].includes(e)?"badge-danger":"badge-neutral"}async function d(e,n){const t=await fetch(e,n);if(!t.ok){const r=await t.text();throw new Error(r||t.statusText)}return t.json()}function L(e){w.innerHTML=e.map(n=>`
      <span class="engine-chip ${n.available?"on":""}" title="${s(n.detail)}">
        <span class="dot" aria-hidden="true"></span>
        ${s(n.name)}
      </span>`).join("")}function q(){l.innerHTML=`
    <div class="skeleton-list" aria-hidden="true">
      ${Array.from({length:4}).map(()=>`
        <div class="skeleton-row">
          <span class="sk title"></span>
          <span class="sk url"></span>
          <span class="sk line"></span>
          <span class="sk line short"></span>
        </div>`).join("")}
    </div>`}function E(e){var n;l.innerHTML=`
    <div class="empty">
      <h2>No results yet</h2>
      <p>Nothing ranked for “${s(e)}”. Try a more specific phrase, or switch to local seed.</p>
      <button type="button" class="btn btn-secondary" id="empty-retry">Search again</button>
    </div>`,(n=document.querySelector("#empty-retry"))==null||n.addEventListener("click",()=>{o.focus()})}function x(e){var n;l.innerHTML=`
    <div class="error-box">
      <h2>Search couldn’t finish</h2>
      <p>${s(e)}</p>
      <button type="button" class="btn btn-secondary" id="error-retry">Try again</button>
    </div>`,(n=document.querySelector("#error-retry"))==null||n.addEventListener("click",()=>{f(o.value.trim())})}function C(e){l.innerHTML=e.map(n=>{const t=n.badges.map(r=>`<span class="badge ${k(r)}">${s(r.replaceAll("_"," "))}</span>`).join("");return`
      <article class="result">
        <h2 class="result-title">
          <a href="${s(n.url)}" target="_blank" rel="noreferrer">
            ${s(n.title)}
          </a>
        </h2>
        <div class="result-url">${s(n.url)}</div>
        <p class="result-snippet">${s(n.snippet)}</p>
        <div class="result-meta">
          ${t}
          <span class="badge badge-neutral">${s(n.fetch_engine.replaceAll("_"," "))}</span>
          <button type="button" class="btn btn-tertiary btn-sm" data-open="servo" data-url="${s(n.url)}">Open in Servo</button>
          <button type="button" class="btn btn-tertiary btn-sm" data-open="ladybird" data-url="${s(n.url)}">Open in Ladybird</button>
          <span class="score">score ${n.betterweb_score} · craft ${n.craft}</span>
        </div>
      </article>`}).join("")}function h(){g.hidden=o.value.length===0}async function T(){const e=await d("/api/engines");L(e.engines);const n=e.engines.filter(t=>t.available).map(t=>t.name);c.textContent=`Ready · ${n.join(" · ")||"core only"}`}async function f(e){if(!e){o.focus();return}const n=y();u.disabled=!0,u.textContent="Searching…",l.setAttribute("aria-busy","true"),c.textContent=n==="live"?`Discovering and ranking “${e}”…`:`Searching local seed for “${e}”…`,window.clearTimeout(p),p=window.setTimeout(()=>{l.getAttribute("aria-busy")==="true"&&q()},300);try{const t=await d(`/api/search?q=${encodeURIComponent(e)}&mode=${encodeURIComponent(n)}&limit=8`);window.clearTimeout(p);const r=t.mode==="live"?` · ${t.candidates??"?"} candidates · ${t.fetched??"?"} fetched`:"",a=t.errors&&t.errors.length?` · ${t.errors.length} fetch warning(s)`:"";c.textContent=`${t.count} results${r}${a} · ${t.ranking}`,t.hits.length?C(t.hits):E(e)}catch(t){window.clearTimeout(p);const r=t instanceof Error?t.message:String(t);c.textContent="Search failed",x(r)}finally{l.setAttribute("aria-busy","false"),u.disabled=!1,u.textContent="Search web"}}document.querySelector("#search-form").addEventListener("submit",e=>{e.preventDefault(),f(o.value.trim())});document.querySelectorAll('input[name="mode"]').forEach(e=>{e.addEventListener("change",()=>v())});g.addEventListener("click",()=>{o.value="",h(),o.focus()});o.addEventListener("input",h);window.addEventListener("keydown",e=>{(e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==="k"&&(e.preventDefault(),o.focus(),o.select())});document.querySelector("#ingest-form").addEventListener("submit",async e=>{e.preventDefault();const n=document.querySelector("#ingest-url").value.trim();m.textContent="Fetching page…";try{const t=await d("/api/ingest",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:n,judge:!1,prefer_lightpanda:!0})});m.textContent=`Indexed via ${t.fetch_engine}: ${t.document.title}`}catch(t){m.textContent=`Ingest failed: ${t instanceof Error?t.message:String(t)}`}});document.querySelector("#reload-seed").addEventListener("click",async()=>{const e=await d("/api/seed/reload",{method:"POST"});m.textContent=`Seed reloaded (${e.reloaded} docs)`});l.addEventListener("click",async e=>{const n=e.target,t=n.getAttribute("data-open"),r=n.getAttribute("data-url");if(!(!t||!r))try{await d("/api/open",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({engine:t,url:r})}),c.textContent=`Opened in ${t}`}catch(a){c.textContent=`${t} unavailable: ${a instanceof Error?a.message:String(a)}`}});v();h();T().then(()=>f(o.value.trim()));
