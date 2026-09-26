// ReadAnythingAloud article walker (MIT).
// Runs inside the page after Readability.js is injected. Produces a JSON-serializable article:
// { ok, title, byline, siteName, lang, excerpt, leadImage, publishedTime, blocks: [...], wordCount, reason }
// Block shapes: {k:"h", level, runs} {k:"p", runs} {k:"li", ordered, number, depth, runs} {k:"quote", runs}
//               {k:"code", text} {k:"img", src, alt} {k:"caption", runs} {k:"hr"}
// Run shape: {t, b?, i?, c?, a?}
(function () {
  "use strict";

  const SKIP_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "BUTTON", "INPUT", "SELECT",
    "TEXTAREA", "FORM", "NAV", "IFRAME", "VIDEO", "AUDIO", "CANVAS", "OBJECT", "EMBED", "MATH"]);
  const BLOCK_TAGS = new Set(["P", "DIV", "SECTION", "ARTICLE", "MAIN", "HEADER", "FOOTER", "ASIDE", "H1", "H2",
    "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "FIGURE", "FIGCAPTION", "IMG", "PICTURE", "HR",
    "TABLE", "THEAD", "TBODY", "TFOOT", "TR", "TD", "TH", "DL", "DT", "DD", "DETAILS", "SUMMARY", "CAPTION"]);

  function absolute(url) {
    if (!url) return null;
    try { return new URL(url, document.baseURI).href; } catch (e) { return null; }
  }

  function bestImageSource(img) {
    const candidates = [];
    const srcset = img.getAttribute("srcset") || img.getAttribute("data-srcset");
    if (srcset) {
      for (const part of srcset.split(",")) {
        const [u, d] = part.trim().split(/\s+/);
        const w = d && d.endsWith("w") ? parseInt(d) : d && d.endsWith("x") ? parseFloat(d) * 1000 : 1;
        if (u) candidates.push({ u, w });
      }
      candidates.sort((a, b) => b.w - a.w);
      // Prefer a reasonably sized rendition over a huge original.
      const good = candidates.find(c => c.w <= 1600) || candidates[candidates.length - 1];
      if (good) return absolute(good.u);
    }
    const src = img.getAttribute("src") || img.getAttribute("data-src") || img.getAttribute("data-lazy-src") ||
      img.getAttribute("data-original");
    if (src && !src.startsWith("data:")) return absolute(src);
    return null;
  }

  function Walker() {
    this.blocks = [];
    this.runs = null;          // pending inline runs
    this.kind = null;          // pending block descriptor
  }

  Walker.prototype.flush = function () {
    if (this.runs && this.runs.some(r => r.t.trim().length > 0)) {
      const block = Object.assign({}, this.kind || { k: "p" });
      block.runs = mergeRuns(this.runs);
      this.blocks.push(block);
    }
    this.runs = null;
    this.kind = null;
  };

  Walker.prototype.begin = function (kind) {
    this.flush();
    this.kind = kind;
    this.runs = [];
  };

  Walker.prototype.text = function (t, style) {
    if (!t) return;
    if (!this.runs) { this.runs = []; this.kind = this.kind || { k: "p" }; }
    const run = { t };
    if (style.b) run.b = true;
    if (style.i) run.i = true;
    if (style.c) run.c = true;
    if (style.a) run.a = style.a;
    this.runs.push(run);
  };

  function mergeRuns(runs) {
    const out = [];
    for (const r of runs) {
      const last = out[out.length - 1];
      if (last && !!last.b === !!r.b && !!last.i === !!r.i && !!last.c === !!r.c && last.a === r.a) {
        last.t += r.t;
      } else {
        out.push(Object.assign({}, r));
      }
    }
    return out;
  }

  function isFootnoteRef(el) {
    if (el.tagName !== "SUP") return false;
    const t = el.textContent.trim();
    return /^\[?\d{1,3}\]?$/.test(t) || /^\[?[a-z]\]?$/.test(t);
  }

  function isHidden(el) {
    // `hidden="until-found"` is collapsed-but-findable content (mobile Wikipedia's sections), not furniture.
    if (el.hasAttribute("hidden") && el.getAttribute("hidden") !== "until-found") return true;
    if (el.getAttribute("aria-hidden") === "true") return true;
    const style = el.getAttribute("style") || "";
    return /display\s*:\s*none|visibility\s*:\s*hidden/i.test(style);
  }

  Walker.prototype.inline = function (node, style) {
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === Node.TEXT_NODE) {
        this.text(child.nodeValue, style);
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        this.element(child, style);
      }
    }
  };

  Walker.prototype.listDepth = 0;

  Walker.prototype.element = function (el, style) {
    const tag = el.tagName.toUpperCase();
    if (SKIP_TAGS.has(tag) || isHidden(el)) return;
    if (isFootnoteRef(el)) return;

    switch (tag) {
      case "H1": case "H2": case "H3": case "H4": case "H5": case "H6":
        this.begin({ k: "h", level: parseInt(tag[1]) });
        this.inline(el, style);
        this.flush();
        return;
      case "P": case "DT": case "DD": case "SUMMARY":
        this.begin(this.inQuote ? { k: "quote" } : { k: "p" });
        this.inline(el, style);
        this.flush();
        return;
      case "BR":
        this.text(" ", style);
        return;
      case "HR":
        this.flush();
        this.blocks.push({ k: "hr" });
        return;
      case "PRE": {
        this.flush();
        const text = el.textContent.replace(/\s+$/, "");
        if (text.trim()) this.blocks.push({ k: "code", text });
        return;
      }
      case "IMG": {
        const src = bestImageSource(el);
        const w = parseInt(el.getAttribute("width") || "0");
        const h = parseInt(el.getAttribute("height") || "0");
        if (src && !(w && w < 48) && !(h && h < 48)) {
          this.flush();
          this.blocks.push({ k: "img", src, alt: (el.getAttribute("alt") || "").trim() || null });
        }
        return;
      }
      case "PICTURE": {
        const img = el.querySelector("img");
        if (img) this.element(img, style);
        return;
      }
      case "FIGURE": {
        this.flush();
        for (const child of Array.from(el.children)) {
          if (child.tagName.toUpperCase() === "FIGCAPTION") continue;
          this.element(child, style);
        }
        const cap = el.querySelector("figcaption");
        if (cap && cap.textContent.trim()) {
          this.begin({ k: "caption" });
          this.inline(cap, style);
          this.flush();
        }
        return;
      }
      case "FIGCAPTION":
        this.begin({ k: "caption" });
        this.inline(el, style);
        this.flush();
        return;
      case "UL": case "OL": {
        this.flush();
        const ordered = tag === "OL";
        let number = parseInt(el.getAttribute("start") || "1") || 1;
        this.listDepth++;
        for (const li of Array.from(el.children)) {
          if (li.tagName.toUpperCase() !== "LI") { this.element(li, style); continue; }
          this.listItem(li, ordered, number, style);
          number++;
        }
        this.listDepth--;
        return;
      }
      case "LI":
        this.listItem(el, false, 1, style);
        return;
      case "BLOCKQUOTE": {
        this.flush();
        const wasQuote = this.inQuote;
        this.inQuote = true;
        this.begin({ k: "quote" });
        this.inline(el, style);
        this.flush();
        this.inQuote = wasQuote;
        return;
      }
      case "TABLE": {
        this.flush();
        for (const row of Array.from(el.querySelectorAll("tr"))) {
          const cells = Array.from(row.children).map(c => c.textContent.replace(/\s+/g, " ").trim()).filter(Boolean);
          if (cells.length) this.blocks.push({ k: "p", runs: [{ t: cells.join(" · ") }] });
        }
        return;
      }
      case "STRONG": case "B":
        this.inline(el, Object.assign({}, style, { b: true }));
        return;
      case "EM": case "I": case "CITE": case "DFN":
        this.inline(el, Object.assign({}, style, { i: true }));
        return;
      case "CODE": case "KBD": case "SAMP": case "TT":
        this.inline(el, Object.assign({}, style, { c: true }));
        return;
      case "A": {
        const href = absolute(el.getAttribute("href"));
        this.inline(el, Object.assign({}, style, href && /^https?:/.test(href) ? { a: href } : {}));
        return;
      }
      default:
        if (BLOCK_TAGS.has(tag)) {
          // Generic container: text directly inside it forms its own paragraph(s).
          this.flush();
          if (this.inQuote) this.kind = { k: "quote" };
          this.inline(el, style);
          this.flush();
        } else {
          this.inline(el, style);
        }
    }
  };

  Walker.prototype.listItem = function (li, ordered, number, style) {
    this.begin({ k: "li", ordered, number, depth: Math.max(0, this.listDepth - 1) });
    for (const child of Array.from(li.childNodes)) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (!this.runs) this.begin({ k: "li", ordered, number, depth: Math.max(0, this.listDepth - 1) });
        this.text(child.nodeValue, style);
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        const t = child.tagName.toUpperCase();
        if (t === "UL" || t === "OL") {
          this.flush();
          this.element(child, style);
        } else if (t === "P" || t === "DIV") {
          // Paragraphs inside an item continue the item.
          if (!this.runs) this.begin({ k: "li", ordered, number, depth: Math.max(0, this.listDepth - 1) });
          else this.text(" ", style);
          this.inline(child, style);
        } else {
          if (!this.runs) this.begin({ k: "li", ordered, number, depth: Math.max(0, this.listDepth - 1) });
          this.element(child, style);
        }
      }
    }
    this.flush();
  };

  // Page furniture that Readability tends to keep: infoboxes, navboxes, edit links, reference backlinks,
  // tables of contents, hatnotes ("For other uses, see…"), maintenance banners.
  const BOILERPLATE = [".infobox", ".navbox", ".vertical-navbox", ".sidebar", ".metadata", ".hatnote",
    ".mw-editsection", ".noprint", ".toc", "#toc", ".shortdescription", ".mw-jump-link", ".sistersitebox",
    ".catlinks", ".navigation-not-searchable", ".ambox", ".mw-cite-backlink", "sup.reference", ".portalbox",
    ".side-box", ".mbox-small", ".reflist", ".mw-references-wrap", "[role=navigation]", "[role=complementary]",
    ".sr-only", ".visually-hidden", ".screen-reader-text", ".share-buttons", ".social-share", ".newsletter-signup",
    "[data-testid=newsletter]", ".ad", ".advertisement", "[aria-label=advertisement]"];

  function removeBoilerplate(doc) {
    // Readability discards hidden nodes; collapsed sections (hidden="until-found", closed <details>) are real text.
    doc.querySelectorAll('[hidden="until-found"]').forEach(el => el.removeAttribute("hidden"));
    doc.querySelectorAll("details:not([open])").forEach(el => el.setAttribute("open", ""));
    for (const sel of BOILERPLATE) {
      try { doc.querySelectorAll(sel).forEach(el => el.remove()); } catch (e) { /* unsupported selector */ }
    }
  }

  // Trailing apparatus that is noise when listened to. "Notes" is kept when it is prose (essays), dropped
  // when it is a list of citations (encyclopedias).
  const APPARATUS = /^(references|external links|citations|sources|bibliography|further reading|see also|works cited|notes and references|references and notes|footnotes|related (articles|stories|reading)|read more|more from .*)$/i;

  function dropApparatus(blocks) {
    const out = [];
    let skipLevel = 0;
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (b.k === "h") {
        const text = b.runs.map(r => r.t).join("").trim();
        if (skipLevel && b.level > skipLevel) continue;
        skipLevel = 0;
        let drop = APPARATUS.test(text);
        if (!drop && /^notes$/i.test(text)) {
          let j = i + 1, items = 0, other = 0;
          for (; j < blocks.length && blocks[j].k !== "h"; j++) blocks[j].k === "li" ? items++ : other++;
          drop = items > 0 && other === 0;
        }
        if (drop) { skipLevel = b.level; continue; }
      } else if (skipLevel) {
        continue;
      }
      out.push(b);
    }
    return out;
  }

  const CORPORATE = /\b(inc|llc|ltd|limited|foundation|corporation|corp|gmbh|plc|s\.a|co)\b\.?,?\s*$/i;

  function meta(names) {
    for (const n of names) {
      const el = document.querySelector(`meta[property="${n}"], meta[name="${n}"], meta[itemprop="${n}"]`);
      const c = el && el.getAttribute("content");
      if (c && c.trim()) return c.trim();
    }
    return null;
  }

  // "Hummingbird - Wikipedia" → "Hummingbird": drop a trailing (or leading) segment that just names the site.
  function cleanTitle(title, siteName) {
    const t = (title || "").trim();
    const norm = x => (x || "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
    const host = (location.hostname || "").replace(/^www\./, "");
    const labels = host.split(".");
    const names = [norm(siteName), norm(host), norm(labels.length >= 2 ? labels[labels.length - 2] : host)].filter(Boolean);
    const parts = t.split(/\s+[-–—|·•]\s+/);
    if (parts.length < 2) return t;
    const last = norm(parts[parts.length - 1]), first = norm(parts[0]);
    const isSite = x => names.some(n => x === n || (x.length >= 4 && n.startsWith(x)));
    if (isSite(last)) return parts.slice(0, -1).join(" - ").trim() || t;
    if (isSite(first)) return parts.slice(1).join(" - ").trim() || t;
    return t;
  }

  // Wiki-style "Contributors to Wikimedia projects" and bare URLs aren't bylines worth showing.
  function cleanByline(b) {
    const t = (b || "").trim();
    if (!t || /^contributors to /i.test(t) || /^https?:\/\//i.test(t) || t.length > 120) return null;
    return t;
  }

  function countWords(blocks) {
    let n = 0;
    for (const b of blocks) {
      if (!b.runs || b.k === "caption") continue;
      for (const r of b.runs) n += (r.t.match(/[\p{L}\p{N}]+/gu) || []).length;
    }
    return n;
  }

  function looksBlocked() {
    const t = (document.title + " " + (document.body ? document.body.innerText.slice(0, 3000) : "")).toLowerCase();
    const signals = ["subscribe to continue", "subscribe to read", "to continue reading", "create a free account",
      "sign in to continue", "log in to continue", "this content is for subscribers", "already a subscriber",
      "verify you are human", "are you a robot", "checking your browser", "enable javascript and cookies",
      "access denied", "unusual traffic", "captcha", "just a moment"];
    return signals.find(s => t.includes(s)) || null;
  }

  // Publishers mark metered/paywalled articles for search engines with schema.org isAccessibleForFree=false.
  function markedPaywalled() {
    for (const script of Array.from(document.querySelectorAll('script[type="application/ld+json"]'))) {
      if (/"isAccessibleForFree"\s*:\s*("?false"?|"False")/i.test(script.textContent || "")) return true;
    }
    const m = document.querySelector('meta[itemprop="isAccessibleForFree"]');
    return !!(m && /false/i.test(m.getAttribute("content") || ""));
  }

  window.__readAloudExtract = function (mode) {
    try {
      const base = {
        lang: document.documentElement.getAttribute("lang") || meta(["og:locale", "language"]),
        leadImage: absolute(meta(["og:image", "og:image:url", "twitter:image", "twitter:image:src"])),
        publishedTime: meta(["article:published_time", "datePublished", "pubdate", "date", "dc.date"]),
        pageTitle: document.title || null,
      };
      let article = null;
      let root = null;
      if (mode !== "wholePage" && typeof Readability !== "undefined") {
        const clone = document.cloneNode(true);
        removeBoilerplate(clone);
        article = new Readability(clone, { charThreshold: 250, keepClasses: false }).parse();
        if (article && article.content) {
          const parsed = new DOMParser().parseFromString(article.content, "text/html");
          root = parsed.body;
        }
      }
      if (!root && document.body) {
        const clone = document.cloneNode(true);
        removeBoilerplate(clone);
        root = clone.body;
      }
      const walker = new Walker();
      if (root) walker.inline(root, {});
      walker.flush();
      const blocks = dropApparatus(walker.blocks);
      const readabilitySite = article && article.siteName && !CORPORATE.test(article.siteName) ? article.siteName : null;
      const wordCount = countWords(blocks);
      const blocked = looksBlocked();
      const siteName = meta(["og:site_name", "application-name"]) || readabilitySite;
      return JSON.stringify({
        ok: wordCount >= 60 || (wordCount >= 25 && !blocked),
        usedReadability: !!article,
        title: cleanTitle((article && article.title) || meta(["og:title", "twitter:title"]) || document.title || "", siteName),
        byline: cleanByline((article && article.byline) || meta(["author", "article:author", "parsely-author"])),
        siteName,
        excerpt: (article && article.excerpt) || meta(["description", "og:description"]),
        lang: (article && article.lang) || base.lang,
        leadImage: base.leadImage,
        publishedTime: (article && article.publishedTime) || base.publishedTime,
        blocks,
        wordCount,
        reason: blocked,
        // Only part of a paywalled article came through (a teaser before the subscribe prompt).
        preview: wordCount < 450 && (markedPaywalled() || !!blocked),
      });
    } catch (e) {
      return JSON.stringify({ ok: false, error: String(e && e.stack || e), blocks: [], wordCount: 0 });
    }
  };
})();
