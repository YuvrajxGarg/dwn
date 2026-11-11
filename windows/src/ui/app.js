// Dwn main window.
'use strict';

const S = {
  settings: {}, prefs: {}, health: null, jobs: [], history: [], historyLoaded: false,
  engine: { state: 'starting', message: '' }, update: {}, platform: 'win32', version: '',
  free: null, info: null, looking: false, lookupError: null, section: null, query: '', clip: '',
  doneSeen: new Set(), signinPrompted: false, browsers: [],
};
const IS_MAC = () => S.platform === 'darwin';
const shortcutLabel = () => (S.settings.shortcut || '').replace('CommandOrControl', IS_MAC() ? '⌘' : 'Ctrl')
  .replace('Command', '⌘').replace('Alt', IS_MAC() ? '⌥' : 'Alt').replace('Shift', IS_MAC() ? '⇧' : 'Shift')
  .replace('Control', IS_MAC() ? '⌃' : 'Ctrl');
const shortcutKeys = () => shortcutLabel().split('+');

// ============================================================ boot

(async function boot() {
  S.platform = await invoke('app:platform');
  S.version = await invoke('app:version');
  document.body.classList.add(S.platform === 'darwin' ? 'mac' : 'win');
  S.settings = await invoke('settings:get');
  S.update = await invoke('update:state');
  S.engine = await invoke('engine:state');
  window.dwn.onEngine((e) => { S.engine = e; onEngine(); });
  window.dwn.onSettings((s) => { S.settings = s; });
  window.dwn.onUpdate((u) => { S.update = u; renderFooter(); if (updateModal) updateModal.refresh(); });
  window.dwn.onCommand(onCommand);
  const minSplash = new Promise((r) => setTimeout(r, 1900));
  onEngine();
  await Promise.all([minSplash, new Promise((r) => { const t = setInterval(() => { if (S.engine.state === 'running') { clearInterval(t); r(); } }, 100); })]);
  await engineReady();
  $('#splash').classList.add('out');
  setTimeout(() => $('#splash').classList.add('hidden'), 500);
  if (!S.settings.onboarded) showWelcome(); else showApp();
})();

function onEngine() {
  const fail = $('.splash-fail');
  if (S.engine.state === 'failed') {
    $('.splash-line').classList.add('hidden');
    $('.splash-status').classList.add('hidden');
    $('#splash').classList.remove('hidden', 'out');
    mount(fail, h('div', {}, S.engine.message),
      h('div', { style: { display: 'flex', gap: '10px' } },
        h('button', { class: 'btn-quiet', onclick: () => invoke('engine:restart') }, 'Try Again'),
        h('button', { class: 'btn-quiet', onclick: () => invoke('engine:log') }, 'Show Engine Log')));
    fail.classList.remove('hidden');
  } else {
    fail.classList.add('hidden');
    $('.splash-line').classList.remove('hidden');
    $('.splash-status').classList.remove('hidden');
    if (S.engine.state === 'running' && S.started) engineReady();
  }
}

async function engineReady() {
  try { S.health = await api('health'); } catch {}
  try { S.prefs = await api('prefs'); } catch {}
  S.browsers = await invoke('browsers');
  refreshFree();
  await refreshHistory();
  if (!S.started) { S.started = true; poll(); }
}

function showApp() {
  $('#welcome').classList.add('hidden');
  $('#app').classList.remove('hidden');
  buildComposer();
  renderFooter();
  renderTop();
  renderList();
  installDrop();
  addEventListener('focus', checkClipboard);
  checkClipboard();
  mount($('#section-tabs'), tabs([['links', 'Links', 'down'], ['cloud', 'Cloud', 'cloud']], S.settings.section === 'cloud' ? 'cloud' : 'links', setSection, 30));
  showSection(S.settings.section === 'cloud' ? 'cloud' : 'links');
  cloudInit();
}

// "Links | Cloud" at the top of the left column. The content swaps instantly;
// only the tab pill slides.
function setSection(sec) {
  S.settings.section = sec;
  setSettings({ section: sec });
  showSection(sec);
}
function showSection(sec) {
  const cloud = sec === 'cloud';
  for (const id of ['#sidebar', '#content']) $(id).classList.toggle('hidden', cloud);
  for (const id of ['#cloud-sidebar', '#cloud-content']) $(id).classList.toggle('hidden', !cloud);
  if (cloud) cloudActivate();
}

// A link download or a cloud download finished: play the sound, and when
// Dwn isn't in front, show the "Download complete" panel (or a notification).
let soundTimer = null;
let doneAudio = null;
function playDoneSound() {
  if (S.settings.doneSound === false) return;
  clearTimeout(soundTimer);
  // Several finishing together chime once.
  soundTimer = setTimeout(() => {
    try {
      if (!doneAudio) { doneAudio = new Audio('sounds/done.wav'); doneAudio.volume = 0.7; }
      doneAudio.currentTime = 0;
      doneAudio.play().catch(() => {});
    } catch {}
  }, 60);
}
function downloadFinished(item) {
  if (item.direction !== 'up') playDoneSound();
  invoke('download:finished', item);
}

// ============================================================ engine data

async function poll() {
  for (;;) {
    await refreshJobs();
    const busy = S.jobs.some(isActive);
    await new Promise((r) => setTimeout(r, busy ? 500 : 2000));
  }
}
const isActive = (j) => ['queued', 'running', 'converting'].includes(j.state);

async function refreshJobs() {
  if (S.engine.state !== 'running') return;
  let list;
  try { list = await api('jobs'); } catch { return; }
  const before = JSON.stringify(S.jobs);
  S.jobs = list;
  let newlyDone = false;
  for (const j of list) {
    if (j.state === 'done' && !S.doneSeen.has(j.id)) {
      S.doneSeen.add(j.id);
      newlyDone = true;
      downloadFinished({ title: j.title, file: j.file, thumbnail: j.thumbnail });
      api(`jobs/${j.id}/dismiss`, {}).catch(() => {});
    }
  }
  if (!S.signinPrompted && list.some((j) => j.error_code === 'signin' && j.state === 'failed')) {
    S.signinPrompted = true;
    openSignIn();
  }
  if (newlyDone) { await refreshHistory(); refreshFree(); }
  if (JSON.stringify(S.jobs) !== before && !$('#app').classList.contains('hidden')) renderList();
}

async function refreshHistory() {
  try { S.history = await api('history'); S.historyLoaded = true; } catch {}
  if (!$('#app').classList.contains('hidden')) renderList();
}

async function refreshFree() {
  S.free = await invoke('fs:free', S.prefs.folder);
  renderFooter();
}

let prefsTimer = null;
function setPrefs(patch) {
  Object.assign(S.prefs, patch);
  clearTimeout(prefsTimer);
  prefsTimer = setTimeout(() => api('prefs', patch).catch((e) => toast(`Couldn't save your settings. ${e.message}`, true)), 250);
  if ('folder' in patch) refreshFree();
}
async function setSettings(patch) {
  const r = await invoke('settings:set', patch);
  S.settings = r.settings;
  return r;
}

async function download(url, opts = {}) {
  const kind = opts.kind || (S.settings.tab === 'audio' ? 'audio' : 'video');
  const body = { url, kind, mode: opts.mode || 'normal', format: kind === 'video' ? S.prefs.video_format : S.prefs.audio_format };
  if (opts.info && opts.info.title) body.title = opts.info.title;
  if (opts.info && opts.info.thumbnail) body.thumbnail = opts.info.thumbnail;
  if (opts.start != null) body.start = opts.start;
  if (opts.end != null) body.end = opts.end;
  try {
    await api('download', body);
    await refreshJobs();
    renderList();
    return true;
  } catch (e) { toast(e.message, true); return false; }
}

async function saveTranscript(url) {
  toast('Looking for captions');
  try {
    const r = await api('transcript', { url });
    await refreshHistory();
    toast(`Transcript saved: ${r.file.split(/[\\/]/).pop()}`);
  } catch (e) { toast(e.message, true); }
}

// ============================================================ composer

const C = {};
function buildComposer() {
  C.input = h('input', { placeholder: 'Paste a link', spellcheck: false,
    oninput: () => onLinkChange(), onkeydown: (e) => { if (e.key === 'Enter') start(); } });
  C.trail = h('span');
  C.field = h('label', { class: 'field' }, icon('link'), C.input, C.trail);
  C.copied = h('div');
  C.preview = h('div');
  C.format = h('div', { class: 'section' });
  C.quality = h('div');
  C.options = h('div');
  C.actions = h('div');
  mount($('#composer'), C.field, C.copied, C.preview, C.format, C.quality, C.options, C.actions);
  renderTrail(); renderFormat(); renderQuality(); renderOptions(); renderActions();
  mount($('#bulk-card'), h('span', { class: 'ic' }, icon('stack')),
    h('span', {}, h('b', {}, 'Bulk download'), h('span', {}, 'Download several links at once')),
    h('kbd', {}, IS_MAC() ? '⌘B' : 'Ctrl+B'));
  $('#bulk-card').onclick = () => openBulk();
}

const link = () => C.input.value.trim();
const valid = () => looksLikeLink(link());

function renderTrail() {
  mount(C.trail, C.input.value
    ? h('button', { class: 'btn-icon', title: 'Clear', onclick: () => { C.input.value = ''; onLinkChange(); C.input.focus(); } }, icon('xc'))
    : h('button', { class: 'btn-quiet', style: { height: '28px' }, onclick: pasteLink }, icon('clipboard', 'sm'), 'Paste'));
}
async function pasteLink() {
  C.input.value = (await invoke('clipboard:read')).trim();
  onLinkChange();
}
async function checkClipboard() {
  if (!C.input) return;
  const t = (await invoke('clipboard:read')).trim();
  S.clip = looksLikeLink(t) ? t : '';
  renderCopied();
}
function renderCopied() {
  if (!S.clip || link()) return mount(C.copied);
  mount(C.copied, h('button', { class: 'copied', onclick: () => { C.input.value = S.clip; onLinkChange(); } },
    icon('arrowr', 'sm'), h('b', {}, 'Use copied link'), h('span', {}, S.clip.replace(/^https?:\/\/(www\.)?/, ''))));
}

let lookupSeq = 0;
function onLinkChange() {
  renderTrail(); renderCopied();
  if (S.section && S.section.url !== normalizeLink(link())) S.section = null;
  const seq = ++lookupSeq;
  S.info = null; S.lookupError = null; S.looking = false;
  if (!valid()) { renderPreview(); renderActions(); return; }
  const target = normalizeLink(link());
  const q = quickInfo(target);
  if (q) {
    S.info = q;
    invoke('oembed', target).then((o) => {
      if (o && seq === lookupSeq && S.info && !S.info.title) { S.info.title = o.title; S.info.uploader = o.author; renderPreview(); }
    });
  }
  S.looking = true;
  renderPreview(); renderActions();
  setTimeout(async () => {
    if (seq !== lookupSeq) return;
    try {
      const full = await api('info', { url: target });
      if (seq !== lookupSeq) return;
      if (S.info && S.info.thumbnail && !full.is_playlist) full.thumbnail = S.info.thumbnail;
      S.info = full;
    } catch (e) {
      if (seq !== lookupSeq) return;
      if (!q) S.lookupError = e.message;
    }
    S.looking = false;
    renderPreview(); renderActions();
  }, q ? 0 : 200);
}

function renderPreview() {
  const l = link();
  if (l && !valid()) return mount(C.preview, h('div', { class: 'warn' }, 'That doesn\'t look like a link. Paste the full address, like https://…'));
  if (S.looking && !S.info) {
    return mount(C.preview, h('div', { class: 'linkcard' }, h('div', { class: 'thumb shimmer', style: { width: '92px', height: '52px' } }),
      h('div', { class: 'meta' }, h('div', { class: 'bar shimmer' }), h('div', { class: 'bar shimmer', style: { width: '110px', height: '7px' } }))));
  }
  if (S.lookupError) {
    return mount(C.preview, h('div', { class: 'warn', style: { color: 'var(--text2)' } },
      'Couldn\'t read that link. You can still try downloading it. ', h('span', { class: 'faint' }, S.lookupError)));
  }
  if (!S.info) return mount(C.preview);
  const i = S.info;
  const site = SITE_NAMES[i.site] || i.site;
  const sub = [i.uploader, site, i.is_playlist ? `${i.count || 0} items` : null].filter(Boolean).join(' · ');
  const pills = [];
  if (S.settings.tab !== 'transcript' && !i.is_playlist) {
    if (S.section) {
      pills.push(h('span', { class: 'pillbtn lime' },
        h('button', { onclick: () => openSection(i), title: 'Edit the section' }, icon('scissors'), ` ${fmtTime(S.section.start)}–${fmtTime(S.section.end)}`),
        h('button', { onclick: () => { S.section = null; renderPreview(); renderActions(); }, title: 'Download the whole video instead' }, icon('x'))));
    } else {
      pills.push(h('button', { class: 'pillbtn', onclick: () => openSection(i), title: 'Download just part of the video' }, icon('scissors'), 'Section'));
    }
    pills.push(h('button', { class: 'pillbtn', title: 'Find this song\'s instrumental on YouTube and download it',
      onclick: () => download(normalizeLink(link()), { info: i, kind: 'audio', mode: 'instrumental' }) }, icon('music'), 'Instrumental'));
  }
  mount(C.preview, h('div', { class: 'linkcard' },
    thumb(i.thumbnail, 92, 52, i.duration && !i.is_playlist ? h('span', { class: 'dur' }, fmtTime(i.duration)) : null),
    h('div', { class: 'meta' },
      i.title ? h('div', { class: 'title' }, i.title) : h('div', { class: 'bar shimmer', style: { margin: '3px 0' } }),
      sub ? h('div', { class: 'sub' }, sub) : null,
      pills.length ? h('div', { class: 'pills' }, pills) : null)));
}

function renderFormat() {
  mount(C.format, h('div', { class: 'label' }, 'Format'),
    tabs([['video', 'Video', 'film'], ['audio', 'Audio', 'wave'], ['transcript', 'Transcript', 'text']], S.settings.tab || 'video', (t) => {
      setSettings({ tab: t });
      if (t !== 'transcript') setPrefs({ kind: t });
      S.settings.tab = t;
      renderQuality(); renderOptions(); renderActions(); renderPreview();
    }, 42));
}

function renderQuality() {
  const tab = S.settings.tab || 'video';
  if (tab === 'video') {
    return mount(C.quality, h('div', { class: 'section' }, h('div', { class: 'label' }, 'Quality'),
      select(FORMATS.heights.map(([v, n]) => [v, n, CODEC_SHORT[S.prefs.video_format] || '']), S.prefs.max_height || 0,
        (v) => { setPrefs({ max_height: Number(v) }); renderQuality(); }, { iconName: 'aspect', height: 42 })));
  }
  if (tab === 'audio') {
    return mount(C.quality, h('div', { class: 'section' }, h('div', { class: 'label' }, 'Audio format'),
      select(FORMATS.audio.map(([id, n]) => [id, n]), S.prefs.audio_format || 'mp3',
        (v) => { setPrefs({ audio_format: v }); renderQuality(); }, { iconName: 'music', height: 42 })));
  }
  mount(C.quality, h('div', { class: 'fill', style: { display: 'flex', gap: '10px', padding: '12px 14px', color: 'var(--text2)' } },
    icon('captions'), 'Saves the video\'s captions as a text file, with the same name as the video.'));
}

function renderOptions() {
  if ((S.settings.tab || 'video') === 'transcript') return mount(C.options);
  const open = S.settings.optionsOpen !== false;
  const head = h('button', { class: `options-head${open ? '' : ' closed'}`, onclick: () => {
    setSettings({ optionsOpen: !open }); S.settings.optionsOpen = !open; renderOptions();
  } }, h('span', { class: 'label', style: { flex: 1, textAlign: 'left' } }, 'Options'), icon('chev', 'sm'));
  const rows = [];
  if (open) {
    rows.push(optionRow('image', 'Embed cover art', S.prefs.embed_thumbnail !== false, (v) => setPrefs({ embed_thumbnail: v })));
    rows.push(optionRow('tag', 'Embed metadata', S.prefs.embed_metadata !== false, (v) => setPrefs({ embed_metadata: v })));
    if (S.settings.tab !== 'audio') {
      rows.push(optionRow('captions', 'Embed subtitles', !!S.prefs.embed_subs, (v) => setPrefs({ embed_subs: v })));
      rows.push(optionRow('layers', 'ProRes for editing', S.prefs.video_format === 'prores', (v) => {
        if (v) { localStorage.codecBefore = S.prefs.video_format; setPrefs({ video_format: 'prores' }); }
        else setPrefs({ video_format: (localStorage.codecBefore && localStorage.codecBefore !== 'prores') ? localStorage.codecBefore : 'h264' });
        renderQuality();
      }));
    }
    const b = S.browsers.find((x) => x.id === S.prefs.browser_cookies) || S.browsers[0];
    rows.push(optionRow('key', `Use ${b ? b.name : 'browser'} logins`, !!S.prefs.browser_cookies, (v) => {
      if (v) openSignIn(); else { setPrefs({ browser_cookies: '' }); renderOptions(); }
    }));
  }
  mount(C.options, h('div', { class: 'section', style: { gap: '11px' } }, head, open ? h('div', { class: 'options' }, rows) : null));
}

function renderActions() {
  const tab = S.settings.tab || 'video';
  let label = 'Download';
  if (tab === 'transcript') label = 'Save transcript';
  else if (S.section) label = 'Download section';
  else if (S.info && S.info.is_playlist) label = `Download all ${S.info.count || 0}`;
  mount(C.actions, h('button', { class: 'btn-primary', disabled: !valid(), onclick: start },
    icon(tab === 'transcript' ? 'text' : 'down'), label));
}

async function start() {
  if (!valid()) return;
  const url = normalizeLink(link());
  const tab = S.settings.tab || 'video';
  if (tab === 'transcript') return saveTranscript(url);
  if (S.info && S.info.is_playlist) return openBulk(url);
  if (S.info && ['is_live', 'is_upcoming'].includes(S.info.live_status)) return toast('This stream is live. Download it once it has ended.', true);
  const cut = S.section;
  if (await download(url, { info: S.info, kind: tab, start: cut && cut.start, end: cut && cut.end })) {
    C.input.value = ''; S.section = null; onLinkChange();
  }
}

function openSection(info) {
  openSectionEditor(info, {
    tab: () => S.settings.tab, prefs: () => S.prefs, section: S.section,
    onDone: (sec) => { S.section = sec; renderPreview(); renderActions(); },
    onDownload: async (kind, s, e) => {
      S.section = null;
      if (await download(info.url, { info, kind, start: s, end: e })) {
        toast(s != null ? `Downloading section ${fmtTime(s)}–${fmtTime(e)}` : 'Download started.');
        if (normalizeLink(link()) === info.url) { C.input.value = ''; onLinkChange(); }
      }
    },
  });
}

// ============================================================ footer, top bar

function renderFooter() {
  if ($('#app').classList.contains('hidden')) return;
  mount($('#footer'), footerKids());
  mount($('#cloud-footer'), footerKids());
}

function footerKids() {
  const u = S.update || {};
  let pill = null;
  if (u.phase === 'available' || u.phase === 'downloading' || u.phase === 'ready') {
    const text = u.phase === 'downloading' ? `Updating… ${Math.round((u.progress || 0) * 100)}%`
      : u.phase === 'ready' ? 'Restart to update' : `Update to ${u.version}`;
    pill = h('button', { class: 'update-pill', onclick: openUpdate }, icon('down', 'sm'), text);
  }
  const folder = (S.prefs.folder || '').replace(/^\/Users\/[^/]+|^C:\\Users\\[^\\]+/i, '~');
  return [
    h('button', { class: 'row', title: 'Change where files are saved', onclick: chooseFolder }, icon('folder'), h('span', {}, 'Saving to'), h('span', { class: 'path' }, folder)),
    h('div', { class: 'row' }, icon('drive'), [S.free != null ? `${fmtBytes(S.free)} free` : null, S.health ? `yt-dlp ${S.health.ytdlp}` : null].filter(Boolean).join(' · ')),
    h('div', { class: 'row', style: { marginTop: '2px' } }, wordmark(12, true), h('span', {}, `v${S.version}`), pill)];
}

async function chooseFolder() {
  const p = await invoke('dialog:folder', S.prefs.folder);
  if (p) { setPrefs({ folder: p }); renderFooter(); }
}

function renderTop() {
  const input = h('input', { placeholder: 'Search downloads', oninput: (e) => { S.query = e.target.value; renderList(); } });
  mount($('#search-box'), icon('search'), input);
  mount($('#top-actions'),
    h('button', { class: 'btn-icon filled lg', title: 'Open download folder', onclick: () => invoke('shell:folder', S.prefs.folder) }, icon('folder')),
    h('button', { class: 'btn-icon filled lg', title: 'Settings', onclick: () => openSettings() }, icon('gear')));
}

// ============================================================ downloads list

function renderList() {
  const list = $('#list');
  const visible = S.jobs.filter((j) => isActive(j) || j.state === 'failed' || j.state === 'cancelled');
  $('#search-box').style.visibility = S.history.length || visible.length ? 'visible' : 'hidden';
  if (!S.historyLoaded) return mount(list);
  if (!visible.length && !S.history.length) {
    return mount(list, h('div', { class: 'empty' },
      h('div', { class: 'logomark' }, arrowSVG('')),
      h('div', {}, h('h3', {}, 'Nothing downloaded yet'), h('p', {}, 'Paste a link on the left, or drop one', h('br'), 'anywhere in the window.')),
      h('div', { class: 'keys' }, shortcutKeys().map((k) => h('kbd', { class: 'cap' }, k)),
        S.settings.shortcutAction === 'instant' ? 'downloads the copied link from any app' : 'opens quick download from any app')));
  }
  const kids = [];
  if (S.jobs.some((j) => j.error_code === 'signin' && j.state === 'failed')) {
    kids.push(h('div', { class: 'banner' }, icon('user'),
      h('div', { style: { flex: 1 } }, h('b', {}, 'YouTube wants to check you\'re a real person'),
        h('span', {}, 'Sign in with your browser and Dwn will retry those downloads.')),
      h('button', { class: 'btn-primary', style: { width: '96px', height: '34px' }, onclick: openSignIn }, 'Sign in')));
  }
  if (visible.length) {
    const running = S.jobs.filter(isActive).length;
    kids.push(h('div', { class: 'sec-head' }, 'In progress',
      running > 1 ? h('button', { class: 'btn-link', onclick: () => { if (confirm(`Stop ${running} downloads?`)) api('jobs/cancel-all', {}).then(refreshJobs); } }, 'Stop all') : null));
    for (const j of visible) kids.push(jobCard(j));
  }
  const q = S.query.trim().toLowerCase();
  const words = q.split(/\s+/).filter(Boolean);
  const hist = S.history.filter((x) => !words.length || words.every((w) => `${x.title || ''} ${x.url} ${formatName(x.format)}`.toLowerCase().includes(w)));
  if (S.history.length) {
    kids.push(h('div', { class: 'sec-head', style: { marginTop: visible.length ? '14px' : 0 } }, q ? `${hist.length} matching` : 'Downloads'));
    if (!hist.length) kids.push(h('div', { class: 'faint', style: { padding: '30px', textAlign: 'center' } }, `Nothing matches “${S.query}”`));
    for (const x of hist.slice(0, 400)) kids.push(historyRow(x));
  }
  const top = list.scrollTop;
  mount(list, kids);
  list.scrollTop = top;
}

function jobCard(j) {
  let body;
  if (j.state === 'failed') body = h('div', { class: 'err' }, j.error || 'Couldn\'t download');
  else if (j.state === 'cancelled') body = h('div', { class: 'faint' }, 'Stopped');
  else {
    let badge = formatName(j.format);
    if (j.mode === 'instrumental') badge = `Instrumental · ${badge}`;
    if (j.start != null || j.end != null) badge += ` · ${fmtTime(j.start || 0)}–${fmtTime(j.end)}`;
    body = [progress(j.progress, j.state === 'queued' || (j.progress <= 0 && j.state !== 'converting')),
      h('div', { class: 'line' }, h('span', {}, j.stage),
        j.speed && j.state === 'running' ? h('span', {}, `· ${fmtBytes(j.speed)}/s`) : null,
        j.eta && j.state === 'running' ? h('span', {}, `· ${fmtTime(j.eta)} left`) : null,
        h('span', { class: 'r' }, badge))];
  }
  const acts = isActive(j)
    ? [h('button', { class: 'btn-icon', title: 'Stop downloading', onclick: () => api(`jobs/${j.id}/cancel`, {}).then(refreshJobs) }, icon('x'))]
    : [j.error_code === 'signin' ? h('button', { class: 'btn-quiet', style: { height: '30px' }, onclick: openSignIn }, 'Sign in') : null,
      h('button', { class: 'btn-icon', title: 'Try again', onclick: () => api(`jobs/${j.id}/retry`, {}).then(refreshJobs) }, icon('refresh')),
      h('button', { class: 'btn-icon', title: 'Remove from list', onclick: () => api(`jobs/${j.id}/dismiss`, {}).then(refreshJobs) }, icon('x'))];
  return h('div', { class: 'card job' }, thumb(j.thumbnail, 96, 54),
    h('div', { class: 'meta' }, h('div', { class: 'title' }, j.title), body), h('div', { class: 'acts' }, acts));
}

function historyRow(x) {
  const gone = x.exists === false;
  const sub = [h('span', { class: 'badge' }, formatName(x.format))];
  if (x.start != null || x.end != null) sub.push(h('span', {}, `Section ${fmtTime(x.start || 0)}–${fmtTime(x.end)}`));
  if (x.finished) sub.push(h('span', {}, relTime(x.finished)));
  if (gone) sub.push(h('span', { style: { color: 'var(--warn)' } }, '· File moved or deleted'));
  const open = () => invoke('shell:open', x.file).then((r) => r && r.error && toast(r.error, true));
  const reveal = () => invoke('shell:reveal', x.file).then((r) => r && r.error && toast(r.error, true));
  const row = h('div', { class: `row-h${gone ? ' gone' : ''}`, ondblclick: open },
    thumb(x.thumbnail, 80, 45, x.kind === 'audio' ? h('span', { class: 'dur', style: { left: '3px', right: 'auto' } }, '♪') : null),
    h('div', { class: 'meta' }, h('div', { class: 'title' }, x.title || x.url), h('div', { class: 'sub' }, sub)),
    gone ? null : h('div', { class: 'acts' },
      h('button', { class: 'btn-icon', title: 'Open', onclick: open }, icon('play', 'sm')),
      h('button', { class: 'btn-icon', title: IS_MAC() ? 'Show in Finder' : 'Show in folder', onclick: reveal }, icon('search'))));
  row.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    popupMenu(e.clientX, e.clientY, [
      { label: 'Open', run: open },
      { label: IS_MAC() ? 'Show in Finder' : 'Show in folder', run: reveal },
      { label: 'Copy link', run: () => invoke('clipboard:write', x.url) },
      { label: 'Download again', run: () => download(x.url) },
      '-',
      { label: 'Remove from list', run: () => api('history/forget', { ids: [x.id] }).then(refreshHistory) },
      { label: IS_MAC() ? 'Move to Trash' : 'Move to Recycle Bin', danger: true, run: async () => {
        const r = await invoke('shell:trash', x.file);
        if (r && r.error) toast(r.error, true); else api('history/forget', { ids: [x.id] }).then(refreshHistory);
      } },
    ]);
  });
  return row;
}

// ============================================================ commands, drop, keys

function onCommand(c) {
  if (c === 'bulk') openBulk();
  else if (c && c.bulk) openBulk(c.bulk);
  else if (c === 'settings') openSettings();
  else if (c === 'update') openUpdate();
  else if (c === 'open-folder') invoke('shell:folder', S.prefs.folder);
  else if (c && c.section) openSection(c.section);
  else if (c && c.signin) openSignIn();
}

addEventListener('keydown', (e) => {
  const mod = IS_MAC() ? e.metaKey : e.ctrlKey;
  if (mod && e.key.toLowerCase() === 'b') { e.preventDefault(); openBulk(); }
  if (mod && e.shiftKey && e.key.toLowerCase() === 'v' && C.input) { e.preventDefault(); pasteLink(); }
  if (mod && e.key === ',') { e.preventDefault(); openSettings(); }
});

function installDrop() {
  const drop = $('#drop');
  mount($('.drop-inner'), arrowSVG(''), 'Drop to download');
  let depth = 0;
  const inCloud = () => S.settings.section === 'cloud';
  addEventListener('dragenter', (e) => { e.preventDefault(); if (inCloud()) return; depth++; drop.classList.remove('hidden'); });
  addEventListener('dragleave', () => { if (inCloud()) return; if (--depth <= 0) { depth = 0; drop.classList.add('hidden'); } });
  addEventListener('dragover', (e) => e.preventDefault());
  addEventListener('drop', async (e) => {
    e.preventDefault(); depth = 0; drop.classList.add('hidden');
    if (inCloud()) return;
    const dt = e.dataTransfer;
    if (dt.files && dt.files.length) {
      const f = dt.files[0];
      if (f.size > 5_000_000) return toast('That file is too big. 5 MB max.', true);
      return openBulk(await f.text());
    }
    const text = dt.getData('text/uri-list') || dt.getData('text/plain') || '';
    const links = text.split(/\s+/).filter(looksLikeLink);
    if (links.length > 1) openBulk(links.join('\n'));
    else if (links.length) { C.input.value = links[0]; onLinkChange(); }
  });
}

// ============================================================ bulk

function openBulk(prefill = '') {
  let items = []; let skipped = []; const chosen = new Set();
  let reviewing = false; let busy = false; let kind = S.settings.tab === 'audio' ? 'audio' : 'video'; let skipExisting = true;
  const area = h('textarea', { class: 'textarea', style: { flex: 1 }, placeholder: 'Links, one per line', spellcheck: false });
  area.value = prefill;
  const err = h('div', { class: 'warn' });
  const body = h('div', { style: { flex: 1, display: 'flex', flexDirection: 'column', gap: '10px', minHeight: 0 } });
  const footer = h('div', { style: { display: 'flex', gap: '10px', justifyContent: 'flex-end' } });
  const back = h('button', { class: 'btn-link' }, 'Back');
  const box = h('div', { class: 'bulk' },
    h('div', { style: { display: 'flex', alignItems: 'center' } }, h('h2', { style: { flex: 1 } }, 'Bulk download'), back),
    body, err, footer);
  const m = modal(box, { width: 640 });
  const selected = () => items.filter((it) => chosen.has(it.url + it.title) && !it.error && !(skipExisting && it.downloaded));

  function render() {
    back.classList.toggle('hidden', !reviewing);
    back.onclick = () => { reviewing = false; render(); };
    if (!reviewing) {
      mount(body, h('div', { class: 'muted' }, 'Paste links, one per line. Playlists, albums and channels expand on their own.'), area,
        h('div', { style: { display: 'flex', gap: '8px' } },
          h('button', { class: 'btn-quiet', onclick: async () => { area.value += (area.value ? '\n' : '') + await invoke('clipboard:read'); } }, 'Paste from clipboard'),
          h('button', { class: 'btn-quiet', onclick: async () => {
            const r = await invoke('dialog:textfile');
            if (r && r.error) err.textContent = r.error; else if (r) area.value += (area.value ? '\n' : '') + r.text;
          } }, 'Add a text or CSV file…')));
      mount(footer, h('button', { class: 'btn-quiet', onclick: m.close }, 'Cancel'),
        h('button', { class: 'btn-primary', style: { width: '120px', height: '36px' }, disabled: busy, onclick: review }, busy ? 'Reading…' : 'Review'));
      setTimeout(() => area.focus(), 50);
    } else {
      const list = h('div', { class: 'items' }, items.map((it) => {
        const id = it.url + it.title;
        const c = h('span', { class: `check${chosen.has(id) ? ' on' : ''}` }, chosen.has(id) ? icon('check') : null);
        return h('div', { class: 'item', onclick: () => { if (it.error) return; chosen.has(id) ? chosen.delete(id) : chosen.add(id); render(); } },
          c, thumb(it.thumbnail, 48, 27),
          h('div', { class: 't' }, h('b', {}, it.title || it.url),
            h('span', {}, [it.playlist, it.duration ? fmtTime(it.duration) : null, it.downloaded ? 'Already downloaded' : null].filter(Boolean).join(' · '),
              it.error ? h('span', { style: { color: 'var(--warn)' } }, ` ${it.error}`) : null)));
      }));
      mount(body,
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '12px' } },
          h('div', { style: { width: '300px' } }, tabs([['video', `Video · ${CODEC_SHORT[S.prefs.video_format] || ''}`, 'film'], ['audio', `Audio · ${formatName(S.prefs.audio_format)}`, 'wave']], kind, (k) => { kind = k; })),
          h('div', { style: { flex: 1 } }),
          h('button', { class: 'option', style: { width: 'auto' }, onclick: () => { skipExisting = !skipExisting; render(); } },
            h('span', { class: 't' }, 'Skip links already downloaded'), h('span', { class: `switch${skipExisting ? ' on' : ''}` }))),
        list,
        skipped.length ? h('div', { class: 'note' }, `Skipped ${skipped.length} line${skipped.length > 1 ? 's' : ''} with no link.`) : null);
      mount(footer, h('button', { class: 'btn-quiet', onclick: m.close }, 'Cancel'),
        h('button', { class: 'btn-primary', style: { width: '220px', height: '36px' }, disabled: !selected().length || busy, onclick: startAll },
          `Start downloading ${selected().length}`));
    }
  }
  async function review() {
    err.textContent = ''; busy = true; render();
    try {
      const r = await api('bulk/expand', { text: area.value, limit: 500 });
      busy = false;
      if (!r.items.length) { err.textContent = 'Nothing to download. Check the list and try again.'; return render(); }
      items = r.items; skipped = r.skipped; chosen.clear();
      items.filter((it) => !it.error).forEach((it) => chosen.add(it.url + it.title));
      reviewing = true;
    } catch (e) { busy = false; err.textContent = e.message; }
    render();
  }
  async function startAll() {
    busy = true; render();
    try {
      const r = await api('bulk/start', { kind, format: kind === 'video' ? S.prefs.video_format : S.prefs.audio_format,
        items: selected().map((it) => ({ url: it.url, title: it.title || '', thumbnail: it.thumbnail || '' })) });
      await refreshJobs();
      toast(`Queued ${r.queued.length} downloads`);
      m.close();
    } catch (e) { busy = false; err.textContent = e.message; render(); }
  }
  render();
}

// ============================================================ sign-in

function signInPanel(onDone) {
  const wrap = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '10px' } });
  let checking = null; let result = null; let checked = null;
  function render() {
    const rows = S.browsers.length ? S.browsers.map((b) => {
      const active = S.prefs.browser_cookies === b.id;
      return h('button', { class: `browser-row${active ? ' active' : ''}`, disabled: !!checking, onclick: () => check(b) },
        h('span', { class: 'browser-badge' }, b.name[0]),
        h('span', { class: 't' }, h('b', {}, `Sign in with ${b.name}`), h('span', {}, active ? 'In use for YouTube downloads' : `Uses your YouTube login from ${b.name}`)),
        checking === b.id ? h('span', { class: 'faint' }, 'Checking…') : active ? icon('check') : icon('right', 'sm'));
    }) : [h('div', { class: 'card', style: { padding: '14px', color: 'var(--text2)' } }, 'Needs Firefox, Chrome, Edge or Brave. Install one and sign in to YouTube there, then come back.')];
    let res = null;
    if (checking) res = h('div', { class: 'note' }, S.platform === 'darwin' ? 'Your Mac may ask for its password. Choose Always Allow.' : 'Reading your browser\'s login…');
    else if (result && checked) {
      const b = S.browsers.find((x) => x.id === checked);
      if (result.ok && result.signed_in) res = h('div', { class: 'signin-result ok' }, `Found your YouTube login in ${b.name}. Downloads that YouTube blocks will now work.`);
      else if (result.ok) res = h('div', { class: 'signin-result bad' }, `${b.name} isn't signed in to YouTube.`,
        h('div', { style: { display: 'flex', gap: '8px' } },
          h('button', { class: 'btn-quiet', style: { height: '32px' }, onclick: () => invoke('browser:open', b.id, 'https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/') }, `Sign in to YouTube in ${b.name}`),
          h('button', { class: 'btn-quiet', style: { height: '32px' }, onclick: () => check(b) }, 'Check again')));
      else res = h('div', { class: 'signin-result bad' }, result.message || 'Couldn\'t read that browser\'s login.',
        h('div', {}, h('button', { class: 'btn-quiet', style: { height: '32px' }, onclick: () => check(b) }, 'Try again')));
    }
    const tip = S.platform === 'win32' ? h('div', { class: 'note' }, 'On Windows, Chrome and Edge lock their logins while open. Firefox works best.') : null;
    mount(wrap, rows, res, tip, h('div', { class: 'note' }, 'Your login stays on this computer and is sent only to YouTube. Dwn has no servers.'));
  }
  async function check(b) {
    checking = b.id; result = null; render();
    try { result = await api('cookies/test', { browser: b.id }); } catch (e) { result = { ok: false, message: e.message }; }
    checking = null; checked = b.id;
    if (result.ok) { setPrefs({ browser_cookies: b.id }); if (C.options) renderOptions(); }
    render();
    if (result.ok && result.signed_in && onDone) onDone();
  }
  render();
  return wrap;
}

function openSignIn() {
  let m;
  const retry = () => S.jobs.filter((j) => j.error_code === 'signin' && j.state === 'failed').forEach((j) => api(`jobs/${j.id}/retry`, {}));
  const box = h('div', { style: { padding: '24px', display: 'flex', flexDirection: 'column', gap: '18px' } },
    h('div', {}, h('h2', {}, 'Sign in to YouTube'),
      h('p', { class: 'muted', style: { marginTop: '6px' } }, 'Every so often, YouTube blocks downloads until it\'s sure a real person is behind them. Signing in with the account you already use in your browser fixes it.')),
    signInPanel(() => { retry(); setTimeout(() => m.close(), 1200); }),
    h('div', { style: { display: 'flex', gap: '10px', justifyContent: 'flex-end' } },
      h('button', { class: 'btn-quiet', onclick: () => m.close() }, 'Not now'),
      h('button', { class: 'btn-primary', style: { width: '150px', height: '36px' }, onclick: () => { retry(); m.close(); } }, 'Retry downloads')));
  m = modal(box, { width: 500 });
}

// ============================================================ updates

let updateModal = null;
function openUpdate() {
  const box = h('div', { style: { padding: '22px', display: 'flex', flexDirection: 'column', gap: '16px' } });
  function refresh() {
    const u = S.update;
    const busy = u.phase === 'downloading';
    let status = null;
    if (busy) status = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '6px' } }, progress(u.progress), h('span', { class: 'note' }, `Downloading the update… ${Math.round((u.progress || 0) * 100)}%`));
    else if (u.phase === 'ready') status = h('div', { class: 'note', style: { color: 'var(--accent)' } }, 'Downloaded and ready to install.');
    else if (u.phase === 'failed') status = h('div', { class: 'warn' }, u.error);
    mount(box,
      h('div', { style: { display: 'flex', gap: '14px', alignItems: 'center' } }, h('div', { class: 'logomark', style: { width: '48px', height: '48px', borderRadius: '14px' } }, arrowSVG('')),
        h('div', {}, h('h2', {}, `Dwn ${u.version || ''} is available`), h('div', { class: 'faint' }, `You have ${S.version}.`))),
      u.notes ? h('div', { class: 'fill', style: { padding: '12px', maxHeight: '220px', overflow: 'auto', whiteSpace: 'pre-wrap', color: 'var(--text2)', userSelect: 'text' } }, u.notes) : null,
      status,
      h('div', { style: { display: 'flex', gap: '10px', alignItems: 'center' } },
        u.page ? h('button', { class: 'btn-link', onclick: () => invoke('shell:external', u.page) }, 'Release page') : null,
        h('div', { style: { flex: 1 } }),
        h('button', { class: 'btn-quiet', onclick: () => updateModal.close() }, 'Later'),
        h('button', { class: 'btn-primary', style: { width: '200px', height: '36px' }, disabled: busy, onclick: () => invoke('update:install') },
          icon('down'), u.phase === 'ready' ? 'Restart to update' : u.canInstall ? 'Update and restart' : 'Get the update')));
  }
  updateModal = modal(box, { width: 480, onClose: () => { updateModal = null; } });
  updateModal.refresh = refresh;
  refresh();
}

// ============================================================ settings

function openSettings(page = 'general') {
  const nav = h('nav');
  const pane = h('div', { class: 'pane' });
  const pages = [['general', 'General', 'gear'], ['formats', 'Formats', 'film'], ['shortcut', 'Shortcut & tray', 'cmd'], ['engine', 'Engine', 'bolt'], ['updates', 'Updates', 'down']];
  function go(p) {
    page = p;
    mount(nav, pages.map(([id, t, ic]) => h('button', { class: id === p ? 'on' : '', onclick: () => go(id) }, icon(ic), t)));
    mount(pane, PAGES[p]());
  }
  const kv = (k, v) => h('div', { class: 'kv' }, h('span', {}, k), v);
  const PAGES = {
    general: () => [h('h3', {}, 'General'),
      h('div', { class: 'group' },
        kv('Save downloads to', h('button', { class: 'btn-quiet', onclick: async () => { await chooseFolder(); go('general'); } }, (S.prefs.folder || '').split(/[\\/]/).pop() || 'Choose…')),
        kv('Downloads at once', select([1, 2, 3, 4, 5, 6, 8].map((n) => [n, String(n)]), S.prefs.concurrency || 3, (v) => setPrefs({ concurrency: Number(v) })))),
      h('h3', {}, 'When a download finishes'),
      h('div', { class: 'group' },
        optionRow('bell', 'Play a sound when a download finishes', S.settings.doneSound !== false, (v) => { setSettings({ doneSound: v }); if (v) { S.settings.doneSound = true; playDoneSound(); } }),
        kv('Download-finished panel', select(DONE_PANEL_SPOTS, S.settings.donePanel || 'bottom-right', (v) => setSettings({ donePanel: v }).then(() => go('general'))))),
      h('div', { class: 'note' }, `When Dwn isn't in front, a small panel shows the finished file. Drag it straight into another app, or open it.${S.settings.donePanel === 'off' ? ' With the panel off, you get a notification instead.' : ''}`),
      h('h3', {}, 'YouTube sign-in'), signInPanel(),
      S.prefs.browser_cookies ? h('button', { class: 'btn-link', style: { alignSelf: 'flex-start' }, onclick: () => { setPrefs({ browser_cookies: '' }); renderOptions(); go('general'); } }, 'Stop using browser logins') : null,
      h('button', { class: 'btn-link', style: { alignSelf: 'flex-start' }, onclick: async () => { await setSettings({ onboarded: false }); location.reload(); } }, 'Show the welcome tour again')],
    formats: () => [h('h3', {}, 'Video'), radioList(FORMATS.video, S.prefs.video_format, (v) => { setPrefs({ video_format: v }); renderQuality(); renderOptions(); go('formats'); }),
      h('h3', {}, 'Audio'), radioList(FORMATS.audio, S.prefs.audio_format, (v) => { setPrefs({ audio_format: v }); renderQuality(); go('formats'); }),
      h('div', { class: 'group' },
        optionRow('image', 'Embed cover art', S.prefs.embed_thumbnail !== false, (v) => { setPrefs({ embed_thumbnail: v }); renderOptions(); }),
        optionRow('tag', 'Embed metadata', S.prefs.embed_metadata !== false, (v) => { setPrefs({ embed_metadata: v }); renderOptions(); }),
        optionRow('captions', 'Embed subtitles in videos', !!S.prefs.embed_subs, (v) => { setPrefs({ embed_subs: v }); renderOptions(); }))],
    shortcut: () => [h('h3', {}, 'Global shortcut'),
      h('div', { class: 'group' },
        optionRow('cmd', 'Use a global shortcut', S.settings.hotkeyEnabled !== false, (v) => setSettings({ hotkeyEnabled: v })),
        kv('Shortcut', shortcutRecorder()),
        kv('Pressing it', select([['panel', 'Opens the quick download panel'], ['instant', 'Downloads the copied link right away']], S.settings.shortcutAction, (v) => setSettings({ shortcutAction: v }))),
        kv('Quick panel appears', select([['top', 'Top right'], ['bottom', 'Bottom right']], S.settings.panelPosition, (v) => setSettings({ panelPosition: v })))),
      h('h3', {}, S.platform === 'darwin' ? 'Menu bar' : 'System tray'),
      h('div', { class: 'group' },
        optionRow('tray', S.platform === 'darwin' ? 'Show Dwn in the menu bar' : 'Show Dwn in the system tray', S.settings.trayEnabled !== false, (v) => setSettings({ trayEnabled: v }),
          'Click the icon for quick download. Closing the window keeps Dwn running there.'),
        optionRow('bolt', 'Open at login', !!S.settings.launchAtLogin, (v) => setSettings({ launchAtLogin: v }))),
      h('h3', {}, 'Browser'),
      h('div', { class: 'group' }, kv('Send to Dwn bookmarklet', h('button', { class: 'btn-quiet', onclick: () => {
        invoke('clipboard:write', "javascript:location.href='dwn://download?url='+encodeURIComponent(location.href)");
        toast('Copied. Make a new bookmark and paste it as the address.');
      } }, 'Copy code'))),
      h('div', { class: 'note' }, 'Click the bookmark on any video page to download that video.')],
    engine: () => [h('h3', {}, 'Engine'),
      h('div', { class: 'group' },
        kv('yt-dlp', h('span', { class: 'v' }, S.health ? S.health.ytdlp : '–')),
        kv('ffmpeg', h('span', { class: 'v' }, S.health && S.health.ffmpeg ? 'Installed' : 'Missing (conversions won\'t work)')),
        kv('YouTube helper', h('span', { class: 'v' }, S.health && S.health.js_runtime ? S.health.js_runtime : 'Missing (YouTube may fail)'))),
      h('div', { style: { display: 'flex', gap: '8px' } },
        h('button', { class: 'btn-quiet', onclick: async (e) => {
          e.target.textContent = 'Checking…';
          try { const r = await api('update-ytdlp', {}); toast(r.updated ? `Updated yt-dlp to ${r.version}.` : `Up to date. You have the newest yt-dlp (${r.version}).`); if (r.updated) invoke('engine:restart'); } catch (err) { toast(err.message, true); }
          go('engine');
        } }, 'Get the newest yt-dlp'),
        h('button', { class: 'btn-quiet', onclick: () => invoke('engine:restart') }, 'Restart engine'),
        h('button', { class: 'btn-quiet', onclick: () => invoke('engine:log') }, 'Show log')),
      h('div', { class: 'note' }, 'If a site stops working, update yt-dlp.')],
    updates: () => {
      const u = S.update;
      const status = { idle: 'Not checked yet', checking: 'Checking…', upToDate: 'Up to date', available: `Version ${u.version} is available`,
        downloading: `Downloading ${Math.round((u.progress || 0) * 100)}%`, ready: 'Ready to install', failed: u.error }[u.phase] || '';
      return [h('h3', {}, 'Updates'),
        h('div', { class: 'group' },
          kv('Version', h('span', { class: 'v' }, S.version)),
          kv('Status', h('span', { class: 'v', style: { color: u.phase === 'available' ? 'var(--accent)' : u.phase === 'failed' ? 'var(--warn)' : '' } }, status)),
          u.checkedAt ? kv('Last checked', h('span', { class: 'v' }, relTime(u.checkedAt / 1000))) : null),
        h('div', { style: { display: 'flex', gap: '8px' } },
          h('button', { class: 'btn-quiet', onclick: async () => { await invoke('update:check'); S.update = await invoke('update:state'); go('updates'); } }, 'Check for updates'),
          ['available', 'downloading', 'ready'].includes(u.phase) ? h('button', { class: 'btn-quiet', onclick: openUpdate }, `Update to ${u.version}`) : null),
        h('div', { class: 'group' },
          optionRow('refresh', 'Check for updates automatically', S.settings.autoCheckUpdates !== false, (v) => setSettings({ autoCheckUpdates: v }),
            'Dwn checks GitHub for new releases when it opens and every few hours.'),
          optionRow('down', 'Download and install updates automatically', S.settings.autoInstallUpdates !== false, (v) => setSettings({ autoInstallUpdates: v }),
            'New versions download in the background and install when you quit Dwn. Dwn always goes straight to the newest version.')),
        h('button', { class: 'btn-link', style: { alignSelf: 'flex-start' }, onclick: () => invoke('shell:external', `https://github.com/${u.repo}/releases`) }, 'All releases on GitHub')];
    },
  };
  modal(h('div', { class: 'settings' }, nav, pane), { width: 760 });
  go(page);
}

const DONE_PANEL_SPOTS = [['off', 'Off'], ['bottom-right', 'Bottom right'], ['top-right', 'Top right'], ['bottom-left', 'Bottom left'], ['top-left', 'Top left']];

function radioList(list, value, onPick) {
  return h('div', { class: 'radio-list card' }, list.map(([id, name, note]) =>
    h('button', { class: id === value ? 'on' : '', onclick: () => onPick(id) }, h('span', { class: 'dot' }), h('span', {}, h('b', {}, name), h('span', {}, note)))));
}

function shortcutRecorder() {
  const b = h('button', { class: 'recorder' });
  let recording = false;
  const show = () => mount(b, recording ? 'Press keys…' : shortcutKeys().map((k) => h('kbd', { class: 'cap' }, k)));
  b.onclick = () => {
    if (recording) return stop();
    recording = true; b.classList.add('rec'); show(); invoke('shortcut:pause');
    addEventListener('keydown', onKey, true);
  };
  async function onKey(e) {
    e.preventDefault(); e.stopPropagation();
    if (e.key === 'Escape') return stop();
    if (e.key === 'Backspace' || e.key === 'Delete') { await setSettings({ shortcut: S.platform === 'darwin' ? 'Alt+Command+D' : 'Alt+Shift+D' }); return stop(); }
    if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
    const mods = [];
    if (e.ctrlKey) mods.push('Control');
    if (e.altKey) mods.push('Alt');
    if (e.shiftKey) mods.push('Shift');
    if (e.metaKey) mods.push(S.platform === 'darwin' ? 'Command' : 'Super');
    if (!mods.some((m) => m !== 'Shift')) return toast(`Include ${S.platform === 'darwin' ? '⌘, ⌥ or ⌃' : 'Ctrl or Alt'}`, true);
    let key = e.code.startsWith('Key') ? e.code.slice(3) : e.code.startsWith('Digit') ? e.code.slice(5) : e.key.length === 1 ? e.key.toUpperCase() : e.key;
    if (key === ' ') key = 'Space';
    const r = await setSettings({ shortcut: [...mods, key].join('+') });
    if (r.shortcut && !r.shortcut.ok) toast(r.shortcut.error, true);
    stop();
  }
  function stop() {
    recording = false; b.classList.remove('rec');
    removeEventListener('keydown', onKey, true);
    invoke('shortcut:resume'); show();
    if (!$('#app').classList.contains('hidden')) renderList();
  }
  show();
  return b;
}

// ============================================================ welcome

function showWelcome() {
  const root = $('#welcome');
  root.classList.remove('hidden');
  const steps = ['welcome', 'formats', 'folder', 'signin', 'shortcuts', 'cloud', 'done'];
  let step = 0;
  function render() {
    const dots = h('div', { class: 'dots', style: { visibility: step ? 'visible' : 'hidden' } },
      steps.map((_, i) => h('i', { class: `${i <= step ? 'on' : ''} ${i === step ? 'cur' : ''}` })));
    const page = PAGES[steps[step]]();
    const primary = step === 0 ? 'Get started' : step === steps.length - 1 ? 'Start downloading' : 'Continue';
    const foot = h('div', { class: 'foot' },
      step > 0 && step < steps.length - 1 ? h('button', { class: 'btn-link', onclick: () => { step--; render(); } }, 'Back') : null,
      h('div', { style: { flex: 1 } }),
      steps[step] === 'signin' && !S.prefs.browser_cookies ? h('button', { class: 'btn-link', onclick: () => { step++; render(); } }, 'Skip for now') : null,
      h('button', { class: 'btn-primary', onclick: next }, primary));
    mount(root, dots, page, foot);
  }
  async function next() {
    if (step < steps.length - 1) { step++; render(); return; }
    await setSettings({ onboarded: true });
    root.classList.add('hidden');
    showApp();
  }
  const title = (t, sub) => [h('h1', {}, t), h('p', { class: 'lead' }, sub)];
  const PAGES = {
    welcome: () => h('div', { class: 'page center' }, wordmark(76),
      h('h2', { style: { font: '600 19px var(--font-display)', marginTop: '26px' } }, 'Download anything on the internet.'),
      h('p', { class: 'muted', style: { maxWidth: '440px', marginTop: '10px', fontSize: '14px' } },
        'Videos, songs, playlists and transcripts from YouTube, TikTok, Instagram, X, SoundCloud and over a thousand other sites. Straight to your computer, no accounts, no servers.'),
      h('div', { class: 'facts' },
        [['bolt', 'Fast', 'Downloads run side by side'], ['scissors', 'Precise', 'Save just the part you want'], ['lock', 'Private', 'Nothing leaves your computer']]
          .map(([ic, t, d]) => h('div', { class: 'card fact' }, icon(ic), h('b', {}, t), h('span', {}, d))))),
    formats: () => h('div', { class: 'page' }, title('Choose your default formats', 'Every download is saved this way. Change it any time in Settings.'),
      h('div', { class: 'label', style: { marginBottom: '8px' } }, 'Video'), radioList(FORMATS.video, S.prefs.video_format, (v) => { setPrefs({ video_format: v }); render(); }),
      h('div', { class: 'label', style: { margin: '16px 0 8px' } }, 'Audio'), radioList(FORMATS.audio, S.prefs.audio_format, (v) => { setPrefs({ audio_format: v }); render(); })),
    folder: () => h('div', { class: 'page' }, title('Choose where Dwn saves downloads', 'A folder in Downloads works well. You can change it any time.'),
      h('div', { class: 'card setting-card' }, icon('folder', 'lg'),
        h('div', { class: 't' }, h('b', {}, (S.prefs.folder || '').split(/[\\/]/).pop()), h('span', {}, S.prefs.folder)),
        h('button', { class: 'btn-quiet', onclick: async () => { await chooseFolder(); render(); } }, 'Change…')),
      S.free != null ? h('p', { class: 'note', style: { marginTop: '10px' } }, `${fmtBytes(S.free)} free on this drive`) : null),
    signin: () => h('div', { class: 'page' }, title('Sign in to YouTube, just in case',
      'Every so often, YouTube blocks downloads until it\'s sure a real person is behind them. Pick the browser where you\'re signed in to YouTube and Dwn will use that login when it needs to. Most downloads work without it.'),
    signInPanel(() => render())),
    shortcuts: () => h('div', { class: 'page' }, title('Download from anywhere', 'Start downloads without switching to Dwn.'),
      h('div', { style: { display: 'flex', flexDirection: 'column', gap: '10px' } },
        h('div', { class: 'card setting-card' }, icon('cmd', 'lg'), h('div', { class: 't' }, h('b', {}, 'Global shortcut'), h('span', {}, 'Opens a small download panel over any app, with the copied link ready.')), shortcutRecorder()),
        h('div', { class: 'card setting-card' }, icon('tray', 'lg'), h('div', { class: 't' }, h('b', {}, S.platform === 'darwin' ? 'Show in the menu bar' : 'Show in the system tray'), h('span', {}, 'Keeps Dwn one click away, even with the window closed.')),
          h('span', { class: `switch${S.settings.trayEnabled !== false ? ' on' : ''}`, onclick: (e) => { e.target.classList.toggle('on'); setSettings({ trayEnabled: e.target.classList.contains('on') }); } })),
        h('div', { class: 'card setting-card' }, icon('bookmark', 'lg'), h('div', { class: 't' }, h('b', {}, 'Send to Dwn bookmarklet'), h('span', {}, 'Paste it as a bookmark\'s address, then click it on any video page.')),
          h('button', { class: 'btn-quiet', onclick: () => { invoke('clipboard:write', "javascript:location.href='dwn://download?url='+encodeURIComponent(location.href)"); toast('Copied. Make a new bookmark and paste it as the address.'); } }, 'Copy')))),
    cloud: () => h('div', { class: 'page' }, title('Whole folders from Google Drive and Dropbox',
      `Connect an account in the Cloud tab to browse your files and everything shared with you, sorted by the person who shared it. Drag a folder to your ${IS_MAC() ? 'Mac' : 'PC'} and it downloads file by file, never as split 2 GB zips.`),
      tourCloudPreview()),
    done: () => h('div', { class: 'page center' }, h('div', { class: 'logomark', style: { width: '84px', height: '84px', borderRadius: '24px' } }, arrowSVG('')),
      h('h1', { style: { marginTop: '22px' } }, 'You\'re all set'),
      h('p', { class: 'muted', style: { fontSize: '14px' } }, `Paste a link, drop one anywhere in the window, or press ${shortcutLabel()} in any app.`),
      h('div', { class: 'card', style: { width: '380px', padding: '16px', marginTop: '22px', display: 'flex', flexDirection: 'column', gap: '8px' } },
        [['Video', formatName(S.prefs.video_format)], ['Audio', formatName(S.prefs.audio_format)], ['Saving to', S.prefs.folder],
          ['YouTube login', (S.browsers.find((b) => b.id === S.prefs.browser_cookies) || {}).name || 'Off']]
          .map(([k, v]) => h('div', { class: 'kv' }, h('span', { class: 'muted' }, k), h('span', { style: { maxWidth: '220px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, v))))),
  };
  render();
}
