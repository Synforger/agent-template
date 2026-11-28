/*
 * 説明のページを、API の説明書 (Sphinx) のような 3 段の形にする。ページは `</body>` の前に、この file を読む
 * `<script src="../_common/toc-sidebar.js" defer></script>` を 1 行置くだけ (根の階層のタブの folder のページの場合)。
 * 真値はエージェントの根の pages/_common/ のこの 1 本で、各階層へは写さず、ページが根のこの file を相対 path で直に読む
 * (その 1 行は .claude/skills/explainer-pages/scripts/install_toc.py が足す)。
 *   上のバー: 左の開け閉め (☰)・「ページ › 今の節」・右の開け閉め
 *   ページの頭: 「タブのトップ › h2 の段 › h3 の段 › このページ」の道しるべ。段の見出しの中にリンク (枝の入口) が在れば押して移れる
 *   左: タブの全部のページ (タブのトップページ index.html のリンクを、その見出しの段ごとに枝にして並べる)。
 *       トップの中に `data-toc-pages` の付いた要素が在れば、その中の h2・h3・リンクだけを読む (無ければ main の中の全部)
 *       枝は畳んで出し、横に中のページの数を添える。今のページを持つ枝は開き、今のページは節まで開く。
 *       h3 の枝は直前の h2 の枝の中に入る。自分のページを持たず枝だけを束ねる h2 は開いて出し、それが 1 つだけなら
 *       その段を省いて子の枝を一番上に並べる。
 *       1 つの枝の中で同じ folder のページが FOLDER_FOLD_MIN 本以上あり、ほかのページも在れば、その folder でも畳む。
 *       人が開け閉めした枝は、タブごとに localStorage に覚える (今のページを持つ枝は覚えより優先して開く)
 *   新しく足したページ: トップページのリンクに `data-added="YYYY-MM-DD"` (時刻まで書いてもよい) が在れば、新しい順に
 *       NEW_PAGE_COUNT 件を左の一覧の枝より上に出す。トップページに `data-toc-new` の付いた要素が在れば、そこにも出す。
 *       出したページも枝の中に残る。日付の無いリンクは新しい物に数えない
 *   右: このページの中の節 (h2・h3)。今読んでいる節に印。幅 RIGHT_MIN_PX 以上で出す
 *   下: 前のページ・次のページ (タブの中のページだけ、トップページの並び順)
 * タブのトップは、ページ自身の URL から決める。ページの URL の最後の `/pages/` の次の 1 段をタブの folder とし、
 * ページがその下に在れば、枝の folder の中 (`<タブ>/model/x.html` など) でも `<タブ>/index.html` がトップで、
 * 枝の中のページもタブの中として前と次に並ぶ。この file の置き場には依らない。`/pages/` の下に無いページと、
 * `pages/` 直下のページは、ページの隣の index.html をトップにする。
 * 狭い画面では左が引き出しになり、右は左の今のページの下に入る。開け閉めは localStorage に覚える (使えない時は毎回開いた形)。
 * 閉じた <details> の中の見出しへ移る時は、その <details> を開く。
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
  /** 枝の開け閉めを覚える鍵の頭 (後ろにタブのトップの URL を付ける) */
  var STORE_BRANCHES = "toc-sidebar:branches:";
  /** 「新しく足したページ」に出す数の上限 */
  var NEW_PAGE_COUNT = 3;
  /** 枝の中で、同じ folder のページがこの数以上なら folder でも畳む */
  var FOLDER_FOLD_MIN = 2;
  /** リンクに付ける、ページを足した日の属性 */
  var ADDED_ATTRIBUTE = "data-added";
  var ADDED_PATTERN = /^\d{4}-\d{2}-\d{2}/;
  /** トップページの中で、新しく足したページを出す要素の印 */
  var NEW_MARK = "data-toc-new";
  var INDEX_PAGE = "index.html";
  /** ページの URL の中で、階層の説明のページの置き場を指す段。この次の 1 段がタブの folder */
  var PAGES_FOLDER = "/pages/";
  /** トップページの中で、左の一覧の元にする範囲の印 (本文の文中のリンクを一覧から外すため) */
  var PAGES_MARK = "data-toc-pages";

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
    ".tsb-side ol{list-style:none;margin:0;padding:0;} .tsb-side li{margin:0;}",
    ".tsb-side a{display:block;padding:3px 8px;border-radius:5px;border-left:3px solid transparent;color:var(--fg,CanvasText);text-decoration:none;}",
    ".tsb-side a:hover{background:var(--bg,Canvas);}",
    ".tsb-side a.tsb-here{font-weight:700;background:var(--bg,Canvas);}",
    ".tsb-side a.tsb-out::after{content:' ↗';color:var(--muted,GrayText);}",
    ".tsb-new{margin:10px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line,GrayText);} .tsb-new h6{margin-top:0;}",
    ".tsb-new small{margin-left:6px;color:var(--muted,GrayText);font-size:11.5px;font-weight:400;}",
    ".tsb-branch{margin:2px 0;} .tsb-head{display:flex;align-items:center;gap:2px;}",
    ".tsb-side button{display:flex;align-items:center;gap:4px;font:inherit;color:inherit;background:none;border:0;border-radius:5px;padding:3px 4px;cursor:pointer;text-align:left;}",
    ".tsb-side button:hover{background:var(--bg,Canvas);}",
    ".tsb-toggle{flex:1;min-width:0;}",
    ".tsb-twist{flex:none;display:inline-block;width:14px;text-align:center;color:var(--muted,GrayText);transition:transform .15s;}",
    "[aria-expanded=true] .tsb-twist{transform:rotate(90deg);}",
    ".tsb-caption{font-weight:700;}",
    // 入口のある枝の名前は、入口の無い枝の名前と同じ位置から始める (開け閉めの印の幅 18px + 間 2px + 2px)
    ".tsb-head a{flex:1;min-width:0;font-weight:700;padding-left:2px;border-left:0;}",
    ".tsb-head button:not(.tsb-toggle){padding-right:0;} .tsb-spacer{flex:none;width:18px;}",
    ".tsb-count{flex:none;margin-left:auto;padding:0 6px;font-size:11.5px;color:var(--muted,GrayText);border:1px solid var(--line,GrayText);border-radius:999px;}",
    ".tsb-inside{margin-left:10px;padding-left:6px;border-left:1px solid var(--line,GrayText);}",
    ".tsb-left .tsb-dup{display:none;}",
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

  /** localStorage から枝の開け閉め {枝の道: 開いているか} を読む (= 読めなければ空)。 */
  function loadBranches(key) {
    try { return JSON.parse(window.localStorage.getItem(key)) || {}; } catch (error) { return {}; }
  }

  /** 枝の開け閉めを localStorage に書く (= 書けなければ何もしない)。 */
  function saveBranches(key, states) {
    try { window.localStorage.setItem(key, JSON.stringify(states)); } catch (error) { /* 覚えられないだけで、画面は動く */ }
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

  /** ページのタブのトップ {url, isTab}。isTab は、ページが `/pages/<タブ>/` の下に在り、枝の folder も
   *  タブの中に数える時に真。`/pages/` の下に無いページと `pages/` 直下のページは、隣の index.html で isTab は偽。 */
  function topPage(here) {
    var at = here.lastIndexOf(PAGES_FOLDER);
    if (at >= 0) {
      var pagesRoot = here.slice(0, at + PAGES_FOLDER.length);
      var inside = here.slice(pagesRoot.length).split("/");
      if (inside.length > 1) { return { url: pagesRoot + inside[0] + "/" + INDEX_PAGE, isTab: true }; }
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

  /** タブのトップページの文書から、見出しの段ごとのページのリンク
   *  [{caption, level, href, added, pages:[{href, title, inTab, added}]}] を読む。
   *  level は見出しの段 (h2 = 2・h3 = 3)。href は見出しの中のリンク (枝の入口) で、無ければ空。
   *  inTab は、トップの folder の下のページか (nested が偽なら直下だけ)。added はページを足した日で、無ければ空。 */
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
    var added = {};
    /** リンクに足した日が在れば、行き先ごとに一番新しい値を覚える。 */
    function noteAdded(link, absolute) {
      var value = link.getAttribute(ADDED_ATTRIBUTE) || "";
      if (ADDED_PATTERN.test(value) && !(added[absolute] >= value)) { added[absolute] = value; }
    }
    root.querySelectorAll(selector).forEach(function (node) {
      // 新しく足したページを出す要素の中は、この部品が書き込む物なので読まない
      if (node.closest("[" + NEW_MARK + "]")) { return; }
      if (node.tagName === "H2" || node.tagName === "H3") {
        groups.push(current);
        var entry = node.querySelector("a[href]");
        var entryHref = entry ? entry.getAttribute("href") : "";
        current = { caption: text(node), level: node.tagName === "H3" ? 3 : 2,
                    href: entryHref && /\.html?(#|$|\?)/.test(entryHref) && !/^[a-z]+:/i.test(entryHref) ? pageUrl(entryHref, indexUrl) : "",
                    pages: [] };
        if (current.href) {
          noteAdded(entry, current.href);
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
      noteAdded(node, absolute);
      if (seen[absolute]) { return; }
      seen[absolute] = true;
      current.pages.push({ href: absolute, title: text(node), inTab: inTabOf(absolute) });
    });
    groups.push(current);
    groups.forEach(function (group) {
      group.added = added[group.href] || "";
      group.pages.forEach(function (page) { page.added = added[page.href] || ""; });
    });
    // ページの無い段は出さない。ただし h2 の段は、その下の h3 の段にページか入口が在れば親の見出しとして残す
    return groups.filter(function (group, index) {
      if (group.pages.length || group.href) { return true; }
      if (group.level !== 2 || !group.caption) { return false; }
      for (var next = index + 1; next < groups.length && groups[next].level === 3; next += 1) {
        if (groups[next].pages.length || groups[next].href) { return true; }
      }
      return false;
    });
  }

  /** 段の一覧から、足した日の在るページ [{href, title, inTab, added}] を新しい順に NEW_PAGE_COUNT 件まで返す。
   *  同じ日なら、トップページで後ろに書いた物を新しいとする。 */
  function newestPages(groups) {
    var dated = [];
    groups.forEach(function (group) {
      if (group.href && group.added) { dated.push({ href: group.href, title: group.caption, inTab: group.inTab, added: group.added }); }
      group.pages.forEach(function (page) { if (page.added) { dated.push(page); } });
    });
    return dated.map(function (page, order) { return { page: page, order: order }; }).sort(function (a, b) {
      if (a.page.added !== b.page.added) { return a.page.added < b.page.added ? 1 : -1; }
      return b.order - a.order;
    }).slice(0, NEW_PAGE_COUNT).map(function (entry) { return entry.page; });
  }

  /** URL の道の 1 段を、読める名前にする (= 戻せない時はそのまま)。 */
  function readableName(segment) {
    try { return decodeURIComponent(segment); } catch (error) { return segment; }
  }

  /** 枝のページの並びを、直に置くページと folder の枝に分けて {items} で返す。items は元の並びで、
   *  folder の枝は最初のページの位置に入る。folder は、タブの中のページに共通する folder の 1 つ下で数える。 */
  function foldFolders(pages) {
    var common = null;
    pages.forEach(function (page) {
      if (!page.inTab) { return; }
      var folders = page.href.split("/").slice(0, -1);
      if (common === null) { common = folders; return; }
      var length = 0;
      while (length < common.length && common[length] === folders[length]) { length += 1; }
      common = common.slice(0, length);
    });
    function folderOf(page) {
      if (!page.inTab) { return ""; }
      var rest = page.href.split("/").slice(common.length);
      return rest.length > 1 ? rest[0] : "";
    }
    var counts = Object.create(null);
    pages.forEach(function (page) {
      var folder = folderOf(page);
      if (folder) { counts[folder] = (counts[folder] || 0) + 1; }
    });
    var branches = Object.create(null);
    var items = [];
    pages.forEach(function (page) {
      var folder = folderOf(page);
      if (!folder || counts[folder] < FOLDER_FOLD_MIN || counts[folder] === pages.length) {
        items.push({ page: page });
        return;
      }
      if (!branches[folder]) {
        branches[folder] = { caption: readableName(folder), href: "", inTab: true, pages: [], children: [] };
        items.push({ branch: branches[folder] });
      }
      branches[folder].pages.push(page);
    });
    return items;
  }

  /** 段の一覧を枝の木 [{caption, href, inTab, pages, children}] にする。h3 の段は直前の h2 の段の子になる。
   *  見出しの無い段は caption が空の枝になる。 */
  function branchTree(groups) {
    var tree = [];
    var parent = null;
    groups.forEach(function (group) {
      var branch = { caption: group.caption, href: group.href, inTab: group.inTab, pages: group.pages, children: [] };
      if (group.level === 3 && parent) {
        parent.children.push(branch);
        return;
      }
      tree.push(branch);
      if (group.level === 2 && group.caption) { parent = branch; }
    });
    // 全部の枝を束ねる h2 が 1 つだけの時は、その段を畳んでも何も選べないので、子の枝を一番上に出す
    var captioned = tree.filter(function (branch) { return branch.caption; });
    if (captioned.length === 1 && isBundle(captioned[0])) {
      var at = tree.indexOf(captioned[0]);
      return tree.slice(0, at).concat(captioned[0].children, tree.slice(at + 1));
    }
    return tree;
  }

  /** 自分の入口もページも持たず、子の枝を束ねるだけの枝か。 */
  function isBundle(branch) {
    return !branch.href && !branch.pages.length;
  }

  /** 枝の中 (入口・ページ・子の枝) に、その URL のページが在るか。 */
  function holdsPage(branch, url) {
    return branch.href === url || branch.pages.some(function (page) { return page.href === url; }) ||
      branch.children.some(function (child) { return holdsPage(child, url); });
  }

  /** 枝の下に在るページの数 (= 枝自身の入口は数えない)。 */
  function pageCount(branch) {
    return branch.children.reduce(function (sum, child) {
      return sum + pageCount(child) + (child.href ? 1 : 0);
    }, branch.pages.length);
  }

  /** ページへのリンク 1 本 (タブの外のページには ↗ の印の class を付ける)。 */
  function pageLink(page) {
    var link = element("a", page.inTab ? "" : "tsb-out", page.title);
    link.href = page.href;
    return link;
  }

  /** 新しく足したページの一覧。日付は月と日だけを添える。 */
  function newList(pages) {
    var list = element("ol");
    pages.forEach(function (page) {
      var item = element("li");
      var link = pageLink(page);
      link.appendChild(element("small", "", page.added.slice(5, 10)));
      item.appendChild(link);
      list.appendChild(item);
    });
    return list;
  }

  /** 左の一覧に枝の木を足し、今のページの行に印を付けて節の目次 local を入れる。
   *  返すのは今のページの行のリンク (= 一覧に無ければ null)。 */
  function appendBranches(panel, tree, here, local, storeKey) {
    var states = loadBranches(storeKey);
    var hereLink = null;
    function markHere(link, holder) {
      link.classList.add("tsb-here");
      holder.appendChild(local);
      hereLink = link;
    }
    function pageItem(page) {
      var item = element("li");
      var link = pageLink(page);
      item.appendChild(link);
      if (page.href === here && !hereLink) { markHere(link, item); }
      return item;
    }
    /** 枝の中身 (直のページと folder の枝、続けて子の枝) を holder に足す。 */
    function fill(holder, branch, trail) {
      var list = null;
      foldFolders(branch.pages).forEach(function (item) {
        if (item.branch) {
          list = null;
          holder.appendChild(branchNode(item.branch, trail));
          return;
        }
        if (!list) { list = element("ol"); holder.appendChild(list); }
        list.appendChild(pageItem(item.page));
      });
      branch.children.forEach(function (child) { holder.appendChild(branchNode(child, trail)); });
    }
    function branchNode(branch, trail) {
      var path = trail.concat(branch.caption);
      var key = path.join(" / ");
      var node = element("div", "tsb-branch");
      var head = element("div", "tsb-head");
      var inside = element("div", "tsb-inside");
      var count = pageCount(branch);
      var isOpen = holdsPage(branch, here) || (key in states ? states[key] : isBundle(branch));
      var button = element("button", count && branch.href ? "" : "tsb-toggle");
      button.type = "button";
      button.appendChild(element("span", "tsb-twist", "▸"));
      node.appendChild(head);
      if (branch.href) {
        var entry = element("a", branch.inTab ? "" : "tsb-out", branch.caption);
        entry.href = branch.href;
        if (count) {
          button.setAttribute("aria-label", branch.caption + " の中を開け閉めする");
          head.appendChild(button);
        } else {
          head.appendChild(element("span", "tsb-spacer"));
        }
        head.appendChild(entry);
        if (branch.href === here && !hereLink) { markHere(entry, node); }
      } else {
        button.appendChild(element("span", "tsb-caption", branch.caption));
        head.appendChild(button);
      }
      if (!count) { return node; }
      (branch.href ? head : button).appendChild(element("span", "tsb-count", String(count)));
      function apply() {
        inside.hidden = !isOpen;
        button.setAttribute("aria-expanded", String(isOpen));
      }
      button.addEventListener("click", function () {
        isOpen = !isOpen;
        states[key] = isOpen;
        saveBranches(storeKey, states);
        apply();
      });
      fill(inside, branch, path);
      node.appendChild(inside);
      apply();
      return node;
    }
    tree.forEach(function (branch) {
      if (branch.caption) {
        panel.appendChild(branchNode(branch, []));
      } else {
        fill(panel, branch, []);
      }
    });
    return hereLink;
  }

  /** href の # が指す要素が閉じた <details> の中に在れば開いて、その要素まで送る。 */
  function revealTarget(hash) {
    var target = hash.length > 1 ? document.getElementById(readableName(hash.slice(1))) : null;
    if (!target) { return; }
    var isOpened = false;
    for (var node = target.parentElement; node; node = node.parentElement) {
      // <summary> の中の要素は閉じていても見えるので、開けない
      if (node.tagName === "DETAILS" && !node.open && !target.closest("summary")) {
        node.open = true;
        isOpened = true;
      }
    }
    if (isOpened) { target.scrollIntoView(); }
  }

  /** 画面に出ているか (= 閉じた枝や <details> の中の物は偽)。 */
  function isShown(node) {
    return node.getClientRects().length > 0;
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
    var isBottom = window.scrollY > 0 && window.innerHeight + window.scrollY >= page.scrollHeight - 2;
    var index = -1;
    for (var i = 0; i < headings.length; i += 1) {
      if (!isShown(headings[i])) { continue; }
      if (isBottom || headings[i].getBoundingClientRect().top <= ACTIVE_OFFSET_PX) { index = i; } else { break; }
    }
    return index;
  }

  /** 目次の欄の中で、印の付いた行が見える所まで欄を送る。 */
  function keepVisible(panel, link) {
    // 固定の欄は offsetParent が常に null なので、出ているかは箱の有無で見る
    if (!link || !isShown(panel) || !isShown(link)) { return; }
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
    if (here === indexUrl) {
      left.appendChild(leftLocal.list);
      // 枝の見出し (h3) は下の枝の木に同じ名前で並ぶので、節の目次からは外す
      headings.forEach(function (heading, i) {
        if (heading.tagName === "H3" && heading.closest("[" + PAGES_MARK + "]")) {
          leftLocal.links[i].parentElement.classList.add("tsb-dup");
        }
      });
    }

    /** 左に新しく足したページと枝の木を並べ、下に前と次のページを置き、頭に道しるべを置く。 */
    function fillPages(groups) {
      var order = [];
      groups.forEach(function (group) {
        if (group.caption && group.href && group.inTab) { order.push({ href: group.href, title: group.caption }); }
        group.pages.forEach(function (page) { if (page.inTab) { order.push(page); } });
      });
      var newest = newestPages(groups);
      if (newest.length) {
        var fresh = element("div", "tsb-new");
        fresh.appendChild(element("h6", "", "新しく足したページ"));
        fresh.appendChild(newList(newest));
        left.appendChild(fresh);
        if (here === indexUrl) {
          document.querySelectorAll("[" + NEW_MARK + "]").forEach(function (slot) {
            slot.textContent = "";
            slot.appendChild(element("p", "", "新しく足したページ"));
            slot.appendChild(newList(newest));
          });
        }
      }
      var hereLink = appendBranches(left, branchTree(groups), here, leftLocal.list, STORE_BRANCHES + indexUrl);
      if (here !== indexUrl && !hereLink) {
        left.appendChild(element("h6", "", document.title || "このページ"));
        left.appendChild(leftLocal.list);
      }
      addPager(order);
      addCrumbs(groups);
      keepVisible(left, hereLink);
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
      if (event.target.closest("a") && !isWide()) { body.classList.remove("tsb-drawer"); applyState(); }
    });
    [left, right].forEach(function (panel) {
      panel.addEventListener("click", function (event) {
        var link = event.target.closest("a");
        // 同じ # をもう一度押した時は hashchange が起きないので、押した所でも開ける
        if (link && link.getAttribute("href").charAt(0) === "#") { revealTarget(link.getAttribute("href")); }
      });
    });
    window.addEventListener("hashchange", function () { revealTarget(location.hash); });

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
    revealTarget(location.hash);

    loadGroups(indexUrl, top.isTab).then(fillPages);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
