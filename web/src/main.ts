import "./style.css";

type Engine = {
  id: string;
  name: string;
  role: string;
  available: boolean;
  path: string | null;
  detail: string;
};

type Hit = {
  id: string;
  title: string;
  url: string;
  snippet: string;
  relevance: number;
  craft: number;
  betterweb_score: number;
  badges: string[];
  fetch_engine: string;
};

const app = document.querySelector<HTMLDivElement>("#app")!;

app.innerHTML = `
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
`;

const enginesEl = document.querySelector<HTMLDivElement>("#engines")!;
const resultsEl = document.querySelector<HTMLElement>("#results")!;
const metaEl = document.querySelector<HTMLElement>("#meta")!;
const ingestMeta = document.querySelector<HTMLElement>("#ingest-meta")!;
const qInput = document.querySelector<HTMLInputElement>("#q")!;
const clearBtn = document.querySelector<HTMLButtonElement>("#clear-q")!;
const searchBtn = document.querySelector<HTMLButtonElement>("#search-btn")!;
const modeControl = document.querySelector<HTMLDivElement>("#mode-control")!;

let skeletonTimer: number | undefined;

function selectedMode(): string {
  const el = document.querySelector<HTMLInputElement>('input[name="mode"]:checked');
  return el?.value || "live";
}

function syncModeThumb() {
  modeControl.dataset.value = selectedMode();
}

function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function badgeClass(badge: string): string {
  if (["human_craft", "high_thought", "niche", "rare_gem"].includes(badge)) return "badge-ok";
  if (badge === "propaganda") return "badge-warn";
  if (["ai_slop", "bot_spam", "malicious"].includes(badge)) return "badge-danger";
  return "badge-neutral";
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, init);
  if (!res.ok) {
    const detail = await res.text();
    throw new Error(detail || res.statusText);
  }
  return res.json() as Promise<T>;
}

function renderEngines(engines: Engine[]) {
  enginesEl.innerHTML = engines
    .map(
      (e) => `
      <span class="engine-chip ${e.available ? "on" : ""}" title="${escapeHtml(e.detail)}">
        <span class="dot" aria-hidden="true"></span>
        ${escapeHtml(e.name)}
      </span>`,
    )
    .join("");
}

function renderSkeleton() {
  resultsEl.innerHTML = `
    <div class="skeleton-list" aria-hidden="true">
      ${Array.from({ length: 4 })
        .map(
          () => `
        <div class="skeleton-row">
          <span class="sk title"></span>
          <span class="sk url"></span>
          <span class="sk line"></span>
          <span class="sk line short"></span>
        </div>`,
        )
        .join("")}
    </div>`;
}

function renderEmpty(query: string) {
  resultsEl.innerHTML = `
    <div class="empty">
      <h2>No results yet</h2>
      <p>Nothing ranked for “${escapeHtml(query)}”. Try a more specific phrase, or switch to local seed.</p>
      <button type="button" class="btn btn-secondary" id="empty-retry">Search again</button>
    </div>`;
  document.querySelector("#empty-retry")?.addEventListener("click", () => {
    qInput.focus();
  });
}

function renderError(message: string) {
  resultsEl.innerHTML = `
    <div class="error-box">
      <h2>Search couldn’t finish</h2>
      <p>${escapeHtml(message)}</p>
      <button type="button" class="btn btn-secondary" id="error-retry">Try again</button>
    </div>`;
  document.querySelector("#error-retry")?.addEventListener("click", () => {
    void runSearch(qInput.value.trim());
  });
}

function renderHits(hits: Hit[]) {
  resultsEl.innerHTML = hits
    .map((hit) => {
      const badges = hit.badges
        .map(
          (b) =>
            `<span class="badge ${badgeClass(b)}">${escapeHtml(b.replaceAll("_", " "))}</span>`,
        )
        .join("");
      return `
      <article class="result">
        <h2 class="result-title">
          <a href="${escapeHtml(hit.url)}" target="_blank" rel="noreferrer">
            ${escapeHtml(hit.title)}
          </a>
        </h2>
        <div class="result-url">${escapeHtml(hit.url)}</div>
        <p class="result-snippet">${escapeHtml(hit.snippet)}</p>
        <div class="result-meta">
          ${badges}
          <span class="badge badge-neutral">${escapeHtml(hit.fetch_engine.replaceAll("_", " "))}</span>
          <button type="button" class="btn btn-tertiary btn-sm" data-open="servo" data-url="${escapeHtml(hit.url)}">Open in Servo</button>
          <button type="button" class="btn btn-tertiary btn-sm" data-open="ladybird" data-url="${escapeHtml(hit.url)}">Open in Ladybird</button>
          <span class="score">score ${hit.betterweb_score} · craft ${hit.craft}</span>
        </div>
      </article>`;
    })
    .join("");
}

function updateClearVisibility() {
  clearBtn.hidden = qInput.value.length === 0;
}

async function loadEngines() {
  const data = await api<{ engines: Engine[] }>("/api/engines");
  renderEngines(data.engines);
  const on = data.engines.filter((e) => e.available).map((e) => e.name);
  metaEl.textContent = `Ready · ${on.join(" · ") || "core only"}`;
}

async function runSearch(query: string) {
  if (!query) {
    qInput.focus();
    return;
  }
  const mode = selectedMode();
  searchBtn.disabled = true;
  searchBtn.textContent = "Searching…";
  resultsEl.setAttribute("aria-busy", "true");
  metaEl.textContent =
    mode === "live"
      ? `Discovering and ranking “${query}”…`
      : `Searching local seed for “${query}”…`;

  window.clearTimeout(skeletonTimer);
  skeletonTimer = window.setTimeout(() => {
    if (resultsEl.getAttribute("aria-busy") === "true") renderSkeleton();
  }, 300);

  try {
    const data = await api<{
      hits: Hit[];
      ranking: string;
      count: number;
      mode?: string;
      fetched?: number;
      candidates?: number;
      errors?: string[];
    }>(`/api/search?q=${encodeURIComponent(query)}&mode=${encodeURIComponent(mode)}&limit=8`);

    window.clearTimeout(skeletonTimer);
    const extra =
      data.mode === "live"
        ? ` · ${data.candidates ?? "?"} candidates · ${data.fetched ?? "?"} fetched`
        : "";
    const err =
      data.errors && data.errors.length ? ` · ${data.errors.length} fetch warning(s)` : "";
    metaEl.textContent = `${data.count} results${extra}${err} · ${data.ranking}`;

    if (!data.hits.length) renderEmpty(query);
    else renderHits(data.hits);
  } catch (err) {
    window.clearTimeout(skeletonTimer);
    const message = err instanceof Error ? err.message : String(err);
    metaEl.textContent = "Search failed";
    renderError(message);
  } finally {
    resultsEl.setAttribute("aria-busy", "false");
    searchBtn.disabled = false;
    searchBtn.textContent = "Search web";
  }
}

document.querySelector("#search-form")!.addEventListener("submit", (ev) => {
  ev.preventDefault();
  void runSearch(qInput.value.trim());
});

document.querySelectorAll('input[name="mode"]').forEach((el) => {
  el.addEventListener("change", () => syncModeThumb());
});

clearBtn.addEventListener("click", () => {
  qInput.value = "";
  updateClearVisibility();
  qInput.focus();
});

qInput.addEventListener("input", updateClearVisibility);

window.addEventListener("keydown", (ev) => {
  if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === "k") {
    ev.preventDefault();
    qInput.focus();
    qInput.select();
  }
});

document.querySelector("#ingest-form")!.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const url = document.querySelector<HTMLInputElement>("#ingest-url")!.value.trim();
  ingestMeta.textContent = "Fetching page…";
  try {
    const data = await api<{ fetch_engine: string; document: { title: string } }>(
      "/api/ingest",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url, judge: false, prefer_lightpanda: true }),
      },
    );
    ingestMeta.textContent = `Indexed via ${data.fetch_engine}: ${data.document.title}`;
  } catch (err) {
    ingestMeta.textContent = `Ingest failed: ${err instanceof Error ? err.message : String(err)}`;
  }
});

document.querySelector("#reload-seed")!.addEventListener("click", async () => {
  const data = await api<{ reloaded: number }>("/api/seed/reload", { method: "POST" });
  ingestMeta.textContent = `Seed reloaded (${data.reloaded} docs)`;
});

resultsEl.addEventListener("click", async (ev) => {
  const target = ev.target as HTMLElement;
  const engine = target.getAttribute("data-open");
  const url = target.getAttribute("data-url");
  if (!engine || !url) return;
  try {
    await api("/api/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ engine, url }),
    });
    metaEl.textContent = `Opened in ${engine}`;
  } catch (err) {
    metaEl.textContent = `${engine} unavailable: ${err instanceof Error ? err.message : String(err)}`;
  }
});

syncModeThumb();
updateClearVisibility();
void loadEngines().then(() => runSearch(qInput.value.trim()));
