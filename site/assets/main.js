// Dwn site: platform-aware download buttons from the latest GitHub release,
// the Links/Cloud screenshot switch, and scroll reveals.
(() => {
  const REPO = "YuvrajxGarg/dwn";
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  requestAnimationFrame(() => document.body.classList.add("ready"));

  // ---------------------------------------------------------------- nav border on scroll
  const nav = $("#nav");
  const onScroll = () => nav && nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // ---------------------------------------------------------------- platform
  const ua = navigator.userAgent;
  const plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  const isWin = /win/i.test(plat) || /Windows/.test(ua);
  const isMac = !isWin && (/mac/i.test(plat) || /Mac OS X/.test(ua)) && !/iPhone|iPad/.test(ua);

  const main = $("#cta-main"), alt = $("#cta-alt");
  const setBtn = (el, icon, label, href) => {
    if (!el) return;
    el.querySelector("use").setAttribute("href", icon);
    el.querySelector("span").textContent = label;
    if (href) el.href = href;
  };
  if (isWin) {
    setBtn(main, "#windows", "Download for Windows", "https://github.com/" + REPO + "/releases/latest");
    setBtn(alt, "#apple", "Mac", "#download");
  }
  const current = $(`.platform[data-platform="${isWin ? "windows" : isMac ? "mac" : ""}"]`);
  if (current) {
    current.classList.add("current");
    const b = current.querySelector(".btn");
    b.classList.replace("btn-quiet", "btn-primary");
    const other = $$(".platform").find((p) => p !== current);
    other && other.querySelector(".btn").classList.replace("btn-primary", "btn-quiet");
  }

  // ---------------------------------------------------------------- latest release
  const size = (b) => (b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : Math.round(b / 1e6) + " MB");
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((rel) => {
      const v = (rel.tag_name || "").replace(/^v/, "");
      if (v) $$("[data-version]").forEach((el) => (el.textContent = "Version " + v));
      const notes = $("[data-notes]");
      if (notes && rel.html_url) notes.href = rel.html_url;
      const assets = rel.assets || [];
      // The disk image when the release has one, the zip for older releases.
      const dmg = assets.find((a) => a.name === "Dwn.dmg");
      const mac = dmg || assets.find((a) => a.name === "Dwn-mac.zip");
      const win = assets.find((a) => /^Dwn-Setup-.*\.exe$/.test(a.name));
      if (mac) {
        $$('[data-dl="mac"]').forEach((el) => (el.href = mac.browser_download_url));
        $$('[data-size="mac"]').forEach((el) => (el.textContent = size(mac.size)));
        if (!isWin) main.href = mac.browser_download_url;
      }
      if (dmg) {
        $$('[data-note="mac"]').forEach((el) => (el.innerHTML = "Open it and drag <b>Dwn</b> to Applications. The first time, right-click it and choose <b>Open</b>."));
      }
      if (win) {
        $$('[data-dl="windows"]').forEach((el) => (el.href = win.browser_download_url));
        $$('[data-size="windows"]').forEach((el) => (el.textContent = size(win.size)));
        if (isWin) main.href = win.browser_download_url;
      }
    })
    .catch(() => { /* static links still work */ });

  // ---------------------------------------------------------------- screenshot switch
  const sw = $(".switch");
  if (sw) {
    const thumb = $(".thumb", sw);
    const tabs = $$("button", sw);
    const shots = $$(".window img[data-shot]");
    const caption = $("[data-caption]");
    const captions = {
      links: "Paste a link, pick a format, done.",
      cloud: "Your Mac and Google Drive side by side. Drag whole folders either way.",
    };
    const place = (btn) => {
      thumb.style.width = btn.offsetWidth + "px";
      thumb.style.transform = `translateX(${btn.offsetLeft - 3}px)`;
    };
    const select = (btn) => {
      tabs.forEach((t) => t.setAttribute("aria-selected", String(t === btn)));
      const id = btn.dataset.shot;
      shots.forEach((img) => (img.hidden = img.dataset.shot !== id));
      if (caption) caption.textContent = captions[id] || "";
      place(btn);
    };
    tabs.forEach((t) => t.addEventListener("click", () => select(t)));
    place(tabs[0]);
    addEventListener("resize", () => place($('[aria-selected="true"]', sw)));
    document.fonts && document.fonts.ready.then(() => place($('[aria-selected="true"]', sw)));
  }

  // ---------------------------------------------------------------- reveals
  const items = $$(".reveal");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    items.forEach((el, i) => { el.style.transitionDelay = (i % 3) * 60 + "ms"; io.observe(el); });
  } else {
    items.forEach((el) => el.classList.add("in"));
  }
})();
