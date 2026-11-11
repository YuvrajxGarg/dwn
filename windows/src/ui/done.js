// "Download complete" panel: shown in a screen corner when a download
// finishes while Dwn's window isn't in front. Newest first, several stack.
'use strict';

const root = $('#done');
const HIDE_AFTER = 8000;
let items = [];
let platform = 'win32';
let hover = false;
let timer = null;

invoke('app:platform').then((p) => { platform = p; render(); });

window.dwn.onDone((list) => {
  items = list || [];
  render();
  restartTimer();
  // Main shows the panel once it knows its height. Measured right away: a
  // hidden window gets no animation frames or resize callbacks.
  reportSize();
});

function reportSize() {
  if (items.length) invoke('done:size', Math.ceil(root.getBoundingClientRect().height));
}

// Auto-hide, paused while the pointer is over the panel.
function restartTimer() {
  clearTimeout(timer);
  if (hover || !items.length) return;
  timer = setTimeout(() => invoke('done:hide'), HIDE_AFTER);
}
document.documentElement.addEventListener('mouseenter', () => { hover = true; clearTimeout(timer); });
document.documentElement.addEventListener('mouseleave', () => { hover = false; restartTimer(); });

new ResizeObserver(reportSize).observe(root);

function fileArt(it) {
  if (it.thumbnail) {
    const img = h('img', { src: it.thumbnail, draggable: false });
    img.addEventListener('error', () => { img.replaceWith(it.icon ? h('img', { class: 'icon', src: it.icon, draggable: false }) : icon(it.is_dir ? 'folder' : 'file')); });
    return h('div', { class: 'dn-art wide' }, img);
  }
  if (it.icon) return h('div', { class: 'dn-art' }, h('img', { class: 'icon', src: it.icon, draggable: false }));
  return h('div', { class: 'dn-art' }, icon(it.is_dir ? 'folder' : 'file'));
}

function card(it) {
  const reveal = platform === 'darwin' ? 'Show in Finder' : 'Show in Explorer';
  const detail = [it.title !== it.name ? it.name : null, it.size ? fmtBytes(it.size) : null,
    it.is_dir && it.files > 1 ? `${it.files} files` : null].filter(Boolean).join(' · ') || (it.is_dir ? 'Folder' : '');
  const file = h('div', {
    class: 'dn-file', draggable: 'true', title: 'Drag into another app',
    ondragstart: (e) => { e.preventDefault(); window.dwn.startDrag(it.file); },
  }, fileArt(it), h('div', { class: 'dn-meta' }, h('b', {}, it.title), h('span', {}, detail)));
  const done = (fn) => async () => {
    const r = await fn();
    if (r && r.error) return;
    invoke('done:remove', it.id);
  };
  return h('div', { class: 'dn' },
    h('div', { class: 'dn-head' },
      h('span', { class: 'ok' }, icon('check'), it.cloud ? 'Downloaded from the cloud' : 'Downloaded'),
      h('button', { class: 'btn-icon x', title: 'Close', onclick: () => invoke('done:remove', it.id) }, icon('x', 'sm'))),
    file,
    h('div', { class: 'dn-acts' },
      h('button', { class: 'btn-primary', onclick: done(() => invoke('shell:open', it.file)) }, 'Open'),
      h('button', { class: 'btn-quiet', onclick: done(() => invoke('shell:reveal', it.file)) }, reveal)));
}

function render() {
  mount(root, items.map(card));
}
