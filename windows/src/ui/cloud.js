// Dwn main window: the Cloud tab. Google Drive, Dropbox, OneDrive, Box and
// pCloud through rclone, which the engine runs (all /cloud/* endpoints).
// Same layout as Links: a column of cards on the left, and on the right this
// PC and the cloud side by side. Drag between the two to copy whole folders.
'use strict';

// Google is still reviewing Dwn's sign-in app, so its consent screen warns
// that the app isn't verified. Set to true once Google approves Dwn.
const GOOGLE_VERIFIED = false;

const CL = {
  status: null,           // /cloud/status
  loc: null,              // { account, view, link, path, owner }
  entries: [],
  loading: false,
  listError: null,
  sel: new Set(),
  anchor: null,
  transfers: [],
  auth: null,             // sign-in in progress (/cloud/connect/status)
  authSeq: 0,
  usage: {},
  filter: '',
  local: { path: '', parent: null, crumbs: [], items: [], free: null },
  localSel: new Set(),
  localAnchor: null,
  cache: new Map(),
  known: new Set(),       // transfers already seen finished
  seeded: false,
  polling: false,
  built: false,
  listSeq: 0,
  el: {},
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isActiveT = (t) => t.state === 'queued' || t.state === 'running';
const cloudAccounts = () => (CL.status && CL.status.accounts) || [];
const cloudAccount = (name) => cloudAccounts().find((a) => a.name === name);
const revealLabel = () => (IS_MAC() ? 'Show in Finder' : 'Show in Explorer');
const pcName = () => (IS_MAC() ? 'This Mac' : 'This PC');
const savedLinks = () => (Array.isArray(S.settings.cloudLinks) ? S.settings.cloudLinks : []);
const linksFor = (account) => savedLinks().filter((l) => l.account === account);
const canWrite = () => !!CL.loc && (CL.loc.view === 'files' || CL.loc.view === 'link');

// ============================================================ lifecycle

// From showApp: watch transfers even while the Links tab is showing, so a
// cloud download finishing there still chimes and shows the panel.
function cloudInit() {
  refreshTransfers().then(() => { if (CL.transfers.some(isActiveT)) startPolling(); });
  setInterval(() => { if (!CL.polling) refreshTransfers().then(() => { if (CL.transfers.some(isActiveT)) startPolling(); }); }, 5000);
}

function cloudActivate() {
  if (!CL.built) buildCloud();
  refreshLocal();
  refreshStatus();
}

function buildCloud() {
  CL.built = true;
  const input = h('input', { placeholder: 'Filter files', spellcheck: false, oninput: (e) => { CL.filter = e.target.value; clearBtn.classList.toggle('hidden', !CL.filter); renderLocalList(); renderRemoteList(); } });
  const clearBtn = h('button', { class: 'btn-icon hidden', style: { width: '22px', height: '22px' }, title: 'Clear', onclick: () => { input.value = ''; CL.filter = ''; clearBtn.classList.add('hidden'); renderLocalList(); renderRemoteList(); } }, icon('xc', 'sm'));
  mount($('#cloud-search'), icon('search'), input, clearBtn);
  mount($('#cloud-actions'),
    h('button', { class: 'btn-icon filled lg', title: 'Open download folder', onclick: () => invoke('shell:folder', S.prefs.folder) }, icon('folder')),
    h('button', { class: 'btn-icon filled lg', title: 'Settings', onclick: () => openSettings() }, icon('gear')));
  // Both panes are built once and only their parts re-render, so lists keep their scroll position.
  CL.el.local = buildPane('local');
  CL.el.remote = buildPane('remote');
  CL.el.panes = h('div', { class: 'panes' }, CL.el.local.root, CL.el.remote.root);
  CL.el.transfers = h('div', { class: 'transfers hidden' });
  CL.el.state = h('div', { class: 'cloud-state hidden' });
  mount($('#cloud-body'), CL.el.panes, CL.el.transfers, CL.el.state);
  renderCloud();
}

async function refreshStatus() {
  try { CL.status = await api('cloud/status'); } catch (e) { CL.status = { available: false, services: [], accounts: [], error: e.message }; }
  const accts = cloudAccounts();
  if (!CL.loc || !cloudAccount(CL.loc.account)) {
    CL.loc = accts[0] ? { account: accts[0].name, view: 'files', link: null, path: '', owner: null } : null;
    CL.sel.clear();
    if (CL.loc) reload(); else CL.entries = [];
  }
  for (const a of accts) if (!(a.name in CL.usage)) loadUsage(a.name);
  renderCloud();
}

async function loadUsage(name) {
  CL.usage[name] = null;
  try {
    const a = await api('cloud/about', { account: name });
    if (a && a.used != null) { CL.usage[name] = { used: a.used, total: a.total || 0 }; renderCloudSidebar(); }
  } catch {}
}

// ============================================================ browsing

const locKey = (l) => JSON.stringify([l.account, l.view, l.link || '', l.path || '']);

function cloudOpen(loc) {
  CL.loc = { link: null, path: '', owner: null, ...loc };
  CL.sel.clear(); CL.anchor = null;
  reload();
  renderCloudSidebar();
}

async function reload(force = false) {
  const loc = CL.loc;
  if (!loc) return;
  CL.listError = null;
  if (loc.view === 'links') {   // the saved links list lives in Dwn's settings, not the engine
    CL.entries = []; CL.loading = false;
    renderRemote();
    return;
  }
  const key = locKey(loc);
  if (CL.cache.has(key) && !force) { CL.entries = CL.cache.get(key); CL.loading = false; } else { CL.entries = []; CL.loading = true; }
  renderRemote(true);
  const seq = ++CL.listSeq;
  const body = { account: loc.account, view: loc.view, path: loc.path };
  if (loc.link) body.link = loc.link;
  try {
    const r = await api('cloud/list', body);
    if (seq !== CL.listSeq) return;
    CL.cache.set(key, r.items || []);
    CL.entries = r.items || [];
  } catch (e) {
    if (seq !== CL.listSeq) return;
    CL.listError = e.message;
    CL.entries = [];
  }
  CL.loading = false;
  renderRemote();
}

// At the top of Drive's "Shared with me", each item says who owns it: group
// them into a list of people. Items without an owner go under "Others".
function cloudPeople() {
  const loc = CL.loc;
  const acct = loc && cloudAccount(loc.account);
  if (!loc || loc.view !== 'shared' || loc.path || loc.owner || !acct || acct.type !== 'drive') return null;
  if (!CL.entries.some((e) => e.owner)) return null;
  const counts = new Map();
  let others = 0;
  for (const e of CL.entries) { if (e.owner) counts.set(e.owner, (counts.get(e.owner) || 0) + 1); else others++; }
  const list = [...counts].sort((a, b) => a[0].toLowerCase().localeCompare(b[0].toLowerCase()));
  if (others) list.push(['Others', others]);
  return list;
}

function visibleEntries() {
  const loc = CL.loc;
  if (loc && loc.view === 'links') {
    return linksFor(loc.account).map((l) => ({ name: l.title, path: l.link, is_dir: true, saved: l }));
  }
  if (!loc || loc.path || !loc.owner) return CL.entries;
  return CL.entries.filter((e) => (e.owner || 'Others') === loc.owner);
}

function shownEntries() {
  const q = CL.filter.trim().toLowerCase();
  const all = visibleEntries();
  return q ? all.filter((e) => (e.name || '').toLowerCase().includes(q)) : all;
}
const selectedEntries = () => visibleEntries().filter((e) => CL.sel.has(e.path));

function enter(e) {
  if (!e.is_dir || !CL.loc) return;
  if (e.saved) return cloudOpen({ account: CL.loc.account, view: 'link', link: e.saved.link });
  cloudOpen({ ...CL.loc, path: e.path });
}

function showPerson(owner) {
  CL.loc = { ...CL.loc, owner };   // same listing, filtered: no reload
  CL.sel.clear();
  renderRemote(true);
}

function goUp() {
  const loc = CL.loc;
  if (!loc) return;
  if (!loc.path) {
    if (loc.owner) { CL.loc = { ...loc, owner: null }; CL.sel.clear(); renderRemote(true); }
    else if (loc.view === 'link') cloudOpen({ account: loc.account, view: 'links' });
    return;
  }
  const parts = loc.path.split('/'); parts.pop();
  cloudOpen({ ...loc, path: parts.join('/') });
}
const canGoUp = () => !!CL.loc && (!!CL.loc.path || !!CL.loc.owner || CL.loc.view === 'link');

function linkTitle(account, link) {
  const l = savedLinks().find((x) => x.account === account && x.link === link);
  return l ? l.title : 'Shared link';
}

// Path steps: [title, location] from the top down.
function cloudCrumbs() {
  const loc = CL.loc;
  const acct = loc && cloudAccount(loc.account);
  if (!acct) return [];
  const out = [];
  const root = { account: loc.account, view: loc.view, link: loc.link, path: '', owner: null };
  if (loc.view === 'link' || loc.view === 'links') {
    out.push(['Shared links', { account: loc.account, view: 'links' }]);
    if (loc.view === 'link') out.push([linkTitle(loc.account, loc.link), root]);
  } else {
    out.push([(acct.views.find((v) => v.id === loc.view) || {}).title || 'Files', root]);
  }
  if (loc.owner) out.push([loc.owner, { ...root, owner: loc.owner }]);
  let p = '';
  for (const part of (loc.path || '').split('/').filter(Boolean)) {
    p = p ? `${p}/${part}` : part;
    out.push([part, { ...root, owner: loc.owner, path: p }]);
  }
  return out;
}

function navigate(l) {
  const cur = CL.loc;
  if (cur && l.view === cur.view && (l.link || null) === (cur.link || null) && (l.path || '') === (cur.path || '') && l.view !== 'links') {
    CL.loc = { ...cur, owner: l.owner || null };   // only the person filter changed
    CL.sel.clear();
    renderRemote(true);
  } else cloudOpen(l);
}

async function newFolder() {
  const loc = CL.loc;
  const name = await promptDialog({ title: 'New folder', placeholder: 'Name', ok: 'Create' });
  if (!name || !loc) return;
  const body = { account: loc.account, view: loc.view, path: loc.path ? `${loc.path}/${name}` : name };
  if (loc.link) body.link = loc.link;
  try { await api('cloud/mkdir', body); reload(true); } catch (e) { toast(e.message, true); }
}

async function deleteItems(items) {
  const loc = CL.loc;
  if (!loc || !items.length || !canWrite()) return;
  const acct = cloudAccount(loc.account);
  const ok = await confirmDialog({
    title: items.length === 1 ? `Delete “${items[0].name}”?` : `Delete ${items.length} items?`,
    message: `They go to the ${acct ? acct.service : 'cloud'} trash, where you can restore them for a while.`,
    ok: 'Delete', danger: true,
  });
  if (!ok) return;
  const body = { account: loc.account, view: loc.view, items: items.map((e) => ({ path: e.path, is_dir: e.is_dir })) };
  if (loc.link) body.link = loc.link;
  try {
    await api('cloud/delete', body);
    toast(items.length === 1 ? `Moved “${items[0].name}” to the trash.` : `Moved ${items.length} items to the trash.`);
    reload(true);
  } catch (e) { toast(e.message, true); }
}

// ============================================================ accounts

async function connect(service, replace) {
  const seq = ++CL.authSeq;
  CL.auth = { type: service, state: 'starting' };
  renderAuth();
  try {
    const a = await api('cloud/connect', replace ? { service, replace } : { service });
    if (seq !== CL.authSeq) return;
    CL.auth = { type: service, ...(a || {}) };
    if (a && a.url) invoke('cloud:open-auth', a.url);
    renderAuth();
    while (seq === CL.authSeq) {
      await sleep(1000);
      if (seq !== CL.authSeq) return;
      let s;
      try { s = await api('cloud/connect/status'); } catch { continue; }
      if (!s || !s.state) { CL.auth = null; renderAuth(); return; }
      if (!CL.auth.url && s.url) invoke('cloud:open-auth', s.url);
      CL.auth = s;
      if (s.state === 'done') {
        CL.auth = null;
        await refreshStatus();
        if (s.account && s.account.name) {
          for (const k of [...CL.cache.keys()]) if (JSON.parse(k)[0] === s.account.name) CL.cache.delete(k);
          delete CL.usage[s.account.name];
          loadUsage(s.account.name);
          cloudOpen({ account: s.account.name, view: 'files' });
          toast(`Connected ${s.account.email || s.account.label || s.account.service}.`);
        }
        if (CL.connectModal) CL.connectModal.close();
        renderAuth();
        invoke('main:show');
        return;
      }
      renderAuth();
      if (s.state === 'failed' || s.state === 'cancelled') return;
    }
  } catch (e) {
    if (seq !== CL.authSeq) return;
    CL.auth = { type: service, state: 'failed', error: e.message };
    renderAuth();
  }
}

function cancelConnect() {
  CL.authSeq++;
  CL.auth = null;
  api('cloud/connect/cancel', {}).catch(() => {});
  renderAuth();
}

function openConnect(replace) {
  const box = h('div', { style: { padding: '22px', display: 'flex', flexDirection: 'column', gap: '16px' } },
    h('div', { style: { display: 'flex', alignItems: 'center' } },
      h('h2', { style: { flex: 1 } }, replace ? `Sign in to ${replace.service} again` : 'Add an account'),
      h('button', { class: 'btn-icon', title: 'Close', onclick: () => CL.connectModal && CL.connectModal.close() }, icon('x'))),
    h('p', { class: 'muted', style: { fontSize: '12.5px' } }, `Your browser opens to sign in. Dwn keeps the sign-in on this ${IS_MAC() ? 'Mac' : 'PC'} only.`),
    serviceButtons(replace));
  CL.connectModal = modal(box, { width: 440, onClose: () => {
    CL.connectModal = null;
    if (CL.auth && CL.auth.state !== 'failed') cancelConnect(); else { CL.auth = null; renderAuth(); }
  } });
  if (replace) connect(replace.type, replace.name);
}

// Service buttons plus the sign-in status. Re-rendered in place while signing in.
const authHosts = new Set();
function serviceButtons(replace) {
  const box = h('div', { class: 'svc-list' });
  box.render = () => {
    const busy = CL.auth && CL.auth.state !== 'failed';
    const services = (CL.status && CL.status.services) || [];
    const list = replace ? services.filter((s) => s.type === replace.type) : services;
    mount(box, list.map((s) => h('button', { class: 'svc-btn', disabled: !!busy, onclick: () => connect(s.type, replace ? replace.name : undefined) },
      serviceIcon(s.type, 26),
      h('span', { class: 't' }, h('b', {}, s.name), s.type === 'drive' && !GOOGLE_VERIFIED ? h('span', {}, 'Expect an “unverified app” notice') : null),
      icon('arrowur', 'sm'))),
    CL.auth ? authStatus() : null);
  };
  authHosts.add(box);
  box.render();
  return box;
}

function renderAuth() {
  for (const b of [...authHosts]) { if (b.isConnected) b.render(); else authHosts.delete(b); }
}

function authStatus() {
  const a = CL.auth;
  if (a.state === 'failed') {
    return h('div', { class: 'auth-status' }, h('div', { class: 'warn', style: { display: 'flex', gap: '8px', alignItems: 'flex-start' } }, icon('alert'), h('span', {}, a.error || 'Sign-in didn\'t finish.')));
  }
  return h('div', { class: 'auth-status' },
    h('div', { class: 'auth-wait' }, h('span', { class: 'spin' }), 'Finish signing in in your browser…'),
    a.type === 'drive' && !GOOGLE_VERIFIED ? googleNotice() : null,
    h('div', { style: { display: 'flex', gap: '8px', justifyContent: 'center' } },
      a.url ? h('button', { class: 'btn-quiet', style: { height: '30px' }, onclick: () => invoke('cloud:open-auth', a.url) }, 'Open sign-in page again') : null,
      h('button', { class: 'btn-quiet', style: { height: '30px' }, onclick: cancelConnect }, 'Cancel')));
}

// What to click on Google's "unverified app" screen (see GOOGLE_VERIFIED).
function googleNotice() {
  const step = (n, t) => h('span', { class: 'g-step' }, h('i', {}, n), t);
  return h('div', { class: 'g-note' },
    h('div', { class: 'g-head' }, icon('shield'),
      h('div', {}, h('b', {}, 'Google will say it hasn\'t verified Dwn'),
        h('span', {}, `Google is still reviewing Dwn. It's safe: Dwn runs only on this ${IS_MAC() ? 'Mac' : 'PC'} and never sends your files or sign-in anywhere.`))),
    h('div', { class: 'g-steps' }, step('1', 'Advanced'), step('2', 'Go to Dwn (unsafe)'), step('3', 'Allow')));
}

async function disconnect(acct) {
  const ok = await confirmDialog({
    title: `Remove ${acct.email || acct.service}?`,
    message: 'Dwn forgets this account. Nothing in it is deleted, and you can add it again later.',
    ok: 'Remove Account', danger: true,
  });
  if (!ok) return;
  try {
    await api('cloud/disconnect', { account: acct.name });
    saveLinks(savedLinks().filter((l) => l.account !== acct.name));
    if (CL.loc && CL.loc.account === acct.name) CL.loc = null;
    delete CL.usage[acct.name];
    await refreshStatus();
  } catch (e) { toast(e.message, true); }
}

// ============================================================ shared links

function saveLinks(list) {
  S.settings.cloudLinks = list;
  setSettings({ cloudLinks: list });
}

// "Open a shared link" (sidebar card): save the link and open it right away.
// "Add a shared link" (+ in the Shared links view): save it and stay on the list.
async function openAddLink(account, mode = 'add') {
  const opening = mode === 'open';
  const drives = cloudAccounts().filter((a) => a.type === 'drive');
  if (!drives.length) return;
  let acct = account || (drives[0] && drives[0].name);
  const err = h('div', { class: 'warn' });
  const linkIn = h('input', { placeholder: 'https://drive.google.com/drive/folders/…', spellcheck: false });
  const nameIn = h('input', { spellcheck: false });
  const defaultName = () => `Shared link ${linksFor(acct).length + 1}`;
  nameIn.value = defaultName();
  const clip = (await invoke('clipboard:read')).trim();
  if (/drive\.google\.com/.test(clip)) linkIn.value = clip;
  const picker = h('div');
  const renderPicker = () => mount(picker, drives.length > 1
    ? select(drives.map((d) => [d.name, d.email || d.label]), acct, (v) => { const wasDefault = nameIn.value === defaultName(); acct = v; if (wasDefault) nameIn.value = defaultName(); renderPicker(); }, { iconName: 'user', height: 38 })
    : null);
  renderPicker();
  let m;
  const submit = () => {
    const link = linkIn.value.trim();
    if (!link) { err.textContent = 'Paste a Google Drive folder link first.'; return; }
    if (!/drive\.google\.com|^[\w-]{20,}$/.test(link)) { err.textContent = 'That doesn\'t look like a Google Drive folder link.'; return; }
    const title = nameIn.value.trim() || defaultName();
    const list = savedLinks().filter((l) => !(l.account === acct && l.link === link));
    list.push({ account: acct, link, title });
    saveLinks(list);
    m.close();
    if (opening) cloudOpen({ account: acct, view: 'link', link });
    else { renderCloudSidebar(); renderRemote(); }
  };
  const onKey = (e) => { if (e.key === 'Enter') submit(); };
  linkIn.addEventListener('keydown', onKey); nameIn.addEventListener('keydown', onKey);
  const box = h('div', { style: { padding: '22px', display: 'flex', flexDirection: 'column', gap: '12px' } },
    h('h2', {}, opening ? 'Open a shared link' : 'Add a shared link'),
    h('p', { class: 'muted', style: { fontSize: '12.5px' } }, 'Paste a Google Drive folder link someone sent you. You can browse it and download all of it, without it being split into zips.'),
    h('label', { class: 'field' }, icon('link'), linkIn),
    h('label', { class: 'field' }, icon('tag'), nameIn),
    picker, err,
    h('div', { style: { display: 'flex', gap: '10px', justifyContent: 'flex-end', marginTop: '4px' } },
      h('button', { class: 'btn-quiet', onclick: () => m.close() }, 'Cancel'),
      h('button', { class: 'btn-primary', style: { width: '110px', height: '36px' }, onclick: submit }, opening ? 'Open' : 'Add')));
  m = modal(box, { width: 460 });
  setTimeout(() => (linkIn.value ? nameIn : linkIn).focus(), 50);
}

async function renameLink(l) {
  const title = await promptDialog({ title: 'Rename shared link', value: l.title, ok: 'Rename' });
  if (!title) return;
  saveLinks(savedLinks().map((x) => (x.account === l.account && x.link === l.link ? { ...x, title } : x)));
  renderRemote();
}

function removeLink(l) {
  saveLinks(savedLinks().filter((x) => !(x.account === l.account && x.link === l.link)));
  CL.sel.delete(l.link);
  if (CL.loc && CL.loc.view === 'link' && CL.loc.link === l.link) cloudOpen({ account: l.account, view: 'links' });
  else renderRemote();
}

function linkMenu(l) {
  return [
    { label: 'Open', run: () => cloudOpen({ account: l.account, view: 'link', link: l.link }) },
    { label: 'Download to ' + pcName(), run: () => cloudDownload([{ name: l.title, path: '', is_dir: true }], { account: l.account, view: 'link', link: l.link }) },
    '-',
    { label: 'Rename…', run: () => renameLink(l) },
    { label: 'Copy link', run: () => { invoke('clipboard:write', l.link); toast('Link copied.'); } },
    { label: 'Remove', danger: true, run: () => removeLink(l) },
  ];
}

// ============================================================ transfers

// Copy cloud items into a folder on this computer (the This PC pane's folder by default).
async function cloudDownload(items, loc, dest) {
  if (!loc) return;
  let list = items;
  if (!list.length) {
    if (!loc.path && loc.view !== 'link') return;
    list = [{ name: loc.path ? loc.path.split('/').pop() : linkTitle(loc.account, loc.link), path: loc.path || '', is_dir: true }];
  }
  const body = { account: loc.account, view: loc.view, dest: dest || CL.local.path || S.prefs.folder,
    items: list.map((e) => ({ path: e.path, name: e.name, is_dir: !!e.is_dir })) };
  if (loc.link) body.link = loc.link;
  try {
    const t = await api('cloud/download', body);
    for (const n of t) if (!CL.transfers.some((x) => x.id === n.id)) CL.transfers.push(n);
    renderTransfers();
    startPolling();
  } catch (e) { toast(e.message, true); }
}

// Copy files and folders from this computer into the cloud folder being shown.
async function cloudUpload(paths, loc = CL.loc) {
  if (!loc || !paths.length) return;
  if (loc.view !== 'files' && loc.view !== 'link') {
    toast('You can\'t add files here. Open My Drive or one of your folders first.', true);
    return;
  }
  const body = { account: loc.account, view: loc.view, path: loc.path || '', files: paths };
  if (loc.link) body.link = loc.link;
  try {
    const t = await api('cloud/upload', body);
    CL.transfers.push(...t);
    renderTransfers();
    startPolling();
  } catch (e) { toast(e.message, true); }
}

// About every 0.7 s while anything is copying.
async function startPolling() {
  if (CL.polling) return;
  CL.polling = true;
  try {
    for (;;) {
      await refreshTransfers();
      if (!CL.transfers.some(isActiveT)) break;
      await sleep(700);
    }
  } finally { CL.polling = false; }
}

async function refreshTransfers() {
  if (S.engine.state !== 'running') return;
  let list;
  try { list = await api('cloud/transfers'); } catch { return; }
  const changed = JSON.stringify(list) !== JSON.stringify(CL.transfers);
  CL.transfers = list;
  for (const t of list) {
    if (isActiveT(t) || CL.known.has(t.id)) continue;
    CL.known.add(t.id);
    // Transfers that had already finished when Dwn opened aren't news.
    if (!CL.seeded || t.state !== 'done') continue;
    if (t.direction === 'down') {
      refreshLocal();
      downloadFinished({ cloud: true, direction: 'down', title: t.name, file: t.local, size: t.bytes || null, files: t.files_total });
    } else {
      if (CL.loc && t.account === CL.loc.account) reload(true);
      downloadFinished({ cloud: true, direction: 'up', title: t.name });
    }
  }
  CL.seeded = true;
  if (changed) renderTransfers();
}

async function transferAction(t, action) {
  try { await api(`cloud/transfers/${t.id}/${action}`, {}); } catch (e) { toast(e.message, true); }
  if (action === 'retry') CL.known.delete(t.id);
  await refreshTransfers();
  startPolling();
}

async function clearFinished() {
  try { await api('cloud/transfers/clear', {}); } catch {}
  await refreshTransfers();
}

// ============================================================ this PC

async function refreshLocal(dir) {
  const want = dir || CL.local.path || S.settings.cloudLocalFolder || S.prefs.folder;
  const r = await invoke('fs:list', want);
  if (r.error) {
    toast(r.error, true);
    if (CL.local.path) return;
    const fallback = await invoke('fs:list', S.prefs.folder);
    if (fallback.error) return;
    Object.assign(CL.local, fallback);
  } else {
    const moved = r.path !== CL.local.path;
    CL.local = r;
    if (moved) { CL.localSel.clear(); CL.localAnchor = null; }
    if (dir && r.path !== S.settings.cloudLocalFolder) { S.settings.cloudLocalFolder = r.path; setSettings({ cloudLocalFolder: r.path }); }
    if (moved && CL.el.local) CL.el.local.list.scrollTop = 0;
  }
  renderLocal();
}

async function chooseLocalFolder() {
  const p = await invoke('dialog:folder', CL.local.path, `Choose a folder on this ${IS_MAC() ? 'Mac' : 'PC'}`);
  if (p) refreshLocal(p);
}

const shownLocal = () => {
  const q = CL.filter.trim().toLowerCase();
  return q ? CL.local.items.filter((e) => e.name.toLowerCase().includes(q)) : CL.local.items;
};
const selectedLocal = () => CL.local.items.filter((e) => CL.localSel.has(e.path));

// ============================================================ rendering

function renderCloud() {
  if (!CL.built) return;
  renderCloudSidebar();
  const st = CL.status;
  let state = null;
  if (!st) state = h('div', { class: 'empty' }, h('span', { class: 'spin' }));
  else if (!st.available) {
    state = h('div', { class: 'empty' }, h('div', { class: 'warn-ic' }, icon('cloud', 'lg')),
      h('div', {}, h('h3', {}, 'Cloud drives aren\'t available'),
        h('p', { style: { maxWidth: '440px', marginTop: '6px' } }, IS_MAC()
          ? 'This copy of Dwn doesn\'t include rclone, which it uses to talk to Google Drive and Dropbox. Install it with Homebrew (brew install rclone), then restart Dwn.'
          : 'This copy of Dwn is missing rclone, which it uses to talk to Google Drive and Dropbox. Reinstall Dwn, then try again.'),
        st.error ? h('p', { class: 'note', style: { marginTop: '8px', userSelect: 'text' } }, st.error) : null));
  } else if (!cloudAccounts().length) {
    state = h('div', { class: 'empty cloud-welcome' }, h('div', { class: 'logomark' }, arrowSVG('')),
      h('div', {}, h('h3', {}, 'Download whole folders from the cloud'),
        h('p', { style: { marginTop: '6px' } }, 'Connect Google Drive or Dropbox to browse your files and everything', h('br'),
          `shared with you, then drag folders to your ${IS_MAC() ? 'Mac' : 'PC'}. They arrive file by file, never as split zips.`)),
      h('div', { style: { width: '320px', marginTop: '4px' } }, serviceButtons()));
  }
  CL.el.state.classList.toggle('hidden', !state);
  CL.el.panes.classList.toggle('hidden', !!state);
  $('#cloud-search').style.visibility = state ? 'hidden' : 'visible';
  if (state) { mount(CL.el.state, state); CL.el.transfers.classList.add('hidden'); return; }
  mount(CL.el.state);
  renderLocal();
  renderRemote();
  renderTransfers();
}

function serviceIcon(type, size = 22) {
  const colors = { drive: '#21964f', dropbox: '#0061ff', onedrive: '#0078d6', box: '#0061d6' };
  const glyph = { drive: 'triangle', dropbox: 'box', box: 'square' }[type] || 'cloud';
  return h('span', { class: 'svc-ic', style: { width: `${size}px`, height: `${size}px`, borderRadius: `${Math.round(size * 0.26)}px`, background: colors[type] || '#149eBF' } }, icon(glyph));
}

const VIEW_ICONS = { files: 'folder', shared: 'users', shared_files: 'copy', links: 'link' };

function renderCloudSidebar() {
  const side = $('#cloud-side');
  if (!side) return;
  const st = CL.status;
  const accts = cloudAccounts();
  const kids = [];
  if (accts.length) {
    const sections = [];
    accts.forEach((a, i) => {
      if (i) sections.push(h('div', { class: 'acct-sep' }));
      const views = [...a.views];
      if (a.type === 'drive') views.push({ id: 'links', title: 'Shared links' });
      const cur = CL.loc && CL.loc.account === a.name ? (CL.loc.view === 'link' ? 'links' : CL.loc.view) : null;
      const usage = CL.usage[a.name];
      const more = h('button', { class: 'btn-icon', title: 'Account', onclick: (e) => {
        const r = e.currentTarget.getBoundingClientRect();
        popupMenu(r.left, r.bottom + 4, [
          { label: 'Sign In Again', run: () => openConnect(a) },
          '-',
          { label: 'Remove Account…', danger: true, run: () => disconnect(a) },
        ]);
      } }, icon('more'));
      sections.push(h('div', { class: 'acct' },
        h('div', { class: 'acct-head' }, serviceIcon(a.type, 32),
          h('div', { class: 'acct-t' }, h('b', {}, a.service), a.email ? h('span', { title: a.email }, a.email) : null), more),
        views.map((v) => h('button', { class: `side-row${cur === v.id ? ' on' : ''}`, onclick: () => cloudOpen({ account: a.name, view: v.id }) },
          icon(VIEW_ICONS[v.id] || 'folder'), h('span', {}, v.title),
          v.id === 'links' && linksFor(a.name).length ? h('span', { class: 'count' }, linksFor(a.name).length) : null)),
        usage && usage.total > 0 ? h('div', { class: 'usage' }, progress(usage.used / usage.total), h('span', {}, `${fmtBytes(usage.used)} of ${fmtBytes(usage.total)} used`)) : null));
    });
    kids.push(h('div', { class: 'card accounts' }, h('div', { class: 'label' }, 'Accounts'), sections));
  }
  if (st && st.available && accts.some((a) => a.type === 'drive')) {
    const here = CL.loc && accts.find((a) => a.name === CL.loc.account && a.type === 'drive');
    kids.push(h('button', { class: 'card bulk-card', onclick: () => openAddLink(here ? here.name : undefined, 'open') },
      h('span', { class: 'ic' }, icon('link')),
      h('span', {}, h('b', {}, 'Open a shared link'), h('span', {}, 'Paste a Drive folder someone sent you'))));
  }
  if (st && st.available) {
    kids.push(h('button', { class: 'card bulk-card', onclick: () => openConnect() },
      h('span', { class: 'ic' }, icon('plus')),
      h('span', {}, h('b', {}, 'Add account'), h('span', {}, 'Google Drive, Dropbox, OneDrive and more'))));
  }
  const top = side.scrollTop;
  mount(side, kids);
  side.scrollTop = top;
}

// ---------- panes

function buildPane(kind) {
  const head = h('div', { class: 'pane-head' });
  const list = h('div', { class: 'pane-list' });
  const foot = h('div', { class: 'pane-foot' });
  const hl = h('div', { class: 'pane-drop hidden' }, h('div', { class: 'pane-drop-in' }, arrowSVG(''), h('b')));
  const root = h('div', { class: 'card pane' }, head, list, foot, hl);
  list.addEventListener('click', (e) => {
    if (e.target !== list && !e.target.classList.contains('rows')) return;
    (kind === 'local' ? CL.localSel : CL.sel).clear();
    paintSel(kind);
    if (kind === 'local') renderLocalFoot(); else renderRemoteFoot();
  });
  // Drops: cloud rows onto This PC (download), local rows or Explorer files onto the cloud (upload).
  let depth = 0;
  const accepts = (dt) => {
    const types = [...(dt.types || [])];
    if (kind === 'local') return types.includes('application/x-dwn-cloud');
    return types.includes('application/x-dwn-local') || types.includes('Files');
  };
  root.addEventListener('dragenter', (e) => {
    if (!accepts(e.dataTransfer)) return;
    e.preventDefault(); depth++;
    $('b', hl).textContent = kind === 'local' ? 'Download here' : (CL.loc && CL.loc.view === 'links') ? 'Open a shared link to upload' : canWrite() ? 'Upload here' : 'Open My Drive to upload';
    hl.classList.remove('hidden');
  });
  root.addEventListener('dragover', (e) => { if (accepts(e.dataTransfer)) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; } });
  root.addEventListener('dragleave', () => { if (--depth <= 0) { depth = 0; hl.classList.add('hidden'); } });
  root.addEventListener('drop', (e) => {
    depth = 0; hl.classList.add('hidden');
    if (!accepts(e.dataTransfer)) return;
    e.preventDefault();
    const dt = e.dataTransfer;
    if (kind === 'local') {
      try { const d = JSON.parse(dt.getData('application/x-dwn-cloud')); cloudDownload(d.items, d.loc); } catch {}
      return;
    }
    let paths = [];
    const internal = dt.getData('application/x-dwn-local');
    if (internal) { try { paths = JSON.parse(internal); } catch {} }
    else paths = [...dt.files].map((f) => window.dwn.pathForFile(f)).filter(Boolean);
    if (paths.length) cloudUpload(paths);
  });
  return { root, head, list, foot };
}

function crumbBar(crumbs, go) {
  const bar = h('div', { class: 'crumbs' }, crumbs.map(([title, target], i) => [
    i ? icon('right', 'sm') : null,
    h('button', { class: i === crumbs.length - 1 ? 'last' : '', title, onclick: () => go(target) }, title)]));
  requestAnimationFrame(() => { bar.scrollLeft = bar.scrollWidth; });
  return bar;
}

function paneTitle(ic, title, sub) {
  return h('div', { class: 'pane-title' }, ic, h('div', { class: 'pt' }, h('b', {}, title), sub ? h('span', { title: sub }, sub) : null));
}

function fileIconName(name, isDir, mime) {
  if (isDir) return 'folder';
  const ext = (String(name).split('.').pop() || '').toLowerCase();
  if (mime && (mime.startsWith('application/vnd.google-apps') || mime.includes('officedocument'))) return 'text';
  if (/^(jpe?g|png|heic|gif|webp|tiff?|raw|cr2|cr3|nef|arw|dng|psd|bmp|svg)$/.test(ext)) return 'image';
  if (/^(mp4|mov|mkv|avi|m4v|webm|mxf|braw|r3d|wmv)$/.test(ext)) return 'film';
  if (/^(mp3|wav|aac|m4a|flac|aiff?|ogg|opus)$/.test(ext)) return 'wave';
  if (/^(zip|rar|7z|tar|gz|bz2|xz)$/.test(ext)) return 'archive';
  if (/^(xlsx?|csv|numbers|ods)$/.test(ext)) return 'sheet';
  if (/^(pdf|txt|md|rtf|docx?|pages|odt)$/.test(ext)) return 'text';
  return 'file';
}

function fmtDay(d) {
  if (d == null || d === '') return '';
  const t = typeof d === 'number' ? new Date(d) : new Date(String(d).replace(/\.\d+/, ''));
  return isNaN(t) ? '' : t.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

function fileRow({ id, name, isDir, size, date, mime, meta, sel, arrow, arrowTitle, onArrow, onOpen, onSelect, onMenu, onDrag, more }) {
  const sub = meta || [isDir ? 'Folder' : (size != null ? fmtBytes(size) : ''), fmtDay(date)].filter(Boolean).join(' · ');
  const row = h('div', { class: `frow${sel ? ' on' : ''}`, draggable: 'true', title: name },
    h('span', { class: `ftile${isDir ? ' dir' : ''}` }, icon(fileIconName(name, isDir, mime))),
    h('div', { class: 'fmeta' }, h('div', { class: 'fname' }, name), h('div', { class: 'fsub' }, sub)),
    more ? h('button', { class: 'btn-icon farrow fmore', title: 'More', onclick: (e) => {
      e.stopPropagation();
      const r = e.currentTarget.getBoundingClientRect();
      onMenu({ clientX: r.left, clientY: r.bottom + 4 });
    } }, icon('more')) : null,
    h('button', { class: 'btn-icon filled farrow', title: arrowTitle, onclick: (e) => { e.stopPropagation(); onArrow(); } }, icon(arrow)));
  row.dataset.id = id;
  row.addEventListener('click', (e) => { if (e.detail >= 2) onOpen(); else onSelect(e); });
  row.addEventListener('contextmenu', (e) => { e.preventDefault(); onMenu(e); });
  row.addEventListener('dragstart', onDrag);
  return row;
}

// Click selects, Ctrl-click (⌘ on a Mac) toggles, Shift-click selects a range.
function clickSelect(e, id, order, sel, anchorKey) {
  const toggle = IS_MAC() ? e.metaKey : e.ctrlKey;
  const anchor = CL[anchorKey];
  if (toggle) { if (sel.has(id)) sel.delete(id); else sel.add(id); CL[anchorKey] = id; }
  else if (e.shiftKey && anchor && order.includes(anchor)) {
    const i = order.indexOf(anchor); const j = order.indexOf(id);
    sel.clear();
    order.slice(Math.min(i, j), Math.max(i, j) + 1).forEach((x) => sel.add(x));
  } else { sel.clear(); sel.add(id); CL[anchorKey] = id; }
}

function paintSel(kind) {
  const pane = kind === 'local' ? CL.el.local : CL.el.remote;
  const sel = kind === 'local' ? CL.localSel : CL.sel;
  if (!pane) return;
  pane.list.querySelectorAll('.frow').forEach((r) => r.classList.toggle('on', sel.has(r.dataset.id)));
}

function selectRow(kind, e, id) {
  if (kind === 'local') { clickSelect(e, id, shownLocal().map((x) => x.path), CL.localSel, 'localAnchor'); paintSel('local'); renderLocalFoot(); }
  else { clickSelect(e, id, shownEntries().map((x) => x.path), CL.sel, 'anchor'); paintSel('remote'); renderRemoteFoot(); }
}

function paneFoot(text) {
  return [h('span', {}, text), h('span', { class: 'hint' }, 'Drag to copy')];
}

function emptyText(text) {
  return h('div', { class: 'pane-empty' }, text.split('\n').map((l, i) => [i ? h('br') : null, l]));
}

// ---------- This PC

function renderLocal() {
  const p = CL.el.local;
  if (!p) return;
  mount(p.head,
    h('div', { class: 'pane-top' },
      paneTitle(h('span', { class: 'pc-ic' }, icon('monitor')), pcName(), CL.local.free != null ? `${fmtBytes(CL.local.free)} free` : null),
      h('button', { class: 'btn-icon', title: 'Enclosing folder', disabled: !CL.local.parent, onclick: () => CL.local.parent && refreshLocal(CL.local.parent) }, icon('up')),
      h('button', { class: 'btn-icon', title: 'Choose folder…', onclick: chooseLocalFolder }, icon('folder'))),
    crumbBar(CL.local.crumbs.map((c) => [c.title, c.path]), (path) => refreshLocal(path)));
  renderLocalList();
}

function renderLocalList() {
  const p = CL.el.local;
  if (!p) return;
  const items = shownLocal();
  const top = p.list.scrollTop;
  mount(p.list, items.length ? h('div', { class: 'rows' }, items.map((e) => fileRow({
    id: e.path, name: e.name, isDir: e.is_dir, size: e.size, date: e.modified, sel: CL.localSel.has(e.path),
    arrow: 'up', arrowTitle: 'Upload to the cloud folder on the right',
    onArrow: () => cloudUpload(CL.localSel.has(e.path) ? selectedLocal().map((x) => x.path) : [e.path]),
    onOpen: () => { if (e.is_dir) refreshLocal(e.path); else invoke('shell:open', e.path).then((r) => r && r.error && toast(r.error, true)); },
    onSelect: (ev) => selectRow('local', ev, e.path),
    onMenu: (ev) => {
      if (!CL.localSel.has(e.path)) { CL.localSel.clear(); CL.localSel.add(e.path); CL.localAnchor = e.path; paintSel('local'); renderLocalFoot(); }
      const paths = selectedLocal().map((x) => x.path);
      popupMenu(ev.clientX, ev.clientY, [
        { label: 'Upload to the cloud', run: () => (CL.loc ? cloudUpload(paths) : toast('Add a cloud account first.', true)) },
        { label: 'Open', run: () => paths.forEach((x) => invoke('shell:open', x)) },
        { label: revealLabel(), run: () => invoke('shell:reveal', paths[0]) },
      ]);
    },
    onDrag: (ev) => {
      const paths = CL.localSel.has(e.path) ? selectedLocal().map((x) => x.path) : [e.path];
      ev.dataTransfer.effectAllowed = 'copy';
      ev.dataTransfer.setData('application/x-dwn-local', JSON.stringify(paths));
    },
  }))) : emptyText(CL.filter ? `Nothing matches “${CL.filter}”` : 'This folder is empty.\nDrag cloud files here to download them.'));
  p.list.scrollTop = top;
  renderLocalFoot();
}

function renderLocalFoot() {
  const sel = selectedLocal();
  mount(CL.el.local.foot, paneFoot(sel.length ? `${sel.length} selected` : `${CL.local.items.length} item${CL.local.items.length === 1 ? '' : 's'}`));
}

// ---------- cloud

function renderRemote(resetScroll) {
  const p = CL.el.remote;
  if (!p) return;
  const loc = CL.loc;
  const acct = loc && cloudAccount(loc.account);
  const btns = [h('button', { class: 'btn-icon', title: 'Enclosing folder', disabled: !canGoUp(), onclick: goUp }, icon('up'))];
  if (loc && loc.view === 'links') btns.push(h('button', { class: 'btn-icon', title: 'Add a shared link', onclick: () => openAddLink(loc.account) }, icon('plus')));
  else btns.push(h('button', { class: 'btn-icon', title: 'Refresh', disabled: !loc, onclick: () => reload(true) }, icon('refresh')));
  if (canWrite()) btns.push(h('button', { class: 'btn-icon', title: 'New folder', onclick: newFolder }, icon('folderplus')));
  mount(p.head,
    h('div', { class: 'pane-top' }, paneTitle(serviceIcon(acct ? acct.type : '', 32), acct ? acct.service : 'Cloud', acct ? acct.email : null), btns),
    crumbBar(cloudCrumbs(), navigate));
  if (resetScroll) p.list.scrollTop = 0;
  renderRemoteList();
}

function renderRemoteList() {
  const p = CL.el.remote;
  if (!p) return;
  const loc = CL.loc;
  const top = p.list.scrollTop;
  const people = cloudPeople();
  if (people) {
    mount(p.list, h('div', { class: 'rows' }, people.map(([owner, n]) => h('button', { class: 'person', onclick: () => showPerson(owner) },
      h('span', { class: 'avatar', style: { background: personColor(owner) } }, owner[0].toUpperCase()),
      h('div', { class: 'fmeta' }, h('div', { class: 'fname' }, owner), h('div', { class: 'fsub' }, n === 1 ? '1 item shared with you' : `${n} items shared with you`)),
      icon('right', 'sm')))));
  } else if (CL.loading) {
    mount(p.list, h('div', { class: 'pane-empty' }, h('span', { class: 'spin' })));
  } else if (CL.listError) {
    mount(p.list, h('div', { class: 'pane-empty' }, h('div', { class: 'warn-ic' }, icon('alert', 'lg')),
      h('div', { style: { userSelect: 'text', color: 'var(--text2)' } }, CL.listError),
      h('button', { class: 'btn-quiet', style: { height: '30px', marginTop: '4px' }, onclick: () => reload(true) }, 'Try Again')));
  } else {
    const items = shownEntries();
    const isLinks = loc && loc.view === 'links';
    let empty = null;
    if (!items.length && loc) {
      if (CL.filter) empty = emptyText(`Nothing matches “${CL.filter}”`);
      else if (isLinks) {
        empty = h('div', { class: 'pane-empty' }, h('div', { style: { maxWidth: '260px' } }, 'Paste a Google Drive folder link someone sent you to keep it here.'),
          h('button', { class: 'btn-quiet', style: { height: '30px', marginTop: '6px' }, onclick: () => openAddLink(loc.account) }, icon('plus', 'sm'), 'Add a link'));
      } else empty = emptyText(canWrite() ? 'This folder is empty.\nDrag files here to upload them.' : 'Nothing here yet.');
    }
    mount(p.list, empty || h('div', { class: 'rows' }, items.map((e) => remoteRow(e, isLinks))));
  }
  p.list.scrollTop = top;
  renderRemoteFoot();
}

function remoteRow(e, isLinks) {
  const loc = CL.loc;
  const items = () => (CL.sel.has(e.path) ? selectedEntries() : [e]);
  if (isLinks) {
    const l = e.saved;
    const linkLoc = { account: l.account, view: 'link', link: l.link };
    return fileRow({
      id: e.path, name: l.title, isDir: true, meta: 'Shared link', sel: CL.sel.has(e.path), more: true,
      arrow: 'right', arrowTitle: 'Open', onArrow: () => cloudOpen(linkLoc), onOpen: () => cloudOpen(linkLoc),
      onSelect: (ev) => selectRow('remote', ev, e.path),
      onMenu: (ev) => popupMenu(ev.clientX, ev.clientY, linkMenu(l)),
      onDrag: (ev) => {
        ev.dataTransfer.effectAllowed = 'copy';
        ev.dataTransfer.setData('application/x-dwn-cloud', JSON.stringify({ loc: linkLoc, items: [{ name: l.title, path: '', is_dir: true }] }));
      },
    });
  }
  return fileRow({
    id: e.path, name: e.name, isDir: e.is_dir, size: e.size, date: e.modified, mime: e.mime, sel: CL.sel.has(e.path),
    arrow: 'down', arrowTitle: `Download to the folder on the left`,
    onArrow: () => cloudDownload(items(), loc),
    onOpen: () => { if (e.is_dir) enter(e); else cloudDownload([e], loc); },
    onSelect: (ev) => selectRow('remote', ev, e.path),
    onMenu: (ev) => {
      if (!CL.sel.has(e.path)) { CL.sel.clear(); CL.sel.add(e.path); CL.anchor = e.path; paintSel('remote'); renderRemoteFoot(); }
      const list = selectedEntries();
      const menu = [];
      if (e.is_dir && list.length === 1) menu.push({ label: 'Open', run: () => enter(e) });
      menu.push({ label: `Download to ${pcName()}`, run: () => cloudDownload(list, loc) });
      menu.push({ label: 'Download to…', run: async () => {
        const dest = await invoke('dialog:folder', CL.local.path, 'Choose where to download');
        if (dest) cloudDownload(list, loc, dest);
      } });
      if (canWrite()) menu.push('-', { label: 'Delete…', danger: true, run: () => deleteItems(list) });
      popupMenu(ev.clientX, ev.clientY, menu);
    },
    onDrag: (ev) => {
      ev.dataTransfer.effectAllowed = 'copy';
      ev.dataTransfer.setData('application/x-dwn-cloud', JSON.stringify({ loc, items: items().map((x) => ({ name: x.name, path: x.path, is_dir: x.is_dir })) }));
    },
  });
}

function renderRemoteFoot() {
  const people = cloudPeople();
  let text;
  if (people) text = people.length === 1 ? '1 person' : `${people.length} people`;
  else {
    const sel = selectedEntries();
    if (sel.length) {
      const size = sel.reduce((n, x) => n + (x.size || 0), 0);
      text = `${sel.length} selected${size > 0 ? ` · ${fmtBytes(size)}` : ''}`;
    } else {
      const n = visibleEntries().length;
      text = CL.loc && CL.loc.view === 'links' ? `${n} link${n === 1 ? '' : 's'}` : `${n} item${n === 1 ? '' : 's'}`;
    }
  }
  mount(CL.el.remote.foot, paneFoot(text));
}

function personColor(owner) {
  const palette = ['#ccff4d', '#8ccbff', '#ffbf80', '#d9b3ff', '#99f2cc'];
  let x = 0;
  for (const ch of owner) x = (x * 31 + ch.codePointAt(0)) & 0xffff;
  return palette[x % palette.length];
}

// ---------- transfers

function renderTransfers() {
  const box = CL.el.transfers;
  if (!box) return;
  const show = CL.transfers.length && CL.status && CL.status.available && cloudAccounts().length;
  box.classList.toggle('hidden', !show);
  if (!show) return mount(box);
  const finished = CL.transfers.some((t) => t.state === 'done' || t.state === 'cancelled');
  const list = box.querySelector('.t-list');
  const top = list ? list.scrollTop : 0;
  const newList = h('div', { class: 't-list' }, [...CL.transfers].reverse().map(transferCard));
  mount(box, h('div', { class: 'sec-head' }, 'Transfers', finished ? h('button', { class: 'btn-link', onclick: clearFinished }, 'Clear finished') : null), newList);
  newList.scrollTop = top;
}

function transferDetail(t) {
  if (t.state === 'queued') return 'Waiting for a free slot';
  if (t.state === 'cancelled') return 'Stopped';
  if (t.state === 'failed') return t.error || 'Couldn\'t copy';
  if (t.state === 'done') {
    let s = t.direction === 'down' ? 'Downloaded' : 'Uploaded';
    if (t.bytes > 0) s += ` · ${fmtBytes(t.bytes)}`;
    if (t.files_total > 1) s += ` · ${t.files_total} files`;
    if (t.error) s += ` · ${t.error}`;
    return s;
  }
  const parts = [];
  if (t.total > 0) parts.push(`${fmtBytes(t.bytes)} of ${fmtBytes(t.total)}`);
  else parts.push(t.bytes > 0 ? fmtBytes(t.bytes) : 'Starting');
  if (t.speed > 0) parts.push(`${fmtBytes(t.speed)}/s`);
  if (t.eta > 0) parts.push(`${fmtTime(t.eta)} left`);
  if (t.is_dir && t.files_total > 0) parts.push(`${t.files} of ${t.files_total} files`);
  return parts.join(' · ');
}

function transferCard(t) {
  const active = isActiveT(t);
  const frac = t.total > 0 ? Math.min(1, t.bytes / t.total) : null;
  const acts = active
    ? [h('button', { class: 'btn-icon', title: 'Stop', onclick: () => transferAction(t, 'cancel') }, icon('x'))]
    : [t.direction === 'down' && t.state === 'done' && t.local ? h('button', { class: 'btn-icon', title: revealLabel(), onclick: () => invoke('shell:reveal', t.local).then((r) => r && r.error && toast(r.error, true)) }, icon('search')) : null,
      t.state !== 'done' || t.error ? h('button', { class: 'btn-icon', title: 'Try again (skips files already copied)', onclick: () => transferAction(t, 'retry') }, icon('refresh')) : null,
      h('button', { class: 'btn-icon', title: 'Remove from list', onclick: () => transferAction(t, 'dismiss') }, icon('x'))];
  return h('div', { class: 'card job tcard' },
    h('span', { class: `t-ic${t.state === 'done' ? ' done' : ''}` }, icon(t.direction === 'down' ? 'down' : 'up')),
    h('div', { class: 'meta' }, h('div', { class: 'title' }, t.name),
      active ? progress(frac || 0, t.state === 'queued' || frac == null) : null,
      h('div', { class: `t-detail${t.state === 'failed' ? ' err' : ''}` }, transferDetail(t))),
    h('div', { class: 'acts' }, acts));
}

// ============================================================ dialogs

function confirmDialog({ title, message, ok = 'OK', danger = false }) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => { if (done) return; done = true; m.close(); resolve(v); };
    const box = h('div', { style: { padding: '22px', display: 'flex', flexDirection: 'column', gap: '10px' } },
      h('h2', { style: { fontSize: '17px' } }, title),
      message ? h('p', { class: 'muted', style: { fontSize: '12.5px' } }, message) : null,
      h('div', { style: { display: 'flex', gap: '10px', justifyContent: 'flex-end', marginTop: '8px' } },
        h('button', { class: 'btn-quiet', onclick: () => finish(false) }, 'Cancel'),
        h('button', { class: `btn-primary${danger ? ' danger' : ''}`, style: { width: 'auto', padding: '0 16px', height: '36px' }, onclick: () => finish(true) }, ok)));
    const m = modal(box, { width: 400, onClose: () => { if (!done) { done = true; resolve(false); } } });
  });
}

function promptDialog({ title, value = '', placeholder = '', ok = 'OK' }) {
  return new Promise((resolve) => {
    let done = false;
    const input = h('input', { placeholder, spellcheck: false });
    input.value = value;
    const finish = (v) => { if (done) return; done = true; m.close(); resolve(v); };
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') finish(input.value.trim()); });
    const box = h('div', { style: { padding: '22px', display: 'flex', flexDirection: 'column', gap: '14px' } },
      h('h2', { style: { fontSize: '17px' } }, title),
      h('label', { class: 'field' }, input),
      h('div', { style: { display: 'flex', gap: '10px', justifyContent: 'flex-end' } },
        h('button', { class: 'btn-quiet', onclick: () => finish(null) }, 'Cancel'),
        h('button', { class: 'btn-primary', style: { width: 'auto', padding: '0 18px', height: '36px' }, onclick: () => finish(input.value.trim()) }, ok)));
    const m = modal(box, { width: 380, onClose: () => { if (!done) { done = true; resolve(null); } } });
    setTimeout(() => { input.focus(); input.select(); }, 50);
  });
}

// ============================================================ welcome tour

// The tour's Cloud step: the two panes, a folder on its way across, and the services.
function tourCloudPreview() {
  const row = (ic, name, sub, dir) => h('div', { class: 'tp-row' }, h('span', { class: `ftile${dir ? ' dir' : ''}` }, icon(ic)),
    h('div', { class: 'fmeta' }, h('div', { class: 'fname' }, name), h('div', { class: 'fsub' }, sub)));
  const pane = (head, rows) => h('div', { class: 'card tp-pane' }, head, rows);
  return h('div', { class: 'tour-cloud' },
    h('div', { class: 'tp-panes' },
      pane(paneTitle(h('span', { class: 'pc-ic' }, icon('monitor')), pcName(), 'Downloads'),
        [row('folder', 'Client Footage 2026', 'Folder · 412 of 1180 files', true), row('film', 'Interview A-cam.mov', '18.4 GB')]),
      h('div', { class: 'tp-arrow' }, icon('left')),
      pane(paneTitle(serviceIcon('drive', 28), 'Google Drive', 'Shared with me'),
        [h('div', { class: 'tp-row' }, h('span', { class: 'avatar', style: { background: personColor('anika') } }, 'A'),
          h('div', { class: 'fmeta' }, h('div', { class: 'fname' }, 'anika@studio.com'), h('div', { class: 'fsub' }, '3 items shared with you'))),
        row('folder', 'Client Footage 2026', 'Folder', true)])),
    h('div', { class: 'tp-services' }, [['drive', 'Google Drive'], ['dropbox', 'Dropbox'], ['onedrive', 'OneDrive'], ['box', 'Box'], ['pcloud', 'pCloud']]
      .map(([t, n]) => h('span', { class: 'tp-svc' }, serviceIcon(t, 22), n))));
}
