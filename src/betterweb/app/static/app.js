const omni = document.getElementById("omni");
const form = document.getElementById("omni-form");
const results = document.getElementById("results");
const frame = document.getElementById("frame");
const empty = document.getElementById("empty");
const status = document.getElementById("status");

function isUrl(value) {
  return /^(https?:\/\/|www\.)/i.test(value.trim());
}

function normalizeUrl(value) {
  const raw = value.trim();
  if (/^https?:\/\//i.test(raw)) return raw;
  return "https://" + raw.replace(/^www\./i, "www.");
}

function setStatus(text) {
  status.hidden = !text;
  status.textContent = text || "";
}

function showFrame() {
  empty.hidden = true;
  frame.hidden = false;
}

async function searchIndex(query) {
  const response = await fetch("/api/search?limit=20&q=" + encodeURIComponent(query));
  if (!response.ok) throw new Error("search failed");
  return response.json();
}

function renderHits(hits, activeUrl) {
  results.hidden = hits.length === 0;
  results.innerHTML = "";
  for (const hit of hits) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "result" + (hit.url === activeUrl ? " active" : "");
    button.innerHTML =
      "<strong></strong><div class='meta'></div><div class='snip'></div>";
    button.querySelector("strong").textContent = hit.title;
    button.querySelector(".meta").textContent =
      "Craft " + hit.craftrank_score.toFixed(1) + " · " + hit.url.replace(/^https?:\/\//, "");
    button.querySelector(".snip").textContent = hit.snippet || "";
    button.addEventListener("click", () => openUrl(hit.url, hits));
    results.appendChild(button);
  }
}

async function openUrl(url, hits) {
  omni.value = url;
  if (hits) renderHits(hits, url);
  setStatus("Loading…");
  showFrame();
  const response = await fetch("/api/browse?url=" + encodeURIComponent(url));
  const view = await response.json();
  if (view.mode === "embed" && view.embed_url) {
    frame.removeAttribute("srcdoc");
    frame.src = view.embed_url;
    setStatus("Chromium embed");
    return;
  }
  if (view.mode === "reader" && view.html) {
    frame.removeAttribute("src");
    frame.srcdoc = view.html;
    setStatus(view.engine === "html" ? "HTML" : "Chromium render");
    return;
  }
  if (view.mode === "live") {
    frame.removeAttribute("srcdoc");
    frame.src = view.url;
    setStatus("Live Chromium");
    return;
  }
  frame.removeAttribute("src");
  frame.srcdoc = "<p>" + (view.error || "Could not open this page.") + "</p>";
  setStatus("Failed");
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const value = omni.value.trim();
  if (!value) return;
  try {
    if (isUrl(value)) {
      await openUrl(normalizeUrl(value));
      return;
    }
    setStatus("Searching…");
    const data = await searchIndex(value);
    renderHits(data.hits);
    if (data.hits[0]) {
      await openUrl(data.hits[0].url, data.hits);
    } else {
      setStatus("No hits");
      empty.hidden = false;
    }
  } catch (err) {
    setStatus(String(err.message || err));
  }
});
