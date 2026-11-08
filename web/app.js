// Vlnka – webová verze. Stejné chování jako aplikace pro Mac/iPhone:
// předvolby, vyhledávání, ovládání ze zamčené obrazovky a automatické obnovení spojení.
"use strict";

const BASE = 10; // prvních 10 míst je vždy vidět (klávesy 1–0), další přibývají bez omezení
const DEFAULTS = [
  { name: "BBC Radio 6 Music", country: "Velká Británie", codec: "AAC", bitrate: 96,
    url: "https://as-hls-ww-live.akamaized.net/pool_81827798/live/ww/bbc_6music/bbc_6music.isml/bbc_6music-audio%3d96000.norewind.m3u8" },
  { name: "FM4", country: "Rakousko", codec: "MP3", bitrate: 192, url: "https://orf-live.ors-shoutcast.at/fm4-q2a", np: "fm4" },
  { name: "Lounge Radio", country: "Švýcarsko", codec: "MP3", bitrate: 128, url: "https://fr1.streamhosting.ch/lounge128.mp3" },
  { name: "Radio Paradise", country: "USA", codec: "AAC", bitrate: 128, url: "https://stream.radioparadise.com/aac-128" },
  { name: "FIP", country: "Francie", codec: "AAC", bitrate: 192, url: "https://icecast.radiofrance.fr/fip-hifi.aac" },
  { name: "FIP Groove", country: "Francie", codec: "AAC", bitrate: 192, url: "https://icecast.radiofrance.fr/fipgroove-hifi.aac" },
  { name: "KEXP 90.3 Seattle", country: "USA", codec: "AAC", bitrate: 160, url: "https://kexp.streamguys1.com/kexp160.aac", np: "kexp" },
  { name: "ČRo Radio Wave", country: "Česko", codec: "MP3", bitrate: 128, url: "https://rozhlas.stream/wave_mp3_128.mp3", np: "rozhlas:radiowave" },
  { name: "FluxFM", country: "Německo", codec: "MP3", bitrate: 320, url: "https://streams.fluxfm.de/live/mp3-320/audio/" },
  null,
];

// ---------- úložiště (může selhat v soukromém okně) ----------
const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};
const uid = () => Math.random().toString(36).slice(2, 10);
const withId = s => s ? { ...s, id: s.id || uid() } : null;

let presets = store.get("vlnka.presets.v1", null);
if (!Array.isArray(presets)) presets = DEFAULTS.map(withId);
presets = Array.from({ length: Math.max(BASE, presets.length) }, (_, i) => withId(presets[i] || null));
const savePresets = () => store.set("vlnka.presets.v1", presets);
savePresets();

// ---------- stav ----------
const S = {
  current: null, state: "stopped", track: "",
  episode: null, resumeAt: 0, archive: [], archiveState: "idle", archiveAt: 0, scrubbing: false,
  wantsPlaying: false, reconnecting: false, online: navigator.onLine,
  notPlayingSince: null, lastAttempt: 0, retry: 0,
};
const $ = id => document.getElementById(id);
const audio = $("audio");
let hls = null, hlsLoading = null;

const subtitle = s => {
  const p = [];
  if (s.country) p.push(s.country);
  if (s.codec) p.push(String(s.codec).toUpperCase());
  if (s.bitrate > 0) p.push(`${s.bitrate} kb/s`);
  return p.length ? p.join(" · ") : "Vlastní stream";
};
const isActive = () => ["playing", "loading", "reconnecting"].includes(S.state);
const isHls = url => /\.m3u8(\?|$)/i.test(url);

// ---------- přehrávání ----------
function loadHlsLib() {
  if (window.Hls) return Promise.resolve();
  if (!hlsLoading) hlsLoading = new Promise((res, rej) => {
    const s = document.createElement("script");
    s.src = "vendor/hls.min.js"; s.onload = res; s.onerror = rej;
    document.head.appendChild(s);
  });
  return hlsLoading;
}

async function attach(url) {
  if (hls) { hls.destroy(); hls = null; }
  if (isHls(url) && !audio.canPlayType("application/vnd.apple.mpegurl")) {
    await loadHlsLib();                       // Chrome/Edge (Windows) neumí HLS sám
    hls = new Hls({ liveDurationInfinity: true });
    hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal) markBroken(); });
    hls.loadSource(url);
    hls.attachMedia(audio);
  } else {
    audio.src = url;
  }
}

let startToken = 0;
// ---------- archiv FM4 (ORF nabízí epizody 7 dní) ----------
const SHOWS = ["4DD", "4GP"]; // Davidecks, Worldwide Show
const isFM4 = st => !!st && st.url.includes("orf-live.ors-shoutcast.at/fm4");
const dateText = ms => {
  const d = new Date(ms);
  return `${["ne", "po", "út", "st", "čt", "pá", "so"][d.getDay()]} ${d.getDate()}. ${d.getMonth() + 1}.`;
};
const lengthText = sec => {
  const m = Math.round(sec / 60);
  return m >= 60 ? (m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`) : `${m} min`;
};
const clock = t => {
  const s = Math.max(0, Math.floor(t || 0));
  return `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
};

async function loadArchive(force = false) {
  if (!isFM4(S.current) || S.archiveState === "loading") return;
  if (!force && S.archiveState === "loaded" && Date.now() - S.archiveAt < 3600000) return;
  S.archiveState = "loading"; renderArchive();
  try {
    const days = await (await fetch("https://audioapi.orf.at/fm4/api/json/current/broadcasts")).json();
    const now = Date.now();
    const all = days.flatMap(d => d.broadcasts).filter(b => b.isOnDemand && b.end < now);
    const out = [];
    for (const key of SHOWS) {
      const b = all.filter(x => x.programKey === key).sort((a, c) => c.end - a.end)[0];
      if (!b) continue;
      const st = (await (await fetch(b.href)).json()).streams?.[0];
      if (!st) continue;
      out.push({ show: b.title.trim(), start: st.start, duration: (st.end - st.start) / 1000,
                 url: `https://loopstream01.apa.at/?channel=fm4&shoutcast=0&id=${encodeURIComponent(st.loopStreamId)}` });
    }
    S.archive = out; S.archiveAt = Date.now(); S.archiveState = "loaded";
    // pozice epizod, které už v archivu nejsou, nejsou potřeba
    for (const u of Object.keys(progress)) if (!out.some(x => x.url === u) && u !== S.episode?.url) delete progress[u];
    store.set("vlnka.progress.v1", progress);
  } catch { S.archiveState = "failed"; }
  renderArchive();
}

// Rozposlouchané epizody (adresa → sekundy); přežije přepnutí stanice i zavření stránky.
let progress = store.get("vlnka.progress.v1", {});
let lastProgressSave = 0;
function saveProgress() {
  const e = S.episode;
  if (!e || S.resumeAt > 0) return;
  const t = audio.currentTime;
  if (!(t >= 0)) return;
  lastProgressSave = Date.now();
  if (t < 30 || t >= e.duration - 60) delete progress[e.url]; else progress[e.url] = t;
  store.set("vlnka.progress.v1", progress);
}

function playEpisode(e) {
  if (!S.current) return;
  if (S.episode?.url === e.url) { if (!isActive()) toggle(); return; } // stejná epizoda: nezačínat znovu
  S.retry = 0; S.reconnecting = false;
  saveProgress();
  S.episode = e; S.resumeAt = progress[e.url] || 0;
  start(S.current);
}
function seekTo(t) {
  if (!S.episode) return;
  audio.currentTime = t;
  saveProgress();
  updateProgress();
}

function renderArchive() {
  const box = $("archive");
  const show = isFM4(S.current);
  box.hidden = !show;
  if (!show) return;
  $("archiveProgress").hidden = !S.episode;
  const row = (title, sub, active, fn) => {
    const b = el("button", "arow" + (active ? " active" : ""));
    b.type = "button";
    b.append(el("span", "ico " + (active ? "ico-speaker" : "ico-play")));
    const t = el("span", "txt");
    t.append(el("span", "nm", title), el("span", "sb", sub));
    b.append(t);
    b.addEventListener("click", fn);
    return b;
  };
  const rows = [row("Živé vysílání", "FM4 právě teď", !S.episode && S.state !== "stopped", () => play(S.current))];
  for (const e of S.archive) {
    const here = S.episode?.url === e.url, at = progress[e.url];
    rows.push(row(e.show, `${dateText(e.start)} · ${!here && at ? `pokračovat od ${clock(at)}` : lengthText(e.duration)}`, here, () => playEpisode(e)));
  }
  if (S.archiveState === "loading" && !S.archive.length) rows.push(el("div", "muted small anote", "Načítám archiv…"));
  if (S.archiveState === "failed") {
    const n = el("div", "muted small anote", "Archiv se nepodařilo načíst. ");
    const again = el("button", "link small", "Zkusit znovu");
    again.type = "button"; again.addEventListener("click", () => loadArchive(true));
    n.append(again); rows.push(n);
  }
  $("archiveRows").replaceChildren(...rows);
  updateProgress();
}

function updateProgress() {
  if (!S.episode) return;
  const seek = $("seek");
  seek.max = S.episode.duration;
  if (!S.scrubbing) seek.value = audio.currentTime || S.resumeAt || 0;
  $("seekNow").textContent = clock(+seek.value);
  $("seekEnd").textContent = clock(S.episode.duration);
}

async function start(st, keepTrack = false) {
  const token = ++startToken;
  S.current = st;
  S.wantsPlaying = true;
  S.lastAttempt = Date.now();
  S.notPlayingSince = Date.now();
  if (!keepTrack) S.track = "";
  setState(S.reconnecting ? "reconnecting" : "loading");
  try {
    await attach(S.episode ? S.episode.url : st.url);
    await audio.play();
  } catch (e) {
    // starší pokus přerušený novějším (přepnutí stanice, nové napojení) – nic se nerozbilo
    if (token !== startToken || (e && e.name === "AbortError")) return;
    if (e && e.name === "NotAllowedError") { S.wantsPlaying = false; setState("paused"); return; }
    markBroken();
  }
  fetchNowPlaying();
}

function play(st) {
  saveProgress();
  S.retry = 0; S.reconnecting = false; S.episode = null; S.resumeAt = 0;
  start(st);
  loadArchive();
}

function pause() {
  saveProgress();
  S.wantsPlaying = false; S.reconnecting = false;
  audio.pause();
  setState("paused");
}

function stop() {
  saveProgress();
  S.wantsPlaying = false; S.reconnecting = false;
  audio.pause();
  if (hls) { hls.destroy(); hls = null; }
  audio.removeAttribute("src"); audio.load();
  S.track = ""; S.episode = null; S.resumeAt = 0;
  setState("stopped");
}

function toggle() {
  if (isActive()) pause();
  else if (S.episode && !audio.error && audio.getAttribute("src")) {  // epizoda pokračuje, kde se pozastavila
    S.wantsPlaying = true; S.notPlayingSince = Date.now();
    audio.play().catch(markBroken);
  } else if (S.episode) { S.retry = 0; S.resumeAt = S.resumeAt || 0; start(S.current); }
  else { const c = S.current || presets.find(Boolean); if (c) play(c); } // po pauze znovu na živé vysílání
}

function step(d) {
  const saved = presets.filter(Boolean);
  if (!saved.length) return;
  let i = saved.findIndex(s => s.id === S.current?.id);
  if (i < 0) i = d > 0 ? -1 : 0;
  play(saved[(i + d + saved.length) % saved.length]);
}

// ---------- automatické obnovení spojení ----------
function markBroken() {
  if (!S.wantsPlaying) { setState("error"); return; }
  // audio ve skutečnosti hraje (opožděná chyba starého pokusu) → nic neobnovovat
  if (S.online && !audio.paused && !audio.ended && !audio.error && audio.readyState > 2) return;
  S.reconnecting = true;
  setState("reconnecting");
}
function reconnect() {
  if (!S.current || !S.wantsPlaying) return;
  if (S.episode && S.retry >= 4) {      // epizoda mohla z archivu zmizet (po 7 dnech)
    S.wantsPlaying = false; S.reconnecting = false; audio.pause();
    S.archiveState = "idle"; loadArchive();
    setState("error");
    return;
  }
  S.retry++; S.reconnecting = true;
  if (S.episode && audio.currentTime > 0) S.resumeAt = audio.currentTime;
  start(S.current, true);
}
setInterval(() => {                    // hlídač: má hrát a 8 s nehraje → znovu (2, 4, 8 … max 30 s)
  if (!S.wantsPlaying || !S.current || !S.online || !S.notPlayingSince) return;
  const stuck = Date.now() - S.notPlayingSince > 8000 || S.reconnecting;
  const wait = Math.min(30000, 2000 * 2 ** S.retry);
  if (stuck && Date.now() - S.lastAttempt >= wait) reconnect();
}, 2000);

window.addEventListener("offline", () => { S.online = false; if (S.wantsPlaying) markBroken(); });
window.addEventListener("online", () => { S.online = true; if (S.wantsPlaying) { S.retry = 0; reconnect(); } });

audio.addEventListener("playing", () => {
  S.notPlayingSince = null; S.retry = 0; S.reconnecting = false; setState("playing");
});
audio.addEventListener("waiting", () => {
  if (!S.notPlayingSince) S.notPlayingSince = Date.now();
  if (S.wantsPlaying && !S.reconnecting) setState("loading");
});
audio.addEventListener("stalled", () => { if (!S.notPlayingSince) S.notPlayingSince = Date.now(); });
audio.addEventListener("error", () => { if (audio.getAttribute("src") || hls) markBroken(); });
audio.addEventListener("ended", () => {
  if (S.episode && audio.currentTime >= S.episode.duration - 30) { stop(); return; } // epizoda dohrála
  if (S.episode) S.resumeAt = audio.currentTime;
  S.reconnecting = true; if (S.wantsPlaying) setState("reconnecting");     // server stream ukončil
});
audio.addEventListener("loadedmetadata", () => {             // po výpadku pokračovat v epizodě
  if (S.episode && S.resumeAt > 0) { audio.currentTime = S.resumeAt; S.resumeAt = 0; }
});
audio.addEventListener("timeupdate", () => {
  updateProgress();
  if (S.state === "playing" && Date.now() - lastProgressSave >= 5000) saveProgress();
});
audio.addEventListener("pause", () => {                       // pauza z ovládání systému
  if (S.wantsPlaying && !audio.ended && audio.error == null && S.state === "playing") {
    S.wantsPlaying = false; setState("paused");
  }
});

// ---------- název skladby (jen stanice s veřejnými daty) ----------
let npTimer = null;
async function fetchNowPlaying() {
  clearTimeout(npTimer);
  const st = S.current;
  if (!st || !st.np || !S.wantsPlaying || S.episode) return;
  let line = "";
  try {
    if (st.np === "kexp") {
      const r = (await (await fetch("https://api.kexp.org/v2/plays/?limit=1")).json()).results?.[0];
      if (r && r.play_type === "trackplay" && r.artist) line = `${r.artist} – ${r.song}`;
    } else if (st.np === "fm4") {
      const list = await (await fetch("https://audioapi.orf.at/fm4/json/current/live")).json();
      const now = Date.now();
      const b = list.find(x => x.start <= now && now <= x.end) || list[0];
      if (b?.title) line = `Pořad: ${b.title.trim()}`;
    } else if (st.np.startsWith("rozhlas:")) {
      const id = st.np.split(":")[1];
      const d = (await (await fetch(`https://api.rozhlas.cz/data/v2/playlist/now/${id}.json`)).json()).data;
      if (d && d.status === "playing" && (d.interpret || d.track)) line = [d.interpret, d.track].filter(Boolean).join(" – ");
    }
  } catch {}
  if (S.current === st) { S.track = line; render(); }
  npTimer = setTimeout(fetchNowPlaying, 30000);
}

// ---------- zobrazení ----------
const LABEL = { playing: "Živě", loading: "Načítá se…", paused: "Pozastaveno", stopped: "Zastaveno",
                error: "Stream nejde", reconnecting: "Obnovuji spojení" };

function setState(s) { S.state = s; render(); }

function trackLine() {
  if (S.state === "reconnecting") return S.online ? "Obnovuji spojení…" : "Čekám na připojení k internetu…";
  if (S.state === "error") return "Stream se nepodařilo načíst";
  if (S.state === "stopped") return "";
  if (S.episode) return `${S.episode.show} · ${dateText(S.episode.start)}`;
  if (S.track) return S.track;
  return S.current ? "Živé vysílání" : "";
}

function render() {
  const c = S.current;
  $("statusDot").className = S.state;
  $("statusText").textContent = S.state === "playing" && S.episode ? "Z archivu" : LABEL[S.state];
  $("stationName").textContent = c ? c.name : "Zatím ticho";
  const tl = $("trackLine");
  tl.textContent = trackLine();
  tl.classList.toggle("error", S.state === "error");
  $("stationSub").textContent = c ? subtitle(c) : "Vyberte si stanici z předvoleb.";
  $("playIcon").className = "ico " + (isActive() ? "ico-pause" : "ico-play");
  $("playLabel").textContent = isActive() ? "Pozastavit" : "Přehrát";
  $("stopBtn").disabled = S.state === "stopped";
  const n = presets.filter(Boolean).length;
  $("savedCount").textContent = n === 1 ? "1 uložená" : n > 1 && n < 5 ? `${n} uložené` : `${n} uložených`;
  document.title = c && isActive() ? `${c.name} · Vlnka` : "Vlnka";
  renderGrid();
  renderArchive();
  updateMediaSession();
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function renderGrid() {
  const grid = $("grid");
  const shown = presets.includes(null) ? presets : [...presets, null]; // nic volného → „Přidat předvolbu“
  grid.replaceChildren(...shown.map((st, i) => {
    const extra = i >= presets.length;
    const active = st && st.id === S.current?.id && S.state !== "stopped";
    const cell = el("div", "cell" + (st ? "" : " empty") + (active ? " active" : ""));
    cell.tabIndex = 0;
    cell.setAttribute("role", "button");
    const txt = el("div", "txt");
    txt.append(el("div", "nm", st ? st.name : extra ? "Přidat předvolbu" : "Volné místo"),
      el("div", "sb", st ? subtitle(st) : extra ? "Další místo pro stanici" : "Klikněte a vyberte stanici"));
    cell.append(txt);
    if (st) {
      const more = el("button", "more");
      more.type = "button"; more.setAttribute("aria-label", "Možnosti předvolby");
      more.append(el("span", "ico ico-more"));
      more.addEventListener("click", e => { e.stopPropagation(); openMenu(i, more); });
      cell.append(more);
    }
    const act = () => st ? play(st) : openSearch(i);
    cell.addEventListener("click", act);
    cell.addEventListener("keydown", e => { if (e.key === "Enter") act(); });
    cell.title = st ? (i < 10 ? `Klávesa ${(i + 1) % 10}` : "") : "Vybrat stanici";
    return cell;
  }));
}

// ---------- nabídka předvolby ----------
const menu = $("menu");
function openMenu(i, anchor) {
  const items = [
    ["Přehrát", () => play(presets[i])],
    ["Upravit…", () => openEdit(i)],
    ["Nahradit jinou stanicí…", () => openSearch(i)],
    "-",
    ["Posunout dříve", () => move(i, -1), i === 0],
    ["Posunout později", () => move(i, 1), i >= presets.length - 1],
    "-",
    ["Odebrat", () => { if (i >= BASE) presets.splice(i, 1); else presets[i] = null; savePresets(); render(); }, false, "danger"],
  ];
  menu.replaceChildren(...items.map(it => {
    if (it === "-") return el("hr");
    const b = el("button", it[3] || "", it[0]);
    b.type = "button"; b.disabled = !!it[2];
    b.addEventListener("click", () => { closeMenu(); it[1](); });
    return b;
  }));
  menu.hidden = false;
  const r = anchor.getBoundingClientRect(), mw = menu.offsetWidth, mh = menu.offsetHeight;
  menu.style.left = Math.max(8, Math.min(r.right - mw, innerWidth - mw - 8)) + "px";
  menu.style.top = (r.bottom + mh + 8 > innerHeight ? r.top - mh - 4 : r.bottom + 4) + "px";
}
function closeMenu() { menu.hidden = true; }
document.addEventListener("click", e => { if (!menu.hidden && !menu.contains(e.target)) closeMenu(); });
function move(i, d) { const j = i + d; [presets[i], presets[j]] = [presets[j], presets[i]]; savePresets(); render(); }

// ---------- vyhledávání ----------
const searchDlg = $("searchDlg");
let searchSlot = null, mode = "tag", lastQuery = "";
const targetSlot = () => { if (searchSlot != null) return searchSlot; const i = presets.indexOf(null); return i < 0 ? presets.length : i; };
const setPreset = (i, st) => { presets[i] = st; for (let k = 0; k < presets.length; k++) if (presets[k] === undefined) presets[k] = null; };

function openSearch(slot = null) {
  searchSlot = slot;
  $("searchTitle").textContent = slot == null ? "Vyhledat stanici" : `Stanice pro ${slot + 1}. předvolbu`;
  updateTargetNote();
  searchDlg.showModal();
  if (!$("query").value) { $("query").value = "lounge"; }
  search();
}
document.querySelectorAll(".seg button").forEach(b => b.addEventListener("click", () => {
  mode = b.dataset.mode;
  document.querySelectorAll(".seg button").forEach(x => x.classList.toggle("on", x === b));
  $("query").placeholder = mode === "tag" ? "lounge, indie, jazz…" : "Radio Nova, SomaFM…";
  search();
}));
let qTimer;
$("query").addEventListener("input", () => { clearTimeout(qTimer); qTimer = setTimeout(search, 450); });
$("query").addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); search(); } });

async function search() {
  const q = $("query").value.trim();
  const box = $("results");
  if (!q) { box.replaceChildren(el("div", "hint", "Napište název nebo žánr.")); return; }
  const key = mode + ":" + q; lastQuery = key;
  box.replaceChildren(el("div", "hint", "Hledám…"));
  const u = new URL("https://de1.api.radio-browser.info/json/stations/search");
  u.search = new URLSearchParams({ [mode]: q, limit: 60, hidebroken: "true", order: "clickcount", reverse: "true" });
  try {
    const data = await (await fetch(u)).json();
    if (lastQuery !== key) return;
    const seen = new Set();
    const list = data.filter(r => r.url_resolved && r.url_resolved.startsWith("https://") && !seen.has(r.name.trim().toLowerCase()) && seen.add(r.name.trim().toLowerCase()))
      .map(r => ({ name: r.name.trim(), country: r.country, codec: r.codec, bitrate: r.bitrate, url: r.url_resolved }));
    if (!list.length) { box.replaceChildren(el("div", "hint", "Nic nenalezeno.")); return; }
    box.replaceChildren(...list.map(st => {
      const row = el("div", "row");
      const txt = el("div", "txt");
      txt.append(el("div", "nm", st.name), el("div", "sb", subtitle(st)));
      const pb = el("button", "iconbtn"); pb.type = "button"; pb.title = "Poslechnout";
      pb.append(el("span", "ico ico-play")); pb.addEventListener("click", () => play(st));
      const t = targetSlot();
      const sv = el("button", "btn btn-outline save", t >= 0 ? "Uložit" : "Plno");
      sv.type = "button"; sv.disabled = t < 0;
      if (t < 0) sv.title = "Všechny předvolby jsou obsazené – nějakou odeberte.";
      sv.addEventListener("click", () => {
        const slot = targetSlot(); if (slot < 0) return;
        setPreset(slot, withId({ ...st, id: null })); savePresets(); render();
        if (searchSlot != null) searchDlg.close(); else { updateTargetNote(); search(); }
      });
      row.append(txt, pb, sv);
      return row;
    }));
  } catch {
    box.replaceChildren(el("div", "hint", "Vyhledávání se nepovedlo. Zkontrolujte připojení."));
  }
}
function updateTargetNote() {
  const t = targetSlot();
  $("targetNote").textContent = searchSlot != null ? "" : t >= 0 ? `Uloží se na ${t + 1}. místo` : "Všechny předvolby jsou obsazené";
}
$("customBtn").addEventListener("click", () => { const t = targetSlot(); if (t >= 0) { searchDlg.close(); openEdit(t); } });

// ---------- úprava předvolby ----------
const editDlg = $("editDlg"), form = $("editForm");
let editSlot = 0;
function openEdit(i) {
  editSlot = i;
  const s = presets[i] || {};
  $("editTitle").textContent = `${i + 1}. předvolba`;
  for (const k of ["name", "url", "country", "codec"]) form.elements[k].value = s[k] || "";
  form.elements.bitrate.value = s.bitrate > 0 ? s.bitrate : "";
  editDlg.showModal();
}
const fromForm = () => ({
  id: presets[editSlot]?.id || uid(), np: presets[editSlot]?.np,
  name: form.elements.name.value.trim(), url: form.elements.url.value.trim(),
  country: form.elements.country.value.trim(), codec: form.elements.codec.value.trim(),
  bitrate: parseInt(form.elements.bitrate.value, 10) || 0,
});
form.addEventListener("submit", e => { e.preventDefault(); if (!form.reportValidity()) return; setPreset(editSlot, fromForm()); savePresets(); editDlg.close(); render(); });
$("editCancel").addEventListener("click", () => editDlg.close());
$("editTry").addEventListener("click", () => { if (form.reportValidity()) play(fromForm()); });
for (const d of [searchDlg, editDlg]) d.addEventListener("click", e => { if (e.target === d) d.close(); });

// ---------- ovládání ----------
$("playBtn").addEventListener("click", toggle);
$("stopBtn").addEventListener("click", stop);
$("searchBtn").addEventListener("click", () => openSearch(null));
const seekEl = $("seek");
seekEl.addEventListener("input", () => { S.scrubbing = true; $("seekNow").textContent = clock(+seekEl.value); });
seekEl.addEventListener("change", () => { S.scrubbing = false; seekTo(+seekEl.value); });
const vol = $("volume");
vol.value = audio.volume = store.get("vlnka.volume", 0.8);
vol.addEventListener("input", () => { audio.volume = +vol.value; store.set("vlnka.volume", +vol.value); });

document.addEventListener("keydown", e => {
  if (e.target.closest("input, dialog, textarea") || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === " ") { e.preventDefault(); toggle(); }
  else if (/^[0-9]$/.test(e.key)) { const st = presets[(+e.key + 9) % 10]; if (st) play(st); }
  else if (e.key === "ArrowRight") step(1);
  else if (e.key === "ArrowLeft") step(-1);
  else if (e.key === "Escape") closeMenu();
});

// Zamčená obrazovka, Ovládací centrum, multimediální klávesy
function updateMediaSession() {
  if (!("mediaSession" in navigator)) return;
  const c = S.current;
  if (!c || S.state === "stopped") { navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = "none"; return; }
  const title = S.episode ? S.episode.show : S.track && !S.track.startsWith("Pořad:") ? S.track : c.name;
  const m = navigator.mediaSession.metadata;
  if (!m || m.title !== title || m.artist !== c.name) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title, artist: c.name, album: "Vlnka",
      artwork: [{ src: "icons/icon-512.png", sizes: "512x512", type: "image/png" }],
    });
  }
  navigator.mediaSession.playbackState = isActive() ? "playing" : "paused";
}
if ("mediaSession" in navigator) {
  const h = (a, f) => { try { navigator.mediaSession.setActionHandler(a, f); } catch {} };
  h("play", () => { if (!isActive()) toggle(); });
  h("pause", () => { if (isActive()) pause(); });
  h("stop", stop);
  h("nexttrack", () => step(1));
  h("previoustrack", () => step(-1));
  h("seekto", d => { if (S.episode && d.seekTime != null) seekTo(d.seekTime); });
}

if ("serviceWorker" in navigator && location.protocol === "https:") {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}

render();
