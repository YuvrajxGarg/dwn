// "Choose a section" editor: preview, start/end cards with frames, and a
// filmstrip timeline with trim handles. Mirrors the macOS SectionEditorView.
'use strict';

function openSectionEditor(info, ctx) {
  const st = {
    preview: null, error: null, start: 0, end: info.duration || 0, edge: 'start', zoom: 1,
    playing: false, sb: null, strip: {}, edgeImg: {}, duration: info.duration || 0,
  };
  if (ctx.section && ctx.section.url === info.url) { st.start = ctx.section.start; st.end = ctx.section.end; }

  const video = h('video', { preload: 'auto', playsInline: true });
  const badge = h('div', { style: { position: 'absolute', top: '12px', left: '12px', padding: '5px 10px', borderRadius: '999px',
    background: 'rgba(0,0,0,.6)', font: '600 12px var(--font)', fontVariantNumeric: 'tabular-nums', display: 'flex', gap: '6px' } });
  const playBtn = h('button', { style: { position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%,-50%)', width: '54px', height: '54px',
    borderRadius: '50%', background: 'rgba(0,0,0,.55)', border: '1px solid rgba(255,255,255,.15)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center' } });
  const poster = info.thumbnail ? h('img', { src: info.thumbnail, style: { position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover', opacity: .85 } }) : null;
  const playerBox = h('div', { style: { position: 'relative', width: '520px', height: '292px', borderRadius: '14px', overflow: 'hidden', background: '#000', flex: 'none' },
    onclick: (e) => { if (st.preview && e.target !== playBtn && !playBtn.contains(e.target)) togglePlay(); } }, poster, video, badge, playBtn);
  Object.assign(video.style, { width: '100%', height: '100%', objectFit: 'contain', position: 'absolute', inset: 0 });

  const cards = h('div', { style: { flex: 1, display: 'flex', flexDirection: 'column', gap: '10px', justifyContent: 'center' } });
  const lengthInput = h('input', { class: 'mono', style: { width: '90px', textAlign: 'right', background: 'none', border: 0, outline: 0, font: '600 15px var(--font)', userSelect: 'text' },
    onkeydown: (e) => { if (e.key === 'Enter') { const v = parseTime(lengthInput.value); if (v > 0) { st.end = Math.min(st.duration, st.start + v); changed(); } lengthInput.blur(); } } });
  const ruler = h('div', { style: { position: 'relative', height: '20px' } });
  const track = h('div', { style: { position: 'relative', height: '62px' } });
  const inner = h('div', { style: { position: 'relative' } }, ruler, h('div', { style: { height: '8px' } }), track);
  const scroller = h('div', { style: { overflowX: 'hidden', overflowY: 'hidden', paddingTop: '6px' } }, inner);
  const tools = h('div', { style: { display: 'flex', gap: '8px', alignItems: 'center' } });
  const estimate = h('div', { class: 'faint mono', style: { fontSize: '12px', flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } });
  const dlBtn = h('button', { class: 'btn-primary', style: { width: '220px', height: '38px' }, onclick: download });

  const head = h('div', { style: { display: 'flex', alignItems: 'flex-start', padding: '22px 24px 18px' } },
    h('div', { style: { flex: 1, minWidth: 0 } }, h('h2', {}, 'Choose a section'),
      h('div', { class: 'faint', style: { marginTop: '4px', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } },
        [info.title, st.duration ? fmtTime(st.duration) : null].filter(Boolean).join(' · '))),
    h('button', { class: 'btn-icon', onclick: () => m.close() }, icon('x')));
  const body = h('div', {},
    head,
    h('div', { style: { display: 'flex', gap: '20px', padding: '0 24px', alignItems: 'center' } }, playerBox, cards),
    h('div', { style: { padding: '18px 24px 0' } }, scroller),
    h('div', { style: { padding: '14px 24px 18px' } }, tools),
    h('div', { style: { borderTop: '1px solid var(--stroke)', padding: '14px 24px', display: 'flex', gap: '10px', alignItems: 'center' } },
      estimate,
      h('button', { class: 'btn-quiet', style: { height: '38px' }, onclick: done }, icon('check'), 'Done'),
      dlBtn));
  const m = modal(body, { width: 940, onClose: () => { video.pause(); removeEventListener('keydown', onKey, true); } });

  // ---------- data ----------
  const trimmed = () => st.start > 0.05 || st.end < st.duration - 0.05;
  const length = () => Math.max(0, st.end - st.start);

  api('preview', { url: info.url }).then((p) => {
    st.preview = p;
    st.duration = p.duration || st.duration;
    if (!st.end) st.end = st.duration;
    video.src = p.stream;
    video.addEventListener('loadeddata', () => { if (poster) poster.remove(); }, { once: true });
    seek(st.start);
    renderAll();
    loadStrip();
    edgeFrames(true);
  }).catch((e) => { st.error = e.message; renderAll(); });

  api('storyboard', { url: info.url }).then((r) => {
    if (r.levels && r.levels.length) { st.sb = r.levels; renderTrack(); renderCards(); }
  }).catch(() => {});

  video.addEventListener('timeupdate', () => {
    if (st.playing && video.currentTime >= st.end - 0.03) { video.pause(); st.playing = false; video.currentTime = st.end; }
    renderBadge(); renderPlayhead();
  });
  video.addEventListener('pause', () => { st.playing = false; renderPlay(); });
  video.addEventListener('play', () => { st.playing = true; renderPlay(); });

  // ---------- storyboard sprites (CSS-cropped) ----------
  function spriteTile(t, large, w, hh) {
    if (!st.sb) return null;
    const lv = large ? st.sb[st.sb.length - 1] : st.sb[0];
    const sheet = [...lv.sheets].reverse().find((s) => s.start <= t) || lv.sheets[0];
    const per = lv.rows * lv.columns;
    const interval = lv.interval || sheet.duration / per;
    // The last sheet of a video is often only partly filled: fewer rows (or columns).
    const frames = Math.max(1, Math.min(per, Math.ceil(sheet.duration / Math.max(interval, 0.01))));
    const cols = Math.min(lv.columns, frames);
    const rows = Math.max(1, Math.ceil(frames / lv.columns));
    const idx = Math.max(0, Math.min(frames - 1, Math.floor((t - sheet.start) / Math.max(interval, 0.01))));
    const col = idx % lv.columns; const row = Math.floor(idx / lv.columns);
    return h('div', { style: { width: `${w}px`, height: `${hh}px`, flex: 'none',
      backgroundImage: `url("${fileURL(sheet.path)}")`, backgroundSize: `${cols * 100}% ${rows * 100}%`,
      backgroundPosition: `${cols > 1 ? (col / (cols - 1)) * 100 : 0}% ${rows > 1 ? (row / (rows - 1)) * 100 : 0}%` } });
  }

  // ---------- rendering ----------
  function renderAll() { renderBadge(); renderPlay(); renderCards(); renderTrack(); renderTools(); renderFooter(); }

  function renderBadge() {
    if (!st.preview) { badge.style.display = 'none'; return; }
    badge.style.display = 'flex';
    mount(badge, st.edge !== 'none' && !st.playing ? h('span', { style: { color: 'var(--text2)' } }, st.edge === 'start' ? 'Start' : 'End') : null,
      h('span', {}, fmtTime(video.currentTime || 0, true)));
  }
  function renderPlay() {
    playBtn.style.display = st.preview && !st.playing ? 'flex' : 'none';
    mount(playBtn, icon(st.playing ? 'pause' : 'play', 'lg'));
    playBtn.onclick = (e) => { e.stopPropagation(); togglePlay(); };
    if (st.error) {
      mount(playerBox, h('div', { style: { position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '8px', textAlign: 'center', padding: '20px' } },
        h('b', {}, 'Preview unavailable'), h('div', { class: 'faint' }, st.error)));
    }
  }
  function edgeCard(edge) {
    const t = edge === 'start' ? st.start : st.end - (edge === 'end' ? 0.1 : 0);
    const on = st.edge === edge;
    const img = st.edgeImg[edge] ? h('img', { class: 'loaded', src: st.edgeImg[edge], style: { width: '100%', height: '100%', objectFit: 'cover' } }) : spriteTile(Math.max(0, t), true, 104, 58);
    return h('div', { style: { display: 'flex', alignItems: 'center', gap: '14px', padding: '10px', borderRadius: '14px',
      background: `rgba(255,255,255,${on ? 0.07 : 0.04})`, boxShadow: on ? 'inset 0 0 0 1px rgba(255,255,255,.14)' : 'none' },
    onclick: () => { st.edge = edge; seek(edge === 'start' ? st.start : st.end); renderCards(); renderBadge(); } },
    h('div', { class: img ? 'thumb' : 'thumb shimmer', style: { width: '104px', height: '58px' } }, img),
    h('div', { style: { flex: 1 } },
      h('div', { style: { display: 'flex', gap: '6px', alignItems: 'center', fontSize: '12px', fontWeight: 600, color: on ? 'var(--text)' : 'var(--text2)' } }, icon('flag', 'sm'), edge === 'start' ? 'Start' : 'End'),
      h('div', { class: 'mono', style: { font: '600 22px var(--font)', marginTop: '3px' } }, fmtTime(edge === 'start' ? st.start : st.end, st.zoom > 2))),
    h('button', { class: 'btn-icon', title: 'Back a second (Alt: a tenth)', onclick: (e) => { e.stopPropagation(); nudge(edge, e.altKey ? -0.1 : -1); } }, icon('left')),
    h('button', { class: 'btn-icon', title: 'Forward a second (Alt: a tenth)', onclick: (e) => { e.stopPropagation(); nudge(edge, e.altKey ? 0.1 : 1); } }, icon('right')));
  }
  function renderCards() {
    if (document.activeElement !== lengthInput) lengthInput.value = fmtTime(length());
    mount(cards, edgeCard('start'), edgeCard('end'),
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px', height: '44px', padding: '0 14px', borderRadius: '14px', background: 'rgba(255,255,255,.04)' } },
        icon('timer'), h('span', { class: 'muted', style: { flex: 1, fontWeight: 500 } }, 'Length'), lengthInput));
  }

  function trackWidth() { return Math.max(400, (scroller.clientWidth || 892) * st.zoom); }
  const X = (t) => (t / Math.max(st.duration, 0.1)) * trackWidth();
  const T = (px) => Math.min(Math.max((px / trackWidth()) * st.duration, 0), st.duration);

  let playheadEl = null;
  function renderPlayhead() {
    if (playheadEl) playheadEl.style.left = `${X(video.currentTime || 0) - 4.5}px`;
  }
  function renderTrack() {
    const W = trackWidth();
    inner.style.width = `${W}px`;
    scroller.style.overflowX = st.zoom > 1 ? 'auto' : 'hidden';
    // ruler
    const steps = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600];
    const step = steps.find((s) => (s / Math.max(st.duration, 0.1)) * W >= 64) || 3600;
    const ticks = [];
    for (let t = 0; t <= st.duration + 0.001; t += step) {
      ticks.push(h('div', { class: 'mono', style: { position: 'absolute', left: `${X(t)}px`, fontSize: '10.5px', fontWeight: 500, color: 'var(--text3)' } },
        fmtTime(t, step < 1), h('div', { style: { width: '1px', height: '4px', background: 'rgba(255,255,255,.18)', marginTop: '3px' } })));
    }
    mount(ruler, ticks);
    // filmstrip
    const count = Math.max(6, Math.min(80, Math.floor(W / 92)));
    const tileW = W / count;
    const times = Array.from({ length: count }, (_, i) => Math.round(((i + 0.5) * st.duration / count) * 10) / 10);
    const strip = h('div', { style: { position: 'absolute', inset: 0, display: 'flex', borderRadius: '6px', overflow: 'hidden', background: 'rgba(255,255,255,.05)' } },
      times.map((t) => (st.strip[t.toFixed(1)]
        ? h('img', { src: fileURL(st.strip[t.toFixed(1)]), style: { width: `${tileW}px`, height: '62px', objectFit: 'cover', flex: 'none' } })
        : spriteTile(t, false, tileW, 62) || h('div', { class: 'shimmer', style: { width: `${tileW}px`, height: '62px', flex: 'none' } }))));
    const dimL = h('div', { style: { position: 'absolute', left: 0, top: 0, height: '62px', width: `${X(st.start)}px`, background: 'rgba(0,0,0,.6)', pointerEvents: 'none' } });
    const dimR = h('div', { style: { position: 'absolute', left: `${X(st.end)}px`, top: 0, height: '62px', right: 0, background: 'rgba(0,0,0,.6)', pointerEvents: 'none' } });
    const frame = h('div', { style: { position: 'absolute', left: `${X(st.start)}px`, top: '-2px', width: `${Math.max(24, X(st.end) - X(st.start))}px`, height: '66px',
      border: '3px solid #fff', borderRadius: '6px', cursor: 'grab' } });
    const handle = (edge) => h('div', { style: { position: 'absolute', top: '-2px', width: '12px', height: '66px', background: '#fff', borderRadius: '4px', cursor: 'ew-resize',
      left: `${edge === 'start' ? X(st.start) : X(st.end) - 12}px`, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '2px' } },
    h('i', { style: { width: '1.5px', height: '14px', background: 'rgba(0,0,0,.35)', borderRadius: '1px' } }),
    h('i', { style: { width: '1.5px', height: '14px', background: 'rgba(0,0,0,.35)', borderRadius: '1px' } }));
    const hs = handle('start'); const he = handle('end');
    playheadEl = h('div', { style: { position: 'absolute', top: '-8px', width: '9px', pointerEvents: 'none', display: 'flex', flexDirection: 'column', alignItems: 'center' } },
      h('div', { style: { width: '9px', height: '9px', borderRadius: '50%', background: 'var(--accent)' } }),
      h('div', { style: { width: '2px', height: '66px', background: 'var(--accent)' } }));
    const chapters = ((st.preview && st.preview.chapters) || info.chapters || []).filter((c) => c.start > 0)
      .map((c) => h('div', { style: { position: 'absolute', left: `${X(c.start)}px`, top: '52px', width: '1px', height: '10px', background: 'rgba(255,255,255,.5)', pointerEvents: 'none' } }));
    mount(track, strip, dimL, dimR, ...chapters, frame, hs, he, playheadEl);
    renderPlayhead();

    const rel = (e) => e.clientX - track.getBoundingClientRect().left;
    drag(strip, (e) => { st.edge = 'none'; seek(T(rel(e)), false); renderBadge(); renderCards(); });
    drag(hs, (e) => { st.start = Math.min(T(rel(e)), st.end - 0.1); st.edge = 'start'; seek(st.start, false); changed(true); });
    drag(he, (e) => { st.end = Math.max(T(rel(e)), st.start + 0.1); st.edge = 'end'; seek(st.end, false); changed(true); });
    let origin = null;
    drag(frame, (e, phase, startEv) => {
      if (phase === 'start') origin = [st.start, st.end, rel(startEv)];
      const len = origin[1] - origin[0];
      const ns = Math.min(Math.max(0, origin[0] + ((rel(e) - origin[2]) / trackWidth()) * st.duration), st.duration - len);
      st.start = ns; st.end = ns + len; st.edge = 'start'; seek(ns, false); changed(true);
    });
  }
  // Pointer drag helper; re-renders happen on the fly so handles stay under the pointer.
  function drag(el, onMove) {
    el.addEventListener('pointerdown', (e) => {
      e.preventDefault(); e.stopPropagation();
      const startEv = e;
      onMove(e, 'start', startEv);
      const move = (ev) => onMove(ev, 'move', startEv);
      const up = () => { removeEventListener('pointermove', move); removeEventListener('pointerup', up); edgeFrames(true); };
      addEventListener('pointermove', move); addEventListener('pointerup', up);
    });
  }

  function renderTools() {
    const tool = (ic, label, onclick, title) => h('button', { class: 'btn-quiet', style: { height: '34px' }, title, onclick }, icon(ic, 'sm'), label);
    const lengths = [[5, '5 seconds'], [10, '10 seconds'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute'], [120, '2 minutes']];
    const kids = [
      h('label', { class: 'btn-quiet', style: { height: '34px', position: 'relative' }, title: 'Make the section that long, from the start' },
        icon('timer', 'sm'), trimmed() ? fmtTime(length()) : 'Length',
        h('select', { style: { position: 'absolute', inset: 0, opacity: 0 }, onchange: (e) => setLength(Number(e.target.value)) },
          h('option', { value: '', disabled: true, selected: true }, 'Length'), lengths.map(([v, n]) => h('option', { value: v }, n)))),
    ];
    const chapters = ((st.preview && st.preview.chapters) || info.chapters || []).filter((c) => c.start != null);
    if (chapters.length) {
      kids.push(h('label', { class: 'btn-quiet', style: { height: '34px', position: 'relative' } }, icon('list', 'sm'), 'Chapters', icon('chev', 'sm'),
        h('select', { style: { position: 'absolute', inset: 0, opacity: 0 }, onchange: (e) => {
          const c = chapters[Number(e.target.value)];
          st.start = c.start || 0; st.end = Math.min(st.duration, c.end || st.duration); st.edge = 'start'; seek(st.start); changed();
        } }, h('option', { value: '', disabled: true, selected: true }, 'Chapters'),
        chapters.map((c, i) => h('option', { value: i }, `${fmtTime(c.start)}  ${c.title || 'Chapter'}`)))));
    }
    const heat = ((st.preview && st.preview.heatmap) || info.heatmap || []).filter((x) => x.value != null);
    if (heat.length) {
      const peak = heat.reduce((a, b) => (b.value > a.value ? b : a));
      const mid = (peak.start + (peak.end || peak.start)) / 2;
      kids.push(tool('flame', 'Most replayed', () => { st.start = Math.max(0, mid - 10); st.end = Math.min(st.duration, mid + 20); st.edge = 'start'; seek(st.start); changed(); },
        'Jump to the part people replay most'));
    }
    if (trimmed()) kids.push(tool('undo', 'Reset', () => { st.start = 0; st.end = st.duration; st.edge = 'start'; seek(0); changed(); }));
    const maxZoom = Math.max(1, Math.min(32, st.duration / 8));
    kids.push(h('div', { style: { flex: 1 } }),
      h('div', { class: 'fill', style: { display: 'flex', padding: '3px', gap: '2px' } },
        h('button', { class: 'btn-icon', title: 'Zoom out', disabled: st.zoom <= 1, onclick: () => { st.zoom = Math.max(1, st.zoom / 2); renderTrack(); renderTools(); loadStrip(); } }, icon('zout')),
        h('button', { class: 'btn-icon', title: 'Zoom in', disabled: st.zoom >= maxZoom, onclick: () => {
          st.zoom = Math.min(maxZoom, st.zoom * 2); renderTrack(); renderTools(); loadStrip();
          scroller.scrollLeft = X(st.start) - 40;
        } }, icon('zin'))));
    mount(tools, kids);
  }

  function renderFooter() {
    mount(dlBtn, icon('down'), trimmed() ? 'Download section' : 'Download whole video');
    const p = st.preview;
    if (!p) { estimate.textContent = st.error ? '' : 'Getting video details…'; return; }
    const len = length() || st.duration;
    const prefs = ctx.prefs();
    const parts = [];
    let bytes = 0; let convert = 0;
    const src = (p.video_bps || 0) + (p.audio_bps || 0);
    if (ctx.tab() === 'audio') {
      parts.push(formatName(prefs.audio_format));
      bytes = prefs.audio_format === 'mp3' ? 40000 * len : prefs.audio_format === 'wav' ? 176400 * len : (p.audio_bps || 16000) * len;
    } else {
      const codec = prefs.video_format;
      parts.push(CODEC_SHORT[codec] || codec);
      const hgt = p.height || 720;
      if (p.height) parts.push(`${p.height}p`);
      bytes = src * len;
      const avc = String(p.vcodec || '').startsWith('avc');
      if (codec === 'hevc') { bytes *= 0.7; convert = len * hgt / 1080 * 0.6; }
      if (codec === 'prores') { bytes = 27.5e6 * (hgt / 1080) ** 2 * len; convert = len * hgt / 1080 * 0.4; }
      if (codec === 'h264' && !avc) convert = len * hgt / 1080 * 0.5;
    }
    if (bytes > 0) {
      parts.push(`≈ ${fmtBytes(bytes)}`);
      const secs = src * len / 6e6 + convert + 2;
      parts.push(`ready in about ${secs < 60 ? `${Math.round(secs)} s` : `${Math.round(secs / 60)} min`}`);
    }
    estimate.textContent = parts.join(' · ');
  }

  // ---------- actions ----------
  function seek(t, exact = true) {
    if (!st.preview) return;
    try { if (exact || !video.fastSeek) video.currentTime = t; else video.fastSeek(t); } catch {}
    renderBadge(); renderPlayhead();
  }
  function togglePlay() {
    if (st.playing) { video.pause(); return; }
    if (video.currentTime < st.start || video.currentTime >= st.end - 0.1) video.currentTime = st.start;
    video.play().catch(() => {});
  }
  function nudge(edge, step) {
    st.edge = edge;
    if (edge === 'start') { st.start = Math.min(Math.max(0, st.start + step), st.end - 0.1); seek(st.start); }
    else { st.end = Math.max(Math.min(st.duration, st.end + step), st.start + 0.1); seek(st.end); }
    changed();
  }
  function setLength(s) {
    st.end = Math.min(st.duration, st.start + s);
    if (st.end - st.start < s) st.start = Math.max(0, st.end - s);
    st.edge = 'end'; seek(st.end); changed();
  }
  let edgeTimer = null;
  function changed(dragging) {
    renderCards(); renderTrack(); renderTools(); renderFooter(); renderBadge();
    if (!dragging) edgeFrames(true);
  }
  function edgeFrames(now) {
    clearTimeout(edgeTimer);
    st.edgeImg = {};
    renderCards();
    edgeTimer = setTimeout(async () => {
      if (!st.preview) return;
      const s = Math.round(st.start * 10) / 10; const e = Math.round(Math.max(st.start, st.end - 0.1) * 10) / 10;
      try {
        const r = await api('frames', { url: info.url, times: [s, e], width: 320 });
        if (r.frames[s.toFixed(1)]) st.edgeImg.start = fileURL(r.frames[s.toFixed(1)]);
        if (r.frames[e.toFixed(1)]) st.edgeImg.end = fileURL(r.frames[e.toFixed(1)]);
        renderCards();
      } catch {}
    }, now ? 220 : 400);
  }
  async function loadStrip() {
    if (!st.preview || !st.duration) return;
    const W = trackWidth();
    const count = Math.max(6, Math.min(80, Math.floor(W / 92)));
    const times = Array.from({ length: count }, (_, i) => Math.round(((i + 0.5) * st.duration / count) * 10) / 10);
    try {
      const r = await api('frames', { url: info.url, times, width: 192 });
      Object.assign(st.strip, r.frames);
      renderTrack();
    } catch {}
  }
  function done() {
    ctx.onDone(trimmed() ? { url: info.url, start: st.start, end: st.end } : null);
    m.close();
  }
  function download() {
    const kind = ctx.tab() === 'audio' ? 'audio' : 'video';
    const cut = trimmed();
    ctx.onDownload(kind, cut ? st.start : null, cut ? st.end : null);
    m.close();
  }
  function onKey(e) {
    if (document.activeElement === lengthInput) return;
    if (e.key === ' ') { e.preventDefault(); togglePlay(); }
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      e.preventDefault();
      const step = (e.key === 'ArrowLeft' ? -1 : 1) * (e.altKey ? 0.1 : 1);
      if (st.edge === 'none') seek(Math.min(Math.max(0, (video.currentTime || 0) + step), st.duration));
      else nudge(st.edge, step);
    } else if (e.key === 'Enter') { e.preventDefault(); download(); }
  }
  addEventListener('keydown', onKey, true);
  requestAnimationFrame(renderAll);
}
