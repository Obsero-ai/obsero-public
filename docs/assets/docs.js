/* Docs chrome: nav drawer, copy buttons, cross-page search, scrollspy.
   No dependencies. Every feature degrades to plain HTML if this never runs. */
(function () {
  "use strict";

  // --- mobile nav drawer ---------------------------------------------------

  var toggle = document.getElementById("nav-toggle");
  var scrim = document.querySelector(".scrim");

  function setNav(open) {
    document.body.classList.toggle("nav-open", open);
    if (toggle) toggle.setAttribute("aria-expanded", String(open));
  }
  if (toggle) toggle.addEventListener("click", function () {
    setNav(!document.body.classList.contains("nav-open"));
  });
  if (scrim) scrim.addEventListener("click", function () { setNav(false); });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") setNav(false);
  });

  // --- copy buttons --------------------------------------------------------

  Array.prototype.forEach.call(document.querySelectorAll("pre"), function (pre) {
    var wrap = document.createElement("div");
    wrap.className = "code-block";
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);

    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copybtn";
    btn.textContent = "Copy";
    btn.setAttribute("aria-label", "Copy code sample");
    wrap.appendChild(btn);

    btn.addEventListener("click", function () {
      var text = pre.innerText;
      var done = function () {
        btn.textContent = "Copied";
        btn.classList.add("done");
        setTimeout(function () {
          btn.textContent = "Copy";
          btn.classList.remove("done");
        }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
      function fallback() {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); done(); } catch (err) { /* nothing to do */ }
        document.body.removeChild(ta);
      }
    });
  });

  // --- search over every page's headings -----------------------------------

  var input = document.getElementById("navsearch-input");
  var tree = document.getElementById("navtree");
  var results = document.getElementById("navresults");
  var index = window.__DOCS_INDEX__ || [];

  // Flatten the index once: one entry per page and per section.
  var entries = [];
  index.forEach(function (page) {
    entries.push({
      title: page.title, sub: page.group, href: page.href, isPage: true,
      hay: (page.title + " " + page.group + " " + (page.text || "")).toLowerCase()
    });
    (page.sections || []).forEach(function (s) {
      entries.push({
        title: s.title, sub: page.title, href: page.href + "#" + s.id,
        // Body text is matched but never shown: it is there so searching a
        // term that only appears in prose still finds the right section.
        hay: (s.title + " " + page.title + " " + (s.text || "")).toLowerCase()
      });
    });
  });

  function render(query) {
    var q = query.trim().toLowerCase();
    if (!q) {
      tree.hidden = false;
      results.hidden = true;
      results.innerHTML = "";
      return;
    }
    tree.hidden = true;
    results.hidden = false;

    var hits = entries
      .map(function (e, i) { return { e: e, i: i, score: score(e, q) }; })
      .filter(function (r) { return r.score > 0; })
      .sort(function (a, b) { return b.score - a.score || a.i - b.i; })
      .slice(0, 20)
      .map(function (r) { return r.e; });

    if (!hits.length) {
      results.innerHTML = '<p class="empty">No matches for &ldquo;' + escapeHtml(query) + '&rdquo;</p>';
      return;
    }
    results.innerHTML = hits.map(function (h) {
      return '<a class="hit" href="' + h.href + '">' + escapeHtml(h.title) +
             "<small>" + escapeHtml(h.sub) + "</small></a>";
    }).join("");
  }

  // A title hit always beats a body hit. Among body hits a section beats the
  // whole-page entry -- otherwise the overview, which mentions everything once,
  // outranks the guide that actually explains the term.
  function score(e, q) {
    var t = e.title.toLowerCase();
    var at = t.indexOf(q);
    if (at === 0) return 1000;
    if (at > 0) return 800;
    if (e.hay.indexOf(q) === -1) return 0;

    var n = 0, from = 0, found;
    while ((found = e.hay.indexOf(q, from)) !== -1 && n < 10) { n++; from = found + q.length; }
    return (e.isPage ? 10 : 100) + n;
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  if (input && tree && results) {
    input.addEventListener("input", function () { render(input.value); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { input.value = ""; render(""); input.blur(); }
      if (e.key === "Enter") {
        var first = results.querySelector(".hit");
        if (first && !results.hidden) { e.preventDefault(); first.click(); }
      }
    });
    // "/" focuses search, the way it does on most docs sites.
    document.addEventListener("keydown", function (e) {
      if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return;
      var t = e.target;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      e.preventDefault();
      setNav(true);
      input.focus();
      input.select();
    });
  }

  // --- scrollspy for "On this page" ----------------------------------------

  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a[href^='#']"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var byId = {};
    var targets = [];
    tocLinks.forEach(function (a) {
      var el = document.getElementById(decodeURIComponent(a.hash.slice(1)));
      if (el) { byId[el.id] = a; targets.push(el); }
    });

    var visible = {};
    var observer = new IntersectionObserver(function (records) {
      records.forEach(function (r) { visible[r.target.id] = r.isIntersecting; });

      // Highlight the first heading currently in the top band of the viewport,
      // falling back to the last one scrolled past.
      var active = null;
      for (var i = 0; i < targets.length; i++) {
        if (visible[targets[i].id]) { active = targets[i].id; break; }
      }
      if (!active) {
        for (var j = targets.length - 1; j >= 0; j--) {
          if (targets[j].getBoundingClientRect().top < 120) { active = targets[j].id; break; }
        }
      }
      tocLinks.forEach(function (a) { a.classList.remove("active"); });
      if (active && byId[active]) byId[active].classList.add("active");
    }, { rootMargin: "-72px 0px -70% 0px", threshold: 0 });

    targets.forEach(function (t) { observer.observe(t); });
  }
})();
