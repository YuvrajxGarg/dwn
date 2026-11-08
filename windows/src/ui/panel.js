// Quick download panel: shortcut or tray click opens it in a screen corner.
'use strict';

const P = { settings: {}, prefs: {}, info: null, looking: false, error: null, jobs: [], started: false, browsers: [] };
const panel = $('#panel');
const input = h('input', { placeholder: 'Paste a link', spellcheck: false,
  oninput: () => onLink(), onkeydown: (e) => { if (e.key === 'Enter') start(); if (e.key === 'Escape') invoke('panel:hide'); } });
const trail = h('span');
const slots = { preview: h('div'), tabs: h('div'), picker: h('div'), tiles: h('div'), actions: h('div'), active: h('div') };

mount(panel,
  h('div', { class: 'head' }, wordmark(15), h('div', { style: { flex: 1 } }),
    h('button', { class: 'btn-icon', style: { width: '26px', height: '26px' }, title: 'Open Dwn', onclick: () => invoke('main:show') }, icon('expand', 'sm')),
    h('button', { class: 'btn-icon', style: { width: '26px', height: '26px' }, title: 'Close (Esc)', onclick: () => invoke('panel:hide') }, icon('x', 'sm'))),
  h('label', { class: 'field' }, icon('link'), input, trail),
  slots.preview, slots.tabs, slots.picker, slots.tiles, slots.actions, slots.active);

addEventListener('keydown', (e) => { if (e.key === 'Escape') invoke('panel:hide'); });
new ResizeObserver(() => invoke('panel:size', Math.ceil(panel.getBoundingClientRect().height))).observe(panel);

window.dwn.onPanelShow(async ({ clipboard }) => {
  P.settings = await invoke('settings:get');
  try { P.prefs = await api('prefs'); } catch {}
  P.browsers = await invoke('browsers');
  P.justStarted = false;
  const clip = (clipboard || '').trim();
  if (!input.value && looksLikeLink(clip) && !P.jobs.some((j) => j.url === normalizeLink(clip) && isActiveJob(j))) {
    input.value = clip;
    onLink();
  }
  renderAll();
  setTimeout(() => { input.focus(); input.select(); }, 30);
  if (!P.started) { P.started = true; pollJobs(); }
});

const isActiveJob = (j) => ['queued', 'running', 'converting'].includes(j.state);
const link = () => input.value.trim();
const valid = () => looksLikeLink(link());
const tab = () => P.settings.tab || 'video';

async function pollJobs() {
  for (;;) {
    try { P.jobs = await api('jobs'); renderActive(); } catch {}
    await new Promise((r) => setTimeout(r, P.jobs.some(isActiveJob) ? 600 : 2500));
  }
}

let seq = 0;
function onLink() {
  mount(trail, input.value
    ? h('button', { class: 'btn-icon', onclick: () => { input.value = ''; onLink(); input.focus(); } }, icon('xc', 'sm'))
    : h('button', { class: 'btn-link', style: { padding: '0 8px' }, onclick: async () => { input.value = (await invoke('clipboard:read')).trim(); onLink(); } }, 'Paste'));
  const my = ++seq;
  P.info = null; P.error = null; P.looking = false; P.justStarted = false;
  if (!valid()) return renderPreview(), renderActions();
  const target = normalizeLink(link());
  const q = quickInfo(target);
  if (q) {
    P.info = q;
    invoke('oembed', target).then((o) => { if (o && my === seq && P.info && !P.info.title) { P.info.title = o.title; P.info.uploader = o.author; renderPreview(); } });
  }
  P.looking = true;
  renderPreview(); renderActions();
  setTimeout(async () => {
    if (my !== seq) return;
    try {
      const full = await api('info', { url: target });
      if (my !== seq) return;
      if (P.info && P.info.thumbnail && !full.is_playlist) full.thumbnail = P.info.thumbnail;
      P.info = full;
    } catch { if (my === seq && !q) P.error = 'Couldn\'t read that link. You can still try downloading it.'; }
    P.looking = false;
    renderPreview(); renderActions();
  }, q ? 0 : 200);
}

function renderAll() { onLinkTrailOnly(); renderPreview(); renderTabs(); renderPicker(); renderTiles(); renderActions(); renderActive(); }
function onLinkTrailOnly() {
  mount(trail, input.value
    ? h('button', { class: 'btn-icon', onclick: () => { input.value = ''; onLink(); input.focus(); } }, icon('xc', 'sm'))
    : h('button', { class: 'btn-link', style: { padding: '0 8px' }, onclick: async () => { input.value = (await invoke('clipboard:read')).trim(); onLink(); } }, 'Paste'));
}

function renderPreview() {
  if (P.justStarted) return mount(slots.preview, h('div', { class: 'ok' }, icon('check'), 'Download started'));
  if (link() && !valid()) return mount(slots.preview, h('div', { class: 'warn', style: { padding: '0 2px' } }, 'That doesn\'t look like a link.'));
  if (P.looking && !P.info) return mount(slots.preview, h('div', { class: 'prev' }, h('div', { class: 'thumb shimmer', style: { width: '56px', height: '32px' } }), h('div', { class: 'meta' }, h('div', { class: 'bar shimmer' }))));
  if (P.error) return mount(slots.preview, h('div', { class: 'faint', style: { padding: '0 2px', fontSize: '11.5px' } }, P.error));
  if (!P.info) return mount(slots.preview);
  const i = P.info;
  mount(slots.preview, h('div', { class: 'prev' }, thumb(i.thumbnail, 56, 32),
    h('div', { class: 'meta' }, i.title ? h('div', { class: 't' }, i.title) : h('div', { class: 'bar shimmer', style: { width: '160px' } }),
      h('div', { class: 's' }, [i.uploader, i.is_playlist ? `${i.count || 0} items` : i.duration ? fmtTime(i.duration) : null].filter(Boolean).join(' · ')))));
}

function renderTabs() {
  mount(slots.tabs, tabs([['video', 'Video', 'film'], ['audio', 'Audio', 'wave'], ['transcript', 'Transcript', 'text']], tab(), async (t) => {
    P.settings.tab = t;
    await invoke('settings:set', { tab: t });
    if (t !== 'transcript') api('prefs', { kind: t }).catch(() => {});
    renderPicker(); renderTiles(); renderActions();
  }));
}

function setPref(patch) { Object.assign(P.prefs, patch); api('prefs', patch).catch(() => {}); }

function renderPicker() {
  if (tab() === 'video') {
    return mount(slots.picker, select(FORMATS.heights.map(([v, n]) => [v, n, CODEC_SHORT[P.prefs.video_format] || '']), P.prefs.max_height || 0,
      (v) => { setPref({ max_height: Number(v) }); renderPicker(); }, { iconName: 'aspect' }));
  }
  if (tab() === 'audio') {
    return mount(slots.picker, select(FORMATS.audio.map(([id, n]) => [id, n]), P.prefs.audio_format || 'mp3',
      (v) => { setPref({ audio_format: v }); renderPicker(); }, { iconName: 'music' }));
  }
  mount(slots.picker, h('div', { class: 'fill', style: { display: 'flex', gap: '8px', alignItems: 'center', height: '36px', padding: '0 12px', color: 'var(--text2)' } },
    icon('captions'), 'Saves the captions as a text file'));
}

function renderTiles() {
  if (tab() === 'transcript') return mount(slots.tiles);
  const t = [
    tile('image', 'Cover', P.prefs.embed_thumbnail !== false, (v) => setPref({ embed_thumbnail: v })),
    tile('tag', 'Metadata', P.prefs.embed_metadata !== false, (v) => setPref({ embed_metadata: v })),
  ];
  if (tab() === 'video') {
    t.push(tile('captions', 'Subtitles', !!P.prefs.embed_subs, (v) => setPref({ embed_subs: v })));
    t.push(tile('layers', 'ProRes', P.prefs.video_format === 'prores', (v) => {
      if (v) { localStorage.codecBefore = P.prefs.video_format; setPref({ video_format: 'prores' }); }
      else setPref({ video_format: (localStorage.codecBefore && localStorage.codecBefore !== 'prores') ? localStorage.codecBefore : 'h264' });
      renderPicker();
    }));
  }
  t.push(tile('key', 'Login', !!P.prefs.browser_cookies, (v) => {
    if (v) invoke('main:show', { signin: true }); else setPref({ browser_cookies: '' });
  }));
  mount(slots.tiles, h('div', { class: 'tiles' }, t));
}

function renderActions() {
  const label = tab() === 'transcript' ? 'Save transcript' : (P.info && P.info.is_playlist ? `Download all ${P.info.count || 0}` : 'Download');
  mount(slots.actions, h('div', { class: 'acts' },
    h('button', { class: 'btn-primary', disabled: !valid(), onclick: start }, icon(tab() === 'transcript' ? 'text' : 'down'), label),
    tab() !== 'transcript' ? h('button', { class: 'btn-icon', title: 'Download just a section (opens Dwn)', disabled: !valid() || (P.info && P.info.is_playlist),
      onclick: () => invoke('main:show', { section: P.info || { url: normalizeLink(link()) } }) }, icon('scissors')) : null));
}

function renderActive() {
  const active = P.jobs.filter(isActiveJob);
  if (!active.length) return mount(slots.active);
  mount(slots.active, h('div', { class: 'active' }, active.slice(0, 3).map((j) => h('div', { class: 'aj' },
    thumb(j.thumbnail, 40, 23),
    h('div', { class: 'm' }, h('div', { class: 'r' }, h('b', {}, j.title),
      h('span', { class: 'mono' }, j.state === 'running' && j.progress > 0 ? `${Math.round(j.progress * 100)}%` : j.stage)),
    progress(j.progress, j.state === 'queued' || j.progress <= 0)),
    h('button', { class: 'btn-icon', style: { width: '22px', height: '22px' }, title: 'Stop downloading', onclick: () => api(`jobs/${j.id}/cancel`, {}) }, icon('x', 'sm')))),
  active.length > 3 ? h('button', { class: 'btn-link', style: { textAlign: 'left' }, onclick: () => invoke('main:show') }, `+${active.length - 3} more`) : null));
}

async function start() {
  if (!valid()) return;
  const url = normalizeLink(link());
  try {
    if (tab() === 'transcript') await api('transcript', { url });
    else if (P.info && P.info.is_playlist) return invoke('main:show', { bulk: url });
    else {
      const kind = tab();
      await api('download', { url, kind, format: kind === 'video' ? P.prefs.video_format : P.prefs.audio_format,
        title: P.info && P.info.title, thumbnail: P.info && P.info.thumbnail });
    }
    input.value = ''; seq++; P.info = null; P.justStarted = true;
    onLinkTrailOnly(); renderPreview(); renderActions();
    P.jobs = await api('jobs'); renderActive();
    setTimeout(() => { P.justStarted = false; renderPreview(); }, 2000);
  } catch (e) {
    P.error = e.message; renderPreview();
  }
}

onLinkTrailOnly();
