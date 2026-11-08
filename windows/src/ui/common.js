// Shared UI helpers for the main window and the quick panel.
'use strict';

// ---------- DOM ----------
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style' && typeof v === 'object') {
      for (const [sk, sv] of Object.entries(v)) {
        if (sk.startsWith('--')) el.style.setProperty(sk, sv); else el.style[sk] = sv;
      }
    }
    else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'html') el.innerHTML = v;
    else if (k in el && typeof v !== 'string') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
const $ = (sel, root = document) => root.querySelector(sel);
function mount(el, ...kids) { el.replaceChildren(...kids.flat(Infinity).filter((k) => k != null && k !== false)); return el; }

// ---------- icons (stroke icons, 24px grid) ----------
const ICONS = {
  link: 'M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7',
  clipboard: 'M9 4h6v3H9zM8 5H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1h-2',
  x: 'M6 6l12 12M18 6L6 18',
  xc: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9 9l6 6M15 9l-6 6',
  film: 'M3 5h18v14H3zM7 5v14M17 5v14M3 9h4M3 15h4M17 9h4M17 15h4',
  wave: 'M3 12h2M7 8v8M11 5v14M15 8v8M19 10v4M21 12h0',
  text: 'M4 6h16M4 10h16M4 14h10M4 18h12',
  aspect: 'M3 6h18v12H3zM7 10V8h3M17 14v2h-3',
  music: 'M9 18V5l11-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0z',
  image: 'M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M15.5 8.5h.01',
  tag: 'M3 12V4h8l9 9-8 8zM7.5 7.5h.01',
  captions: 'M3 5h18v12H8l-5 4zM7 11h3M13 11h4M7 14h6',
  layers: 'M12 3l9 5-9 5-9-5zM3 13l9 5 9-5',
  key: 'M14 10a4 4 0 1 0-1.2 2.8L21 21M17 17l2-2M15 15l1.5-1.5',
  down: 'M12 4v14M6 12l6 6 6-6',
  scissors: 'M6 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM20 4L8.1 15.9M14.5 14.5L20 20M8.1 8.1L12 12',
  folder: 'M3 6a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z',
  gear: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.7 1.7 0 0 0 3 15.1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.2-2.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.7 1.7 0 0 0 10 4.2V4a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0 1.2 2.9H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4',
  drive: 'M3 13h18v6H3zM5 13l2-8h10l2 8M7 16h.01',
  stack: 'M4 7h12v12H4zM8 3h12v12',
  check: 'M5 12l5 5L20 7',
  chev: 'M6 9l6 6 6-6',
  updown: 'M8 9l4-4 4 4M8 15l4 4 4-4',
  left: 'M15 6l-6 6 6 6',
  right: 'M9 6l6 6-6 6',
  flag: 'M5 21V4M5 4h11l-2 4 2 4H5',
  timer: 'M12 21a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM12 9v4l2 2M9 2h6',
  play: 'M7 4l13 8-13 8z',
  pause: 'M7 4h3v16H7zM14 4h3v16h-3z',
  list: 'M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01',
  flame: 'M12 21a6 6 0 0 0 6-6c0-4-3-6-4-10-2 2-3 4-3 6-1-1-2-2-2-4-2 2-3 5-3 8a6 6 0 0 0 6 6z',
  undo: 'M9 14L4 9l5-5M4 9h11a5 5 0 0 1 0 10h-3',
  zin: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4M8 11h6M11 8v6',
  zout: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4M8 11h6',
  expand: 'M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  refresh: 'M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7',
  alert: 'M12 3l10 18H2zM12 10v4M12 17h.01',
  bell: 'M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9M10 21h4',
  cmd: 'M9 6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3z',
  bookmark: 'M6 3h12v18l-6-4-6 4z',
  lock: 'M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7z',
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0',
  arrowr: 'M5 12h14M13 6l6 6-6 6',
  trash: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13',
  copy: 'M8 8h12v12H8zM4 16V4h12',
  tray: 'M3 13h5l1 3h6l1-3h5M5 5h14l2 8v6H3v-6z',
};
function icon(name, cls = '') {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('class', `i ${cls}`);
  const p = document.createElementNS(ns, 'path');
  p.setAttribute('d', ICONS[name] || '');
  if (name === 'play' || name === 'pause') { s.style.fill = 'currentColor'; s.style.stroke = 'none'; }
  s.append(p);
  return s;
}

// The download arrow from the logo: rounded stem flowing into a solid head.
function arrowSVG(cls = 'arrow') {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('viewBox', '0 0 36 56');
  s.setAttribute('class', cls);
  const p = document.createElementNS(ns, 'path');
  p.setAttribute('d', 'M11.9 25.8V6.1A6.1 6.1 0 0 1 24.1 6.1V25.8H36L18 56 0 25.8Z');
  s.append(p);
  return s;
}
function wordmark(size = 40, muted = false) {
  return h('span', { class: `wordmark${muted ? ' muted' : ''}`, style: { '--size': `${size}px` } }, 'dwn', arrowSVG());
}

// ---------- data ----------
const FORMATS = {
  video: [
    ['h264', 'H.264 .mp4', 'Plays everywhere. 1440p and 4K take longer to convert.'],
    ['hevc', 'HEVC .mp4', 'About a third smaller. Takes longer, as every video is converted.'],
    ['prores', 'ProRes .mov', 'For Premiere and After Effects. Much bigger files.'],
    ['original', 'Original', 'Exactly what the site sends, often VP9 or AV1. Fastest.'],
  ],
  audio: [
    ['mp3', 'MP3', 'Up to 320 kbps. Plays on every phone, car stereo and app.'],
    ['aac', 'AAC .m4a', 'The site\'s own sound, untouched.'],
    ['wav', 'WAV', 'Uncompressed, for editing. About ten times bigger.'],
  ],
  heights: [[0, 'Best available'], [2160, '4K'], [1440, '1440p'], [1080, '1080p'], [720, '720p'], [480, '480p']],
};
const CODEC_SHORT = { h264: 'H.264', hevc: 'HEVC', prores: 'ProRes', original: 'Original' };
function formatName(id) {
  for (const [k, n] of [...FORMATS.video, ...FORMATS.audio]) if (k === id) return n;
  return id || '';
}

// ---------- formatting ----------
function fmtTime(secs, tenths = false) {
  if (secs == null || !isFinite(secs)) return '–';
  const s = Math.max(0, secs);
  const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = Math.floor(s % 60);
  let out = hh > 0 ? `${hh}:${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}` : `${mm}:${String(ss).padStart(2, '0')}`;
  if (tenths) out += `.${Math.floor((s - Math.floor(s)) * 10)}`;
  return out;
}
function parseTime(str) {
  const t = String(str || '').trim().toLowerCase();
  if (!t) return null;
  if (t.includes(':')) {
    const parts = t.split(':').map(Number);
    if (parts.some(isNaN)) return null;
    return parts.reduce((a, b) => a * 60 + b, 0);
  }
  if (!isNaN(Number(t))) return Number(t);
  let total = 0; let num = '';
  for (const ch of t) {
    if (/[0-9.]/.test(ch)) { num += ch; continue; }
    const v = Number(num); if (isNaN(v) || num === '') return null;
    if (ch === 'h') total += v * 3600; else if (ch === 'm') total += v * 60; else if (ch === 's') total += v; else return null;
    num = '';
  }
  if (num) total += Number(num);
  return total;
}
function fmtBytes(b) {
  if (b == null) return '';
  const u = ['bytes', 'KB', 'MB', 'GB', 'TB']; let i = 0; let v = b;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
}
function relTime(sec) {
  const d = (Date.now() / 1000 - sec);
  if (d < 60) return 'just now';
  if (d < 3600) return `${Math.floor(d / 60)} minute${d < 120 ? '' : 's'} ago`;
  if (d < 86400) return `${Math.floor(d / 3600)} hour${d < 7200 ? '' : 's'} ago`;
  if (d < 172800) return 'yesterday';
  return new Date(sec * 1000).toLocaleDateString();
}
function looksLikeLink(s) {
  const t = String(s || '').trim();
  if (!t || /\s/.test(t)) return false;
  if (/^https?:\/\//i.test(t)) { try { new URL(t); return true; } catch { return false; } }
  return /^[a-z0-9-]+(\.[a-z0-9-]+)+\/\S*$/i.test(t);
}
const normalizeLink = (s) => { const t = String(s || '').trim(); return /^https?:/i.test(t) ? t : `https://${t}`; };
const fileURL = (p) => (p ? 'file:///' + encodeURI(String(p).replace(/\\/g, '/').replace(/^\/+/, '')).replace(/#/g, '%23') : '');
const SITE_NAMES = { Youtube: 'YouTube', YoutubeTab: 'YouTube', Twitter: 'X', Tiktok: 'TikTok', TikTok: 'TikTok', Soundcloud: 'SoundCloud' };

// ---------- instant YouTube preview ----------
function youtubeID(link) {
  let u; try { u = new URL(normalizeLink(link)); } catch { return null; }
  const host = u.hostname.toLowerCase(); const parts = u.pathname.split('/').filter(Boolean);
  let id = null;
  if (host.endsWith('youtu.be')) id = parts[0];
  else if (host.includes('youtube.com')) id = u.searchParams.get('v') || (['shorts', 'embed', 'live', 'v'].includes(parts[0]) ? parts[1] : null);
  return id && /^[\w-]{11}$/.test(id) ? id : null;
}
function quickInfo(link) {
  const id = youtubeID(link);
  return id ? { url: normalizeLink(link), thumbnail: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`, site: 'Youtube', quick: true } : null;
}

// ---------- engine calls ----------
async function api(path, body) {
  const r = await window.dwn.api(path, body);
  if (r.error) throw new Error(r.error);
  return r.data;
}
const invoke = (ch, ...a) => window.dwn.invoke(ch, ...a);

// ---------- toasts ----------
function toast(text, err = false) {
  let box = $('#toasts');
  if (!box) { box = h('div', { id: 'toasts' }); document.body.append(box); }
  const t = h('div', { class: `toast${err ? ' err' : ''}` }, icon(err ? 'alert' : 'check'), h('span', {}, text),
    err ? h('button', { class: 'btn-icon', title: 'Copy error details', onclick: () => invoke('clipboard:write', text) }, icon('copy', 'sm')) : null);
  box.append(t);
  setTimeout(() => t.remove(), err ? 6000 : 3000);
}

// ---------- image cache ----------
const imgCache = new Map();
function thumb(url, w, hgt, extra) {
  const box = h('div', { class: 'thumb', style: { width: `${w}px`, height: `${hgt}px` } });
  if (url) {
    const img = h('img', { draggable: false });
    const done = () => { img.classList.add('loaded'); box.classList.remove('shimmer'); imgCache.set(url, true); };
    if (!imgCache.has(url)) box.classList.add('shimmer');
    img.addEventListener('load', done);
    img.addEventListener('error', () => box.classList.remove('shimmer'));
    img.src = url;
    if (img.complete && img.naturalWidth) done();
    box.append(img);
  }
  if (extra) box.append(extra);
  return box;
}

// ---------- controls ----------
function tabs(items, value, onChange, height = 36) {
  const box = h('div', { class: 'tabs', style: { '--h': `${height}px` } });
  const pill = h('div', { class: 'pill' });
  box.append(pill);
  const btns = items.map(([id, title, ic]) => {
    const b = h('button', { class: id === value ? 'on' : '', onclick: () => {
      btns.forEach((x) => x.classList.remove('on')); b.classList.add('on'); place(); onChange(id);
    } }, icon(ic, 'sm'), title);
    return b;
  });
  box.append(...btns);
  function place() {
    const on = btns.find((b) => b.classList.contains('on'));
    if (!on) return;
    pill.style.left = `${on.offsetLeft}px`; pill.style.width = `${on.offsetWidth}px`;
  }
  requestAnimationFrame(place);
  new ResizeObserver(place).observe(box);
  return box;
}

function select(options, value, onChange, { iconName, height = 36 } = {}) {
  const cur = options.find((o) => String(o[0]) === String(value)) || options[0];
  const sel = h('select', { onchange: (e) => onChange(options.find((o) => String(o[0]) === e.target.value)[0]) },
    options.map(([id, title]) => h('option', { value: String(id), selected: String(id) === String(value) }, title)));
  return h('label', { class: 'select', style: { '--h': `${height}px` } },
    iconName ? icon(iconName) : null,
    h('span', { class: 'value' }, cur ? cur[1] : ''),
    cur && cur[2] ? h('span', { class: 'detail' }, cur[2]) : null,
    icon('updown', 'sm'), sel);
}

function optionRow(ic, title, on, onToggle, detail) {
  const sw = h('span', { class: `switch${on ? ' on' : ''}` });
  return h('button', { class: 'option', onclick: () => { sw.classList.toggle('on'); onToggle(sw.classList.contains('on')); } },
    icon(ic), h('span', { class: 't' }, title, detail ? h('span', { class: 'd' }, detail) : null), sw);
}

function tile(ic, title, on, onToggle) {
  const b = h('button', { class: `tile${on ? ' on' : ''}`, onclick: () => { b.classList.toggle('on'); onToggle(b.classList.contains('on')); } },
    icon(ic), title);
  return b;
}

function progress(value, indeterminate) {
  return h('div', { class: `progress${indeterminate ? ' indet' : ''}` }, h('div', { style: { width: `${Math.round((value || 0) * 100)}%` } }));
}

// Small floating menu (right-click etc.)
function popupMenu(x, y, items) {
  document.querySelectorAll('.menu').forEach((m) => m.remove());
  const m = h('div', { class: 'menu' }, items.map((it) => (it === '-' ? h('hr')
    : h('button', { class: it.danger ? 'danger' : '', onclick: () => { m.remove(); it.run(); } }, it.label))));
  document.body.append(m);
  const r = m.getBoundingClientRect();
  m.style.left = `${Math.min(x, innerWidth - r.width - 8)}px`;
  m.style.top = `${Math.min(y, innerHeight - r.height - 8)}px`;
  setTimeout(() => addEventListener('mousedown', function close(e) {
    if (!m.contains(e.target)) { m.remove(); removeEventListener('mousedown', close); }
  }), 0);
}

function modal(content, { width = 480, onClose } = {}) {
  const back = h('div', { class: 'modal-back' });
  const box = h('div', { class: 'modal', style: { width: `${width}px` } }, content);
  back.append(box);
  const close = () => { back.remove(); removeEventListener('keydown', esc, true); onClose && onClose(); };
  const esc = (e) => { if (e.key === 'Escape' && document.querySelectorAll('.modal-back').length && back === [...document.querySelectorAll('.modal-back')].pop()) { e.stopPropagation(); close(); } };
  addEventListener('keydown', esc, true);
  back.addEventListener('mousedown', (e) => { if (e.target === back) close(); });
  document.body.append(back);
  return { close, box };
}
