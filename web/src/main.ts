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
`;

const enginesEl = document.querySelector<HTMLDivElement>("#engines")!;
const resultsEl = document.querySelector<HTMLDivElement>("#results")!;
const metaEl = document.querySelector<HTMLDivElement>("#meta")!;
const ingestMeta = document.querySelector<HTMLDivElement>("#ingest-meta")!;
const qInput = document.querySelector<HTMLInputElement>("#q")!;

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
      <div class="engine ${e.available ? "on" : "off"}" title="${e.detail}">
        <span class="dot"></span>
        <span>${e.name}</span>
        <span>${e.role}</span>
      </div>`,
    )
    .join("");
}

function renderHits(hits: Hit[], query: string) {
  if (!hits.length) {
    resultsEl.innerHTML = `<p class="empty">No matches for “${query}”.</p>`;
    return;
  }
  resultsEl.innerHTML = hits
    .map((hit, i) => {
      const badges = hit.badges
        .map((b) => `<span class="badge ${b}">${b.replaceAll("_", " ")}</span>`)
        .join("");
      return `
      <article class="card" style="animation-delay:${i * 40}ms">
        <h2><a href="${hit.url}" target="_blank" rel="noreferrer">${hit.title}</a></h2>
        <div class="url">${hit.url}</div>
        <p class="snippet">${hit.snippet}</p>
        <div class="row">
          ${badges}
          <span class="badge">${hit.fetch_engine}</span>
          <button class="btn-ghost" data-open="servo" data-url="${hit.url}">Open in Servo</button>
          <button class="btn-ghost" data-open="ladybird" data-url="${hit.url}">Open in Ladybird</button>
          <span class="score">score ${hit.betterweb_score} · craft ${hit.craft}</span>
        </div>
      </article>`;
    })
    .join("");
}

async function loadEngines() {
  const data = await api<{ engines: Engine[] }>("/api/engines");
  renderEngines(data.engines);
  const on = data.engines.filter((e) => e.available).map((e) => e.name);
  metaEl.textContent = `Engines ready: ${on.join(", ") || "none"}`;
}

async function runSearch(query: string) {
  metaEl.textContent = `Searching “${query}”…`;
  const data = await api<{ hits: Hit[]; ranking: string; count: number }>(
    `/api/search?q=${encodeURIComponent(query)}`,
  );
  metaEl.textContent = `${data.count} results · ${data.ranking}`;
  renderHits(data.hits, query);
}

document.querySelector("#search-form")!.addEventListener("submit", (ev) => {
  ev.preventDefault();
  void runSearch(qInput.value.trim());
});

document.querySelector("#ingest-form")!.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const url = document.querySelector<HTMLInputElement>("#ingest-url")!.value.trim();
  ingestMeta.textContent = "Fetching…";
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
    if (qInput.value.trim()) void runSearch(qInput.value.trim());
  } catch (err) {
    ingestMeta.textContent = `Ingest failed: ${err instanceof Error ? err.message : String(err)}`;
  }
});

document.querySelector("#reload-seed")!.addEventListener("click", async () => {
  const data = await api<{ reloaded: number }>("/api/seed/reload", { method: "POST" });
  ingestMeta.textContent = `Seed reloaded (${data.reloaded} docs)`;
  void runSearch(qInput.value.trim() || "heater");
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

void loadEngines().then(() => runSearch(qInput.value.trim()));
