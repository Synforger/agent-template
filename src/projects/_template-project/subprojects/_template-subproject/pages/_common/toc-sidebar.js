/*
 * 説明のページを、API の説明書 (Sphinx) のような 3 段の形にする。ページは `</body>` の前に
 * `<script src="../_common/toc-sidebar.js" defer></script>` を 1 行置くだけ (タブの folder のページの場合)。
 * 真値はエージェントの根の pages/_common/ のこの file で、各階層の pages/_common/ へは
 * .claude/skills/explainer-pages/scripts/install_toc.py が写し、行も足す。
 *   上のバー: 左の開け閉め (☰)・「ページ › 今の節」・右の開け閉め
 *   ページの頭: 「タブのトップ › h2 の段 › h3 の段 › このページ」の道しるべ。段の見出しの中にリンク (枝の入口) が在れば押して移れる
 *   左: タブの全部のページ (タブのトップページ index.html のリンクを、その見出しの段ごとに並べる)。今のページは節まで開く。
 *       トップの中に `data-toc-pages` の付いた要素が在れば、その中の h2・h3・リンクだけを読む (無ければ main の中の全部)
 *       h3 の見出しとその下のページは、h2 の物より 1 段下げて並べる。下にリンクの無い h2 も、下に h3 の段が在れば見出しを残す
 *   右: このページの中の節 (h2・h3)。今読んでいる節に印。幅 RIGHT_MIN_PX 以上で出す
 *   下: 前のページ・次のページ (タブの中のページだけ、トップページの並び順)
 * タブのトップは、この file の置き場から決める。この file は `<階層>/pages/_common/` に在るので、ページが
 * `<階層>/pages/<タブ>/` の下に在れば、枝の folder の中 (`<タブ>/model/x.html` など) でも `<タブ>/index.html` がトップで、
 * 枝の中のページもタブの中として前と次に並ぶ。それ以外の置き場のページは、ページの隣の index.html をトップにする。
 * 狭い画面では左が引き出しになり、右は左の今のページの下に入る。開け閉めは localStorage に覚える (使えない時は毎回開いた形)。
 * 見出しの id が無い物には `toc-<番号>` を振る。色はページの --bg・--fg・--line・--link・--card・--muted を使う。
 */
(function () {
  "use strict";

  /** 左を横に固定で出す画面の幅の下限 [px] (= これより狭い時は引き出し) */
  var WIDE_MIN_PX = 1200;
  /** 右の「このページの中」を出す画面の幅の下限 [px] */
  var RIGHT_MIN_PX = 1500;
  var LEFT_WIDTH_PX = 280;
  var RIGHT_WIDTH_PX = 240;
  var BAR_HEIGHT_PX = 44;
  /** 画面の上 (バーの下) からこの距離までに頭が来た見出しを「今読んでいる節」とする [px] */
  var ACTIVE_OFFSET_PX = BAR_HEIGHT_PX + 56;
  var STORE_LEFT = "toc-sidebar:left";
  var STORE_RIGHT = "toc-sidebar:right";
  var INDEX_PAGE = "index.html";
  var COMPONENT_FILE = "toc-sidebar.js";
  /** トップページの中で、左の一覧の元にする範囲の印 (本文の文中のリンクを一覧から外すため) */
  var PAGES_MARK = "data-toc-pages";
  /** この部品を読んだ script の行。document.currentScript は script の実行中にしか取れないので、ここで取っておく */
  var SELF_SCRIPT = document.currentScript;

  var CSS = [
    "body.tsb{padding-top:" + (BAR_HEIGHT_PX + 20) + "px!important;}",
    "h2[id],h3[id],h4[id]{scroll-margin-top:" + (BAR_HEIGHT_PX + 12) + "px;}",
    ".tsb-bar{position:fixed;top:0;left:0;right:0;height:" + BAR_HEIGHT_PX + "px;z-index:60;display:flex;align-items:center;gap:8px;padding:0 10px;",
    "background:var(--card,Canvas);color:var(--fg,CanvasText);border-bottom:1px solid var(--line,GrayText);font:14px/1.4 system-ui,sans-serif;box-sizing:border-box;}",
    ".tsb-bar button{flex:none;font:inherit;background:none;border:1px solid var(--line,GrayText);color:inherit;border-radius:6px;padding:4px 10px;cursor:pointer;}",
    ".tsb-bar button[aria-pressed=true]{background:var(--bg,Canvas);font-weight:600;}",
    ".tsb-where{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
    ".tsb-where b{font-weight:700;} .tsb-where span{color:var(--muted,GrayText);}",
    ".tsb-crumbs{margin:0 0 14px;font:13px/1.6 system-ui,sans-serif;color:var(--muted,GrayText);}",
    ".tsb-crumbs a{color:var(--link,LinkText);text-decoration:none;} .tsb-crumbs a:hover{text-decoration:underline;}",
    ".tsb-crumbs .tsb-sep{margin:0 6px;} .tsb-crumbs b{color:var(--fg,CanvasText);font-weight:600;}",
    ".tsb-side{position:fixed;top:" + BAR_HEIGHT_PX + "px;bottom:0;overflow-y:auto;z-index:55;box-sizing:border-box;padding:12px 10px 48px;",
    "background:var(--card,Canvas);color:var(--fg,CanvasText);font:14px/1.5 system-ui,sans-serif;}",
    ".tsb-left{left:0;width:" + LEFT_WIDTH_PX + "px;border-right:1px solid var(--line,GrayText);}",
    ".tsb-right{right:0;width:" + RIGHT_WIDTH_PX + "px;border-left:1px solid var(--line,GrayText);display:none;}",
    ".tsb-side h6{margin:14px 8px 4px;font-size:12px;font-weight:700;color:var(--muted,GrayText);letter-spacing:.02em;}",
    ".tsb-side h6.tsb-sub{margin:8px 8px 2px 20px;font-size:11.5px;font-weight:600;}",
    ".tsb-side ol.tsb-sub{margin-left:12px;}",
    ".tsb-side ol{list-style:none;margin:0;padding:0;} .tsb-side li{margin:0;}",
    ".tsb-side a{display:block;padding:3px 8px;border-radius:5px;border-left:3px solid transparent;color:var(--fg,CanvasText);text-decoration:none;}",
    ".tsb-side a:hover{background:var(--bg,Canvas);}",
    ".tsb-side a.tsb-here{font-weight:700;background:var(--bg,Canvas);}",
    ".tsb-side a.tsb-out::after{content:' ↗';color:var(--muted,GrayText);}",
    ".tsb-side h6 a{display:inline;padding:0;border-left:0;border-radius:0;color:inherit;} .tsb-side h6 a:hover{background:none;text-decoration:underline;}",
    ".tsb-side h6 a.tsb-here{background:none;color:var(--fg,CanvasText);}",
    ".tsb-local{margin:2px 0 6px 10px;border-left:1px solid var(--line,GrayText);}",
    ".tsb-local a{font-size:13px;color:var(--muted,GrayText);}",
    ".tsb-local .tsb-h3 a{padding-left:20px;font-size:12.5px;}",
    ".tsb-side a.on{border-left-color:var(--link,LinkText);color:var(--fg,CanvasText);font-weight:700;background:var(--bg,Canvas);}",
    ".tsb-side a.in{color:var(--fg,CanvasText);font-weight:600;}",
    ".tsb-backdrop{position:fixed;inset:0;z-index:54;background:rgba(0,0,0,.35);display:none;}",
    ".tsb-pager{display:flex;justify-content:space-between;gap:12px;margin:48px 0 0;padding-top:12px;border-top:1px solid var(--line,GrayText);font-size:15px;}",
    ".tsb-pager a{display:block;max-width:48%;text-decoration:none;} .tsb-pager small{display:block;color:var(--muted,GrayText);}",
    ".tsb-pager .tsb-next{margin-left:auto;text-align:right;}",
    "@media (min-width:" + WIDE_MIN_PX + "px){body.tsb.tsb-left-on{padding-left:" + (LEFT_WIDTH_PX + 16) + "px!important;}",
    "body.tsb:not(.tsb-left-on) .tsb-left{display:none;} .tsb-backdrop{display:none!important;}}",
    "@media (max-width:" + (WIDE_MIN_PX - 1) + "px){.tsb-left{width:min(86vw,340px);transform:translateX(-102%);transition:transform .2s;}",
    "body.tsb-drawer .tsb-left{transform:none;box-shadow:0 0 24px rgba(0,0,0,.35);} body.tsb-drawer .tsb-backdrop{display:block;} .tsb-right-toggle{display:none;}}",
    "@media (min-width:" + RIGHT_MIN_PX + "px){body.tsb.tsb-right-on{padding-right:" + (RIGHT_WIDTH_PX + 16) + "px!important;}",
    "body.tsb-right-on .tsb-right{display:block;} body.tsb-right-on .tsb-left .tsb-local{display:none;}}",
    "@media (max-width:" + (RIGHT_MIN_PX - 1) + "px){.tsb-right-toggle{display:none;}}"
  ].join("");

  /** localStorage から開け閉めを読む (= 読めなければ既定の「開く」)。 */
  function loadOpen(key) {
    try { return window.localStorage.getItem(key) !== "closed"; } catch (error) { return true; }
  }

  /** 開け閉めを localStorage に書く (= 書けなければ何もしない)。 */
  function saveOpen(key, isOpen) {
    try { window.localStorage.setItem(key, isOpen ? "open" : "closed"); } catch (error) { /* 覚えられないだけで、画面は動く */ }
  }

  function text(node) {
    return node.textContent.replace(/\s+/g, " ").trim();
  }

  function element(tag, className, content) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    if (content !== undefined) { node.textContent = content; }
    return node;
  }

  /** href の、ページの file の部分 (= # と ? を外した物) を、今のページから見た絶対の URL にする。 */
  function pageUrl(href, base) {
    var url = new URL(href, base);
    url.hash = "";
    url.search = "";
    return url.href;
  }

  /** ページのタブのトップ {url, isTab}。isTab は、ページが `<階層>/pages/<タブ>/` の下に在り、枝の folder も
   *  タブの中に数える時に真。部品の行が見つからない時と、タブの folder の外のページは、隣の index.html で isTab は偽。 */
  function topPage(here) {
    var script = SELF_SCRIPT || document.querySelector('script[src*="' + COMPONENT_FILE + '"]');
    if (script && script.src) {
      var pagesRoot = pageUrl("../", script.src);
      if (here.indexOf(pagesRoot) === 0) {
        var inside = here.slice(pagesRoot.length).split("/");
        if (inside.length > 1) { return { url: pagesRoot + inside[0] + "/" + INDEX_PAGE, isTab: true }; }
      }
    }
    return { url: pageUrl(INDEX_PAGE, here), isTab: false };
  }

  /** 目次に載せる見出しを集め、id の無い物に id を振って返す。 */
  function collectHeadings() {
    var root = document.querySelector("main") || document.body;
    var headings = Array.prototype.slice.call(root.querySelectorAll("h2, h3"));
    headings.forEach(function (heading, index) {
      if (!heading.id) { heading.id = "toc-" + (index + 1); }
    });
    return { root: root, headings: headings };
  }

  /** 見出しの並びから、h2 の下に h3 を並べた節の目次 (ol) と、見出しごとのリンク・親のリンクを作る。 */
  function localList(headings) {
    var list = element("ol");
    var links = [];
    var parents = [];
    var parent = null;
    headings.forEach(function (heading) {
      var item = element("li");
      var link = element("a", "", text(heading));
      link.href = "#" + heading.id;
      item.appendChild(link);
      if (heading.tagName === "H3" && parent) {
        item.className = "tsb-h3";
        list.appendChild(item);
        parents.push(parent);
      } else {
        list.appendChild(item);
        parent = link;
        parents.push(null);
      }
      links.push(link);
    });
    return { list: list, links: links, parents: parents };
  }

  /** タブのトップページの文書から、見出しの段ごとのページのリンク [{caption, level, href, pages:[{href, title, inTab}]}] を読む。
   *  level は見出しの段 (h2 = 2・h3 = 3)。href は見出しの中のリンク (枝の入口) で、無ければ空。
   *  inTab は、トップの folder の下のページか (nested が偽なら直下だけ)。 */
  function readGroups(indexDocument, indexUrl, nested) {
    var root = indexDocument.querySelector("main") || indexDocument.body;
    var selector = "h2, h3, a[href]";
    if (indexDocument.querySelector("[" + PAGES_MARK + "]")) {
      root = indexDocument;
      selector = ["h2", "h3", "a[href]"].map(function (tag) { return "[" + PAGES_MARK + "] " + tag; }).join(", ");
    }
    var folder = indexUrl.replace(/[^/]*$/, "");
    function inTabOf(absolute) {
      return absolute.indexOf(folder) === 0 && (nested || absolute.slice(folder.length).indexOf("/") === -1);
    }
    var groups = [];
    var current = { caption: "", level: 2, href: "", pages: [] };
    var seen = {};
    root.querySelectorAll(selector).forEach(function (node) {
      if (node.tagName === "H2" || node.tagName === "H3") {
        groups.push(current);
        var entry = node.querySelector("a[href]");
        var entryHref = entry ? entry.getAttribute("href") : "";
        current = { caption: text(node), level: node.tagName === "H3" ? 3 : 2,
                    href: entryHref && /\.html?(#|$|\?)/.test(entryHref) && !/^[a-z]+:/i.test(entryHref) ? pageUrl(entryHref, indexUrl) : "",
                    pages: [] };
        if (current.href) {
          seen[current.href] = true;
          current.inTab = inTabOf(current.href);
        }
        return;
      }
      // 見出しの中のリンクは段の入口で、見出しそのものがそのリンクになる (ページの行には並べない)
      if (node.closest("h2, h3")) { return; }
      var href = node.getAttribute("href");
      if (!/\.html?(#|$|\?)/.test(href) || /^[a-z]+:/i.test(href)) { return; }
      var absolute = pageUrl(href, indexUrl);
      if (seen[absolute]) { return; }
      seen[absolute] = true;
      current.pages.push({ href: absolute, title: text(node), inTab: inTabOf(absolute) });
    });
    groups.push(current);
    // ページの無い段は出さない。ただし h2 の段は、その下の h3 の段にページが在れば親の見出しとして残す
    return groups.filter(function (group, index) {
      if (group.pages.length || group.href) { return true; }
      if (group.level !== 2 || !group.caption) { return false; }
      for (var next = index + 1; next < groups.length && groups[next].level === 3; next += 1) {
        if (groups[next].pages.length) { return true; }
      }
      return false;
    });
  }

  /** トップページを読んで段の一覧を返す (= 今のページがトップならその文書を使う。読めなければ空の一覧)。 */
  function loadGroups(indexUrl, nested) {
    if (pageUrl(location.href, location.href) === indexUrl) {
      return Promise.resolve(readGroups(document, indexUrl, nested));
    }
    return fetch(indexUrl).then(function (response) {
      return response.ok ? response.text() : Promise.reject(response.status);
    }).then(function (html) {
      return readGroups(new DOMParser().parseFromString(html, "text/html"), indexUrl, nested);
    }).catch(function () { return []; });
  }

  /** 今読んでいる見出しの番号 (= 頭がバーの下 ACTIVE_OFFSET_PX までに来た最後の見出し。無ければ -1) を返す。
   *  ページの一番下まで送った時は、上まで上がれない最後の見出しを選ぶ。 */
  function activeIndex(headings) {
    var page = document.documentElement;
    if (headings.length && window.scrollY > 0 && window.innerHeight + window.scrollY >= page.scrollHeight - 2) {
      return headings.length - 1;
    }
    var index = -1;
    for (var i = 0; i < headings.length; i += 1) {
      if (headings[i].getBoundingClientRect().top <= ACTIVE_OFFSET_PX) { index = i; } else { break; }
    }
    return index;
  }

  /** 目次の欄の中で、印の付いた行が見える所まで欄を送る。 */
  function keepVisible(panel, link) {
    if (!link || panel.offsetParent === null) { return; }
    var box = panel.getBoundingClientRect();
    var row = link.getBoundingClientRect();
    if (row.top < box.top + 40 || row.bottom > box.bottom - 40) {
      panel.scrollTop += row.top - box.top - box.height / 3;
    }
  }

  function start() {
    var collected = collectHeadings();
    var headings = collected.headings;
    var here = pageUrl(location.href, location.href);
    var top = topPage(here);
    var indexUrl = top.url;
    var style = element("style");
    style.textContent = CSS;
    document.head.appendChild(style);

    var body = document.body;
    var bar = element("div", "tsb-bar");
    var leftToggle = element("button", "tsb-left-toggle", "☰ ページ");
    leftToggle.type = "button";
    leftToggle.setAttribute("aria-label", "ページの一覧を開け閉めする");
    var where = element("div", "tsb-where");
    var rightToggle = element("button", "tsb-right-toggle", "このページの中");
    rightToggle.type = "button";
    bar.appendChild(leftToggle);
    bar.appendChild(where);
    bar.appendChild(rightToggle);

    var left = element("nav", "tsb-side tsb-left");
    left.setAttribute("aria-label", "タブのページの一覧");
    var right = element("nav", "tsb-side tsb-right");
    right.setAttribute("aria-label", "このページの中");
    var backdrop = element("div", "tsb-backdrop");

    var leftLocal = localList(headings);
    var rightLocal = localList(headings);
    leftLocal.list.classList.add("tsb-local");
    right.appendChild(element("h6", "", "このページの中"));
    right.appendChild(rightLocal.list);

    var topLink = element("a", "", "このタブのトップ");
    topLink.href = indexUrl;
    if (here === indexUrl) { topLink.className = "tsb-here"; }
    left.appendChild(topLink);
    if (here === indexUrl) { left.appendChild(leftLocal.list); }

    /** 段の一覧を左に並べ、今のページの行の下に節の目次を入れ、下に前と次のページを置く。 */
    function fillPages(groups) {
      var order = [];
      var placed = here === indexUrl;
      groups.forEach(function (group) {
        var sub = group.level === 3 ? "tsb-sub" : "";
        if (group.caption) {
          var head = element("h6", sub);
          if (group.href) {
            var entry = element("a", group.inTab ? "" : "tsb-out", group.caption);
            entry.href = group.href;
            head.appendChild(entry);
          } else {
            head.textContent = group.caption;
          }
          left.appendChild(head);
          if (group.href && group.inTab) { order.push({ href: group.href, title: group.caption, inTab: true }); }
          if (group.href === here && !placed) {
            entry.className = "tsb-here";
            left.appendChild(leftLocal.list);
            placed = true;
          }
        }
        if (!group.pages.length) { return; }
        var list = element("ol", sub);
        group.pages.forEach(function (page) {
          var item = element("li");
          var link = element("a", page.inTab ? "" : "tsb-out", page.title);
          link.href = page.href;
          item.appendChild(link);
          if (page.href === here && !placed) {
            link.className = "tsb-here";
            item.appendChild(leftLocal.list);
            placed = true;
          }
          list.appendChild(item);
          if (page.inTab) { order.push(page); }
        });
        left.appendChild(list);
      });
      if (!placed) {
        left.appendChild(element("h6", "", document.title || "このページ"));
        left.appendChild(leftLocal.list);
      }
      addPager(order);
      addCrumbs(groups);
    }

    /** ページの頭に「タブのトップ › h2 の段 › h3 の段 › このページ」を置く。トップページ自身には置かない。 */
    function addCrumbs(groups) {
      if (here === indexUrl) { return; }
      var at = -1;
      groups.forEach(function (group, i) {
        if (at < 0 && (group.href === here || group.pages.some(function (page) { return page.href === here; }))) { at = i; }
      });
      var steps = [{ title: "タブのトップ", href: indexUrl }];
      if (at >= 0) {
        var group = groups[at];
        if (group.level === 3) {
          for (var i = at - 1; i >= 0; i -= 1) {
            if (groups[i].level === 2) {
              if (groups[i].caption) { steps.push({ title: groups[i].caption, href: groups[i].href }); }
              break;
            }
          }
        }
        // 段の入口そのものを開いている時は、その段を出さない (このページと同じ物が 2 回並ぶため)
        if (group.caption && group.href !== here) { steps.push({ title: group.caption, href: group.href }); }
      }
      var nav = element("nav", "tsb-crumbs");
      nav.setAttribute("aria-label", "このページの場所");
      steps.forEach(function (step) {
        if (step.href && step.href !== here) {
          var link = element("a", "", step.title);
          link.href = step.href;
          nav.appendChild(link);
        } else {
          nav.appendChild(element("span", "", step.title));
        }
        nav.appendChild(element("span", "tsb-sep", "›"));
      });
      nav.appendChild(element("b", "", document.title || "このページ"));
      collected.root.insertBefore(nav, collected.root.firstChild);
    }

    function addPager(order) {
      var position = -1;
      order.forEach(function (page, i) { if (page.href === here) { position = i; } });
      if (position < 0) { return; }
      var pager = element("nav", "tsb-pager");
      pager.setAttribute("aria-label", "前と次のページ");
      [[order[position - 1], "← 前のページ", "tsb-prev"], [order[position + 1], "次のページ →", "tsb-next"]].forEach(function (entry) {
        if (!entry[0]) { return; }
        var link = element("a", entry[2]);
        link.href = entry[0].href;
        link.appendChild(element("small", "", entry[1]));
        link.appendChild(document.createTextNode(entry[0].title));
        pager.appendChild(link);
      });
      collected.root.appendChild(pager);
    }

    var isWide = function () { return window.matchMedia("(min-width: " + WIDE_MIN_PX + "px)").matches; };
    var leftOpen = loadOpen(STORE_LEFT);
    var rightOpen = loadOpen(STORE_RIGHT);
    function applyState() {
      body.classList.toggle("tsb-left-on", leftOpen);
      body.classList.toggle("tsb-right-on", rightOpen);
      leftToggle.setAttribute("aria-pressed", String(isWide() ? leftOpen : body.classList.contains("tsb-drawer")));
      rightToggle.setAttribute("aria-pressed", String(rightOpen));
    }
    /** 開け閉めで本文の幅が変わっても、読んでいた見出しが画面の同じ高さに残るように送り直す。 */
    function keepReading(change) {
      var anchor = headings[Math.max(activeIndex(headings), 0)];
      var before = anchor ? anchor.getBoundingClientRect().top : 0;
      change();
      applyState();
      if (anchor) { window.scrollBy(0, anchor.getBoundingClientRect().top - before); }
    }
    leftToggle.addEventListener("click", function () {
      if (isWide()) {
        keepReading(function () { leftOpen = !leftOpen; saveOpen(STORE_LEFT, leftOpen); });
      } else {
        body.classList.toggle("tsb-drawer");
        applyState();
      }
    });
    rightToggle.addEventListener("click", function () {
      keepReading(function () { rightOpen = !rightOpen; saveOpen(STORE_RIGHT, rightOpen); });
    });
    backdrop.addEventListener("click", function () { body.classList.remove("tsb-drawer"); applyState(); });
    left.addEventListener("click", function (event) {
      if (event.target.tagName === "A" && !isWide()) { body.classList.remove("tsb-drawer"); applyState(); }
    });

    body.appendChild(bar);
    body.appendChild(left);
    body.appendChild(right);
    body.appendChild(backdrop);
    body.classList.add("tsb");
    applyState();

    var pageTitle = document.title || "";
    var shown = -2;
    function update() {
      var index = activeIndex(headings);
      if (index === shown) { return; }
      shown = index;
      [leftLocal, rightLocal].forEach(function (local) {
        local.links.forEach(function (link, i) {
          link.classList.toggle("on", i === index);
          link.classList.toggle("in", index >= 0 && local.parents[index] === link);
        });
      });
      where.textContent = "";
      where.appendChild(element("b", "", pageTitle));
      if (index >= 0) { where.appendChild(element("span", "", " › " + text(headings[index]))); }
      keepVisible(left, leftLocal.links[index]);
      keepVisible(right, rightLocal.links[index]);
    }
    var pending = false;
    window.addEventListener("scroll", function () {
      if (!pending) {
        pending = true;
        window.requestAnimationFrame(function () { pending = false; update(); });
      }
    }, { passive: true });
    window.addEventListener("resize", function () { applyState(); shown = -2; update(); });
    update();

    loadGroups(indexUrl, top.isTab).then(fillPages);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
