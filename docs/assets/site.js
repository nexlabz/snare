/* site.js — shared behaviour for every page.
   Kept dependency-free and defensive: each block no-ops when its markup is absent,
   so one file can serve pages that share only the nav and the footer. */
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------------------------------------------------------- theme
     Dark by default. A click pins an explicit choice, which the inline
     <head> snippet re-applies on the next page load before paint. */
  var themeBtn = document.querySelector(".theme-toggle");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var root = document.documentElement;
      var isDark = (root.dataset.theme || "dark") === "dark";
      var next = isDark ? "light" : "dark";
      root.dataset.theme = next;
      themeBtn.setAttribute("aria-label", next === "dark" ? "Switch to light theme" : "Switch to dark theme");
      try { localStorage.setItem("snare-theme", next); } catch (e) { /* private mode */ }
      setGiscusTheme(next);
    });
  }

  /* ------------------------------------------------------------------ giscus
     Comments are GitHub Discussions. The third-party script is injected only
     where a #giscus-mount exists — this is the single page that carries it, so
     no page with a copy-and-paste shell command runs foreign code. If it does
     not load, the fallback keeps a working link to the same thread. */
  function currentTheme() {
    var pinned = document.documentElement.dataset.theme;
    return pinned || "dark";
  }

  function setGiscusTheme(theme) {
    var frame = document.querySelector("iframe.giscus-frame");
    if (!frame || !frame.contentWindow) return;
    frame.contentWindow.postMessage(
      { giscus: { setConfig: { theme: theme } } },
      "https://giscus.app"
    );
  }

  var mount = document.getElementById("giscus-mount");
  if (mount) {
    var fallback = document.getElementById("giscus-fallback");
    var discussionsUrl = "https://github.com/" + mount.dataset.repo + "/discussions";

    var errored = false;

    var failed = function (why) {
      errored = true;
      if (!fallback) return;
      fallback.innerHTML = "The comment widget did not load (" + why + "). The thread is on " +
        '<a href="' + discussionsUrl + '">GitHub Discussions</a> — nothing is lost.';
    };

    // once the widget is up and has not complained, the loading note is noise
    var settle = function () {
      if (errored || !fallback) return;
      if (mount.querySelector("iframe.giscus-frame")) fallback.hidden = true;
    };

    var s = document.createElement("script");
    s.src = "https://giscus.app/client.js";
    s.async = true;
    s.crossOrigin = "anonymous";
    s.setAttribute("data-repo", mount.dataset.repo);
    s.setAttribute("data-repo-id", mount.dataset.repoId);
    s.setAttribute("data-category", mount.dataset.category);
    s.setAttribute("data-category-id", mount.dataset.categoryId);
    s.setAttribute("data-mapping", "pathname");
    s.setAttribute("data-strict", "1");
    s.setAttribute("data-reactions-enabled", "1");
    s.setAttribute("data-emit-metadata", "0");
    s.setAttribute("data-input-position", "top");
    s.setAttribute("data-theme", currentTheme());
    s.setAttribute("data-lang", "en");
    s.setAttribute("data-loading", "lazy");
    s.onerror = function () { failed("blocked or offline"); };
    mount.appendChild(s);

    // giscus reports its own problems (app not installed, discussions disabled)
    window.addEventListener("message", function (e) {
      if (e.origin !== "https://giscus.app") return;
      var d = e.data && e.data.giscus;
      if (d && d.error) failed(String(d.error));
    });

    // give giscus a moment to report a problem, then either clear the note or
    // say plainly that nothing arrived at all
    setTimeout(settle, 2500);
    setTimeout(function () {
      if (!mount.querySelector("iframe.giscus-frame")) failed("no response from giscus.app");
      else settle();
    }, 8000);
  }

  /* --------------------------------------------------- legacy hash redirect
     The site has been one long page before, so links like /snare/#infected
     are published in GitHub issues, threads and articles. Forward them. */
  var MOVED = {
    "#detect": "check.html", "#check": "check.html", "#install": "install.html",
    "#infected": "infected.html", "#commands": "docs.html#reference",
    "#security": "security.html", "#changelog": "changelog.html",
    "#community": "community.html", "#docs": "docs.html",
    "#attack": "attack.html", "#threat": "attack.html#threat",
    "#mechanism": "attack.html#mechanism", "#reports": "attack.html#reports"
  };
  if (document.body.dataset.page === "index" && MOVED[location.hash]) {
    location.replace(MOVED[location.hash]);
    return;
  }

  /* -------------------------------------------------------------- menu
     Below the breakpoint the primary links become a drawer. Escape closes it
     and returns focus to the button. */
  var navBtn = document.querySelector(".nav-toggle"),
      navEl = document.getElementById("bar-nav");
  if (navBtn && navEl) {
    var setMenu = function (open) {
      navEl.dataset.open = String(open);
      navBtn.setAttribute("aria-expanded", String(open));
      navBtn.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    };
    setMenu(false);
    navBtn.addEventListener("click", function () { setMenu(navEl.dataset.open !== "true"); });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && navEl.dataset.open === "true") { setMenu(false); navBtn.focus(); }
    });
    document.addEventListener("click", function (e) {
      if (navEl.dataset.open === "true" && !navEl.contains(e.target) && !navBtn.contains(e.target)) setMenu(false);
    });
  }

  /* ------------------------------------------------- hero whitespace reveal */
  var code = document.getElementById("code");
  if (code) {
    var GAP = 9000,
        LEADIN = "};",
        // the demo payload is stored reversed, so this file carries no live campaign marker
        payload = "/* detacnurt */ …\"ipa/moc.tuocskcolb.hte//:sptth\"=I,)(esaCrewoLot.\"a1fE0942CDa9e3601210f6e0803D113D3f5E223ax0\"=S,)\"ssecorp_dlihc\"(eriuqer=}nwaps{,)\"ptth\"(eriuqer=ptth tsnoc;eriuqer=r.labolg;\"…-8A\"=i.labolg".split("").reverse().join(""),
        lines = [["1", "module.exports = {"], ["2", "  plugins: {"], ["3", "    '@tailwindcss/postcss': {},"], ["4", "  },"]],
        revealBtn = document.getElementById("reveal"),
        scroller = document.getElementById("scroller"),
        hint = document.getElementById("hint"),
        on = false;

    var esc = function (s) {
      return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    };

    var render = function () {
      var h = "";
      lines.forEach(function (l) {
        h += '<span class="gutter">' + l[0] + '  </span>' + esc(l[1]) + "\n";
      });
      var gap = new Array(GAP + 1).join(on ? "·" : " ");
      h += '<span class="gutter">5  </span>' + esc(LEADIN)
         + '<span class="' + (on ? "ws" : "hidden-ws") + '">' + gap + "</span>"
         + '<span class="payload">' + esc(payload) + "</span>\n"
         + '<span class="gutter">6  </span>';
      code.innerHTML = h;
    };

    if (revealBtn) {
      revealBtn.addEventListener("click", function () {
        on = !on;
        revealBtn.setAttribute("aria-pressed", String(on));
        revealBtn.textContent = on ? "hide whitespace" : "reveal whitespace";
        render();
        if (on) {
          hint.textContent = "Every dot is one space the attacker used to push the payload off-screen.";
          scroller.scrollTo({ left: scroller.scrollWidth, behavior: reduce ? "auto" : "smooth" });
        } else {
          hint.textContent = "Line 5 is 9,135 characters long. Scroll it sideways — or reveal the whitespace.";
          scroller.scrollTo({ left: 0, behavior: "auto" });
        }
      });
    }
    render();
  }

  /* ------------------------------------------ copy buttons on code panels */
  var ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="9" rx="1.5"/><path d="M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h1"/></svg>';
  // swapped in on success — the polyline is what the tick animation draws
  var TICK = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3,8.5 6.5,12 13,4.5"/></svg>';

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.cssText = "position:absolute;left:-9999px;top:0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy") ? resolve() : reject(); }
      catch (e) { reject(e); }
      finally { document.body.removeChild(ta); }
    });
  }

  document.querySelectorAll(".panel").forEach(function (panel) {
    var pre = panel.querySelector("pre");
    if (!pre || pre.id === "code") return;   // the hero specimen is not copyable code

    var bar = panel.querySelector(".panel-bar");
    if (!bar) {
      bar = document.createElement("div");
      bar.className = "panel-bar";
      bar.innerHTML = '<span class="label">shell</span><div class="bar-actions"></div>';
      panel.insertBefore(bar, panel.firstChild);
    }
    var actions = bar.querySelector(".bar-actions");
    if (!actions) {
      actions = document.createElement("div");
      actions.className = "bar-actions";
      bar.appendChild(actions);
    }

    var b = document.createElement("button");
    b.className = "btn";
    b.type = "button";
    b.innerHTML = ICON + "<span>copy</span>";
    b.setAttribute("aria-label", "Copy this command");
    b.addEventListener("click", function () {
      copyText(pre.innerText).then(function () {
        b.classList.add("done");
        b.innerHTML = TICK + "<span>copied</span>";
        setTimeout(function () {
          b.classList.remove("done");
          b.innerHTML = ICON + "<span>copy</span>";
        }, 1600);
      }).catch(function () {
        b.innerHTML = ICON + "<span>select all</span>";
        var r = document.createRange(); r.selectNodeContents(pre);
        var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
      });
    });
    actions.appendChild(b);
  });

  /* ---------------------------------------------------------- platform tabs
     Remembers the platform across pages — someone who picked Windows on the
     install page should not have to pick it again. */
  var tabs = Array.prototype.slice.call(document.querySelectorAll(".tab"));
  if (tabs.length) {
    var panes = tabs.map(function (t) { return t.dataset.p; });

    var selectTab = function (t, remember) {
      tabs.forEach(function (x) {
        var isOn = x === t;
        x.setAttribute("aria-selected", String(isOn));
        x.tabIndex = isOn ? 0 : -1;
      });
      panes.forEach(function (p) {
        var pane = document.getElementById("p-" + p);
        if (pane) pane.hidden = (p !== t.dataset.p);
      });
      if (remember) {
        try { localStorage.setItem("snare-platform", t.dataset.p); } catch (e) { /* private mode */ }
      }
    };

    tabs.forEach(function (t, i) {
      t.tabIndex = t.getAttribute("aria-selected") === "true" ? 0 : -1;
      t.addEventListener("click", function () { selectTab(t, true); });
      t.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 :
                e.key === "Home" ? -i : e.key === "End" ? tabs.length - 1 - i : 0;
        if (!d) return;
        e.preventDefault();
        var next = tabs[(i + d + tabs.length) % tabs.length];
        selectTab(next, true);
        next.focus();
      });
    });

    var saved = null;
    try { saved = localStorage.getItem("snare-platform"); } catch (e) { /* private mode */ }
    if (saved) {
      var match = tabs.filter(function (t) { return t.dataset.p === saved; })[0];
      if (match) selectTab(match, false);
    }
  }

  /* ------------------------------------------------------------------ rail
     Shows where you are on the one long page and how much is left: the
     current chapter, a progress bar per chapter, and minutes remaining,
     estimated from each chapter's reading time. Below the wide breakpoint
     the rail collapses to a strip; tapping it opens the full list. */
  var rail = document.getElementById("rail");
  var chapters = Array.prototype.slice.call(document.querySelectorAll(".chapter"));
  if (rail && chapters.length) {
    var links = Array.prototype.slice.call(rail.querySelectorAll(".rail-list a"));
    var nowBtn = rail.querySelector(".rail-now"),
        nowN = document.getElementById("rail-n"),
        nowT = document.getElementById("rail-t"),
        nowLeft = document.getElementById("rail-left"),
        nowBar = document.getElementById("rail-bar");
    var minsOf = chapters.map(function (c) { return +c.dataset.min || 1; });
    var current = -1, ticking = false;

    var setOpen = function (open) {
      rail.dataset.open = String(open);
      nowBtn.setAttribute("aria-expanded", String(open));
    };
    if (nowBtn) {
      setOpen(false);
      nowBtn.addEventListener("click", function () { setOpen(rail.dataset.open !== "true"); });
      rail.addEventListener("click", function (e) { if (e.target.closest(".rail-list a")) setOpen(false); });
      document.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && rail.dataset.open === "true") { setOpen(false); nowBtn.focus(); }
      });
    }

    var update = function () {
      ticking = false;
      var line = window.innerHeight * 0.35, idx = 0, left = 0;
      chapters.forEach(function (c, i) {
        var r = c.getBoundingClientRect();
        if (r.top <= line) idx = i;
        // fraction of this chapter scrolled past the reading line
        var p = Math.min(1, Math.max(0, (line - r.top) / Math.max(1, r.height)));
        links[i] && links[i].style.setProperty("--p", p.toFixed(3));
        links[i] && links[i].classList.toggle("done", p >= 1);
        left += minsOf[i] * (1 - p);
      });
      if (chapters[0].getBoundingClientRect().top > line) idx = -1;
      var total = minsOf.reduce(function (a, b) { return a + b; }, 0);
      if (nowBar) nowBar.style.setProperty("--p", (1 - left / total).toFixed(3));
      if (nowLeft) nowLeft.textContent = Math.max(0, Math.round(left)) + " min left";
      if (idx !== current) {
        current = idx;
        links.forEach(function (a, i) {
          if (i === idx) a.setAttribute("aria-current", "true"); else a.removeAttribute("aria-current");
        });
        var shown = Math.max(0, idx);
        if (nowN) nowN.textContent = links[shown].querySelector(".rl-n").textContent;
        if (nowT) nowT.textContent = links[shown].querySelector(".rl-t").textContent;
      }
    };
    var onScroll = function () {
      if (!ticking) { ticking = true; requestAnimationFrame(update); }
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    update();
  }
  /* ------------------------------------------------------- changelog filter
     Each release groups its notes under headings that start with the kind of
     change (Fixed, Added, Changed...). Buttons appear only for the
     Keep a Changelog kinds that actually occur; free-form headings
     ("Measured", "Known issues") show under All. Older
     releases are folded; filtering opens them, since hiding matches inside a
     closed fold would read as "nothing found". */
  var filter = document.getElementById("rel-filter");
  if (filter) {
    var KINDS = ["Fixed", "Added", "Changed", "Removed", "Security"];
    var groups = Array.prototype.slice.call(document.querySelectorAll(".rel-group"));
    var kindOf = function (g) {
      var h = g.querySelector("h3,h4");
      var k = h ? h.textContent.trim().split(/[\s—–,:-]+/)[0] : "";
      return KINDS.indexOf(k) >= 0 ? k : "Other";
    };
    var kinds = [];
    groups.forEach(function (g) { var k = kindOf(g); if (k !== "Other" && kinds.indexOf(k) < 0) kinds.push(k); });
    kinds.sort(function (a, b) { return KINDS.indexOf(a) - KINDS.indexOf(b); });
    var buttons = [];
    var apply = function (kind) {
      buttons.forEach(function (b) { b.setAttribute("aria-pressed", String(b.dataset.k === kind)); });
      groups.forEach(function (g) { g.hidden = kind !== "All" && kindOf(g) !== kind; });
      document.querySelectorAll(".rel").forEach(function (r) {
        var any = Array.prototype.some.call(r.querySelectorAll(".rel-group"), function (g) { return !g.hidden; });
        r.closest("section").hidden = !any;
      });
      var older = document.querySelector("details.older");
      if (older && kind !== "All") older.open = true;
    };
    ["All"].concat(kinds).forEach(function (k) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "btn"; b.dataset.k = k; b.textContent = k;
      b.addEventListener("click", function () { apply(k); });
      filter.appendChild(b); buttons.push(b);
    });
    filter.hidden = false;
    apply("All");
  }
  /* ------------------------------------------------------------ report form
     Builds the issue text and hands it to GitHub's new-issue page. There is
     no backend: nothing leaves the browser until the reader submits on
     GitHub, where they can still edit or abandon it. */
  var form = document.getElementById("report-form");
  if (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var f = form.elements, msg = document.getElementById("rf-msg");
      var what = f.what.value.trim();
      if (!what) {
        f.what.setAttribute("aria-invalid", "true");
        msg.textContent = "Say what happened first. One sentence is enough.";
        f.what.focus();
        return;
      }
      f.what.removeAttribute("aria-invalid");
      var first = what.split(/\n/)[0].slice(0, 70);
      var body = "## What happened\n" + what +
        "\n\n## Version\n" + (f.version.value.trim() || "(not given)") +
        "\n\n## System\n" + f.os.value +
        "\n\n## snare selftest\n" + (f.selftest.checked ? "passes" : "not run, or failing") + "\n";
      var url = "https://github.com/nexlabz/snare/issues/new?title=" +
        encodeURIComponent(f.kind.value + ": " + first) + "&body=" + encodeURIComponent(body);
      window.open(url, "_blank", "noopener");
      msg.textContent = "Opened GitHub in a new tab. Check the text, then press Submit there.";
    });
  }
})();
