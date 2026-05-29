#!/usr/bin/env node
// ============================================================
// renderer.js — extracted EBNF IR  ->  railroad SVG + index.html
// ============================================================
//
// Reads grammar.ebnf.json (emitted by the extractor) and writes one
// SVG per rule plus a cross-linked index.html in the SQLite "factored"
// presentation: every rule drawn separately, sub-rules linked rather
// than inlined.
//
// Self-contained: the tabatkins `railroad-diagrams` package can't be
// fetched in this environment (network-restricted), so this emits the
// same visual vocabulary directly — rounded-stadium terminals, square
// linked nonterminals, branching choices, optional bypasses, and
// return-loops with the separator on the back-rail.
//
//   node renderer.js   # run from railroad/, after the gate passes
//
// Per railroad-diagrams.md scope: whitespace is not drawn; keywords are
// uppercase terminals; identifier / string-literal / integer-literal /
// decimal-literal are lexical leaf terminals (a single box, with the
// prose note below the diagrams), not expanded.

'use strict';
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const IR = JSON.parse(fs.readFileSync(path.join(HERE, 'grammar.ebnf.json'), 'utf8'));

// --- geometry constants -------------------------------------
const AR = 10;          // arc radius
const CHARW = 7.3;      // approx width of a 13px monospace glyph
const TH = 22;          // token box height
const TUP = 11, TDOWN = 11;
const VS = 12;          // vertical separation between branches
const HG = 12;          // horizontal gap inside a sequence
const PAD = 20;         // diagram outer padding

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
                  .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function tw(text) { return Math.max(text.length * CHARW, 12); }
function hline(x1, y, x2) {
  if (x2 === x1) return '';
  return `<path class="rail" d="M${x1} ${y} H${x2}"/>`;
}
// quarter-circle arc; dir in {ne,nw,se,sw,en,wn,es,ws} naming start->end tangents.
// We build explicit arcs in each element instead, for clarity.
function arc(x, y, dx, dy, sweep) {
  return `<path class="rail" d="M${x} ${y} A${AR} ${AR} 0 0 ${sweep} ${x + dx} ${y + dy}"/>`;
}

// --- leaf/terminal/nonterminal ------------------------------
function terminal(text, cls) {
  const w = tw(text) + 20;
  return { w, up: TUP, down: TDOWN, draw(x, y) {
    return `<g class="${cls}">`
      + `<rect x="${x}" y="${y - TUP}" width="${w}" height="${TH}" rx="11" ry="11"/>`
      + `<text x="${x + w / 2}" y="${y + 4}">${esc(text)}</text></g>`;
  }};
}
function nonterminal(name) {
  const w = tw(name) + 20;
  return { w, up: TUP, down: TDOWN, draw(x, y) {
    return `<a xlink:href="#${esc(name)}" href="#${esc(name)}"><g class="nonterminal">`
      + `<rect x="${x}" y="${y - TUP}" width="${w}" height="${TH}"/>`
      + `<text x="${x + w / 2}" y="${y + 4}">${esc(name)}</text></g></a>`;
  }};
}
function emptyLine(w) { return { w, up: 0, down: 0, draw(x, y) { return hline(x, y, x + w); } }; }

// --- sequence -----------------------------------------------
function sequence(items) {
  if (items.length === 0) return emptyLine(HG);
  const up = Math.max(...items.map(i => i.up));
  const down = Math.max(...items.map(i => i.down));
  const w = items.reduce((a, i) => a + i.w, 0) + HG * (items.length - 1);
  return { w, up, down, draw(x, y) {
    let s = '', cx = x;
    items.forEach((it, idx) => {
      if (idx > 0) { s += hline(cx, y, cx + HG); cx += HG; }
      s += it.draw(cx, y); cx += it.w;
    });
    return s;
  }};
}

// --- choice -------------------------------------------------
// First branch runs straight through on the baseline; the rest fan out
// below, each reached by a left arc-rail and rejoined by a right one.
function choice(items) {
  const innerW = Math.max(...items.map(i => i.w));
  const offs = [0];
  for (let i = 1; i < items.length; i++) {
    offs[i] = offs[i - 1] + items[i - 1].down + VS + items[i].up;
  }
  const up = items[0].up;
  const lastBase = offs[items.length - 1];
  const down = Math.max(items[0].down, lastBase + items[items.length - 1].down);
  const w = innerW + 4 * AR;
  return { w, up, down, draw(x, y) {
    const xi = x + 2 * AR, xr = xi + innerW, xe = x + w;
    let s = '';
    items.forEach((it, i) => {
      const yi = y + offs[i];
      const pad = innerW - it.w;
      if (i === 0) {
        s += hline(x, y, xi) + it.draw(xi, y) + hline(xi + it.w, y, xr) + hline(xr, y, xe);
      } else {
        // left rail: baseline -> down -> into branch
        s += arc(x, y, AR, AR, 1);                       // turn down
        s += `<path class="rail" d="M${x + AR} ${y + AR} V${yi - AR}"/>`;
        s += arc(x + AR, yi - AR, AR, AR, 0);            // turn right
        s += it.draw(xi, yi) + hline(xi + it.w, yi, xr);
        // right rail: branch -> up -> baseline
        s += arc(xr, yi, AR, -AR, 0);                    // turn up
        s += `<path class="rail" d="M${xr + AR} ${yi - AR} V${y + AR}"/>`;
        s += arc(xr + AR, y + AR, AR, -AR, 1);           // turn right onto baseline
      }
    });
    return s;
  }};
}

// --- optional (bypass on top, content below) ----------------
function optional(item) {
  return choice([emptyLine(item.w), item]);
}

// --- one-or-more / zero-or-more loops -----------------------
// Forward item on the baseline; a return rail loops back BELOW it,
// carrying the separator (drawn on the back-rail) with a left arrow.
function oneOrMore(item, rep) {
  const innerW = Math.max(item.w, rep ? rep.w : 0);
  const w = innerW + 2 * AR;
  const up = item.up;
  const repUp = rep ? rep.up : 0;
  const repDown = rep ? rep.down : 0;
  const repDy = item.down + VS + Math.max(repUp, AR);
  const down = repDy + Math.max(repDown, AR);
  return { w, up, down, draw(x, y) {
    const xi = x + AR, xr = x + w - AR, xe = x + w, yRep = y + repDy;
    let s = '';
    // forward
    s += hline(x, y, xi) + item.draw(xi, y) + hline(xi + item.w, y, xr) + hline(xr, y, xe);
    // right rail down
    s += arc(xr, y, AR, AR, 0);
    s += `<path class="rail" d="M${xe} ${y + AR} V${yRep - AR}"/>`;
    s += arc(xe, yRep - AR, -AR, AR, 0);
    // bottom rail (right -> left) with optional separator + arrow
    if (rep) {
      const pad = innerW - rep.w;
      s += hline(xr, yRep, xr - Math.floor(pad / 2));
      s += rep.draw(xi + Math.ceil(pad / 2), yRep);
      s += hline(x + AR, yRep, xi + Math.ceil(pad / 2));
    } else {
      s += hline(xi, yRep, xr);
    }
    // left arrow mid bottom
    const xm = x + w / 2;
    s += `<path class="arrow" d="M${xm + 5} ${yRep - 4} L${xm - 5} ${yRep} L${xm + 5} ${yRep + 4} Z"/>`;
    // left rail up
    s += arc(xi, yRep, -AR, -AR, 0);
    s += `<path class="rail" d="M${x} ${yRep - AR} V${y + AR}"/>`;
    s += arc(x, y + AR, AR, -AR, 0);
    return s;
  }};
}
function zeroOrMore(item) { return optional(oneOrMore(item, null)); }

// --- IR node -> element -------------------------------------
function build(node) {
  switch (node.t) {
    case 'term':  return terminal(node.text, 'terminal');
    case 'leaf':  return terminal(node.name, 'leaf');
    case 'nt':    return nonterminal(node.name);
    case 'eps':   return emptyLine(HG);
    case 'seq':   return sequence(node.items.map(build));
    case 'choice':return choice(node.items.map(build));
    case 'opt':   return optional(build(node.item));
    case 'zeroOrMore': return zeroOrMore(build(node.item));
    case 'oneOrMore':  return oneOrMore(build(node.item), node.sep ? build(node.sep) : null);
    default: throw new Error('unknown node: ' + JSON.stringify(node));
  }
}

// --- diagram wrapper (entry/exit terminators + viewBox) -----
function diagram(node) {
  const el = build(node);
  const startW = 20, endW = 20;
  const w = el.w + startW + endW + PAD * 2;
  const h = el.up + el.down + PAD * 2;
  const y = PAD + el.up;
  const x0 = PAD;
  let s = `<svg class="railroad" xmlns="http://www.w3.org/2000/svg" `
        + `xmlns:xlink="http://www.w3.org/1999/xlink" `
        + `width="${Math.ceil(w)}" height="${Math.ceil(h)}" `
        + `viewBox="0 0 ${Math.ceil(w)} ${Math.ceil(h)}">`;
  // entry terminator
  s += `<g class="terminator"><circle cx="${x0 + 6}" cy="${y}" r="5"/></g>`;
  s += hline(x0 + 11, y, x0 + startW);
  s += el.draw(x0 + startW, y);
  const xe = x0 + startW + el.w;
  s += hline(xe, y, xe + endW - 11);
  s += `<g class="terminator"><circle cx="${xe + endW - 6}" cy="${y}" r="5"/></g>`;
  s += `</svg>`;
  return s;
}

// --- page ---------------------------------------------------
const CSS = `
:root { --term:#d7f0d7; --termb:#3a8a3a; --nt:#e3ecfb; --ntb:#3a5a9a; --leaf:#fbeede; --leafb:#b8862b; --rail:#444; }
body { font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; margin: 0; color:#1a1a1a; }
header { background:#1f2a3a; color:#fff; padding:18px 28px; }
header h1 { margin:0 0 4px; font-size:20px; }
header p { margin:0; opacity:.8; font-size:13px; }
.wrap { display:flex; }
nav { position:sticky; top:0; align-self:flex-start; max-height:100vh; overflow:auto;
      width:230px; padding:16px; border-right:1px solid #e2e2e2; font-size:13px; background:#fafafa; }
nav a { display:block; color:#26538f; text-decoration:none; padding:2px 4px; border-radius:4px; }
nav a:hover { background:#eef3fb; }
main { flex:1; padding:8px 28px 80px; max-width:1100px; }
section { padding:16px 0; border-bottom:1px solid #eee; }
section h2 { font-size:16px; margin:0 0 6px; font-family:ui-monospace, Menlo, Consolas, monospace; }
section h2 a.self { color:#bbb; text-decoration:none; font-weight:normal; }
.ebnf { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:12px; color:#555;
        background:#f6f6f6; padding:6px 8px; border-radius:5px; margin:4px 0 10px; white-space:pre-wrap; }
.note { font-size:13px; color:#555; background:#fff8ec; border-left:3px solid var(--leafb);
        padding:8px 12px; margin:8px 0; border-radius:0 5px 5px 0; }
svg.railroad { display:block; max-width:100%; }
svg .rail, svg .arrow { fill:none; stroke:var(--rail); stroke-width:1.6; }
svg .arrow { fill:var(--rail); }
svg text { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:13px; text-anchor:middle; }
svg .terminal rect { fill:var(--term); stroke:var(--termb); stroke-width:1.4; }
svg .terminal text { fill:#143a14; }
svg .leaf rect { fill:var(--leaf); stroke:var(--leafb); stroke-width:1.4; stroke-dasharray:4 2; }
svg .leaf text { fill:#5a3d05; font-style:italic; }
svg .nonterminal rect { fill:var(--nt); stroke:var(--ntb); stroke-width:1.4; }
svg .nonterminal text { fill:#142a5a; }
svg a:hover .nonterminal rect { fill:#cfe0fb; }
svg .terminator circle { fill:#fff; stroke:var(--rail); stroke-width:1.8; }
`;

const LEAF_NOTE = {
  identifier: 'A DBISAM identifier: a bare word (letter/underscore then letters, digits, underscores), a <code>"double-quoted"</code> name, or a <code>[bracketed]</code> name (bracket contents must still be a valid bare identifier). Drawn as a single terminal; the three lexical forms are not expanded.',
  string_literal: "A single-quoted string with SQL-standard doubled-quote escaping (<code>'O''Brien'</code>). Backslashes are literal.",
  integer_literal: 'A run of decimal digits.',
  decimal_literal: 'A decimal / float literal: <code>3.14</code>, <code>.5</code>, <code>5.</code>, <code>1.5e3</code>, <code>1E-5</code>, etc.'
};

function ebnfText(node) {
  switch (node.t) {
    case 'term': return '"' + node.text + '"';
    case 'leaf': return node.name;
    case 'nt': return node.name;
    case 'eps': return '(* empty *)';
    case 'opt': return '[ ' + ebnfText(node.item) + ' ]';
    case 'zeroOrMore': return '{ ' + ebnfText(node.item) + ' }';
    case 'oneOrMore': return ebnfText(node.item) + ' { ' + (node.sep ? ebnfText(node.sep) + ' ' : '') + ebnfText(node.item) + ' }';
    case 'seq': return node.items.map(n => n.t === 'choice' ? '( ' + ebnfText(n) + ' )' : ebnfText(n)).join(' ');
    case 'choice': return node.items.map(ebnfText).join(' | ');
  }
}

function main() {
  const outDir = path.join(HERE, 'diagrams');
  fs.mkdirSync(outDir, { recursive: true });
  const ruleByName = {};
  IR.rules.forEach(r => { ruleByName[r.name] = r.node; });

  // per-rule SVG files + collect for the page
  const sections = [];
  IR.order.forEach(name => {
    const node = ruleByName[name];
    if (!node) return;
    const svg = diagram(node);
    fs.writeFileSync(path.join(outDir, name + '.svg'), svg);
    sections.push({ name, svg, ebnf: ebnfText(node) });
  });

  // leaves get a documented terminal-note section (no diagram)
  const leafSections = IR.leaves.map(name => ({ name, note: LEAF_NOTE[name] || 'Lexical terminal.' }));

  const nav = IR.order.filter(n => ruleByName[n])
    .map(n => `<a href="#${esc(n)}">${esc(n)}</a>`).join('\n')
    + '\n<hr>\n'
    + leafSections.map(l => `<a href="#${esc(l.name)}"><em>${esc(l.name)}</em></a>`).join('\n');

  let body = '';
  sections.forEach(s => {
    body += `<section id="${esc(s.name)}">`
      + `<h2>${esc(s.name)} <a class="self" href="#${esc(s.name)}">#</a></h2>`
      + `<div class="ebnf">${esc(s.name)} ::= ${esc(s.ebnf)}</div>`
      + s.svg + `</section>\n`;
  });
  leafSections.forEach(l => {
    body += `<section id="${esc(l.name)}"><h2><em>${esc(l.name)}</em> (lexical leaf)</h2>`
      + `<div class="note">${l.note}</div></section>\n`;
  });

  const html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DBISAM SQL — Railroad Diagrams</title>
<style>${CSS}</style></head>
<body>
<header>
  <h1>DBISAM SQL — Syntax (Railroad) Diagrams</h1>
  <p>Derived mechanically from <code>grammar/dcg.pl</code> by <code>railroad/extractor.pl</code>;
     verified equivalent to the DCG by the railroad gate. Whitespace and keyword casing are not drawn.</p>
</header>
<div class="wrap">
<nav>${nav}</nav>
<main>
<section>
  <div class="note">Green stadiums are <strong>keyword / literal terminals</strong>.
  Blue boxes are <strong>nonterminals</strong> — click to jump to their rule.
  Dashed amber stadiums are <strong>lexical leaves</strong> (see the bottom of the page).
  Comma / separator loops are the collapsed <code>_list</code> idiom drawn as a single repeat.</div>
</section>
${body}
</main></div></body></html>`;

  fs.writeFileSync(path.join(HERE, 'index.html'), html);
  console.log(`renderer: wrote ${sections.length} SVGs + index.html (${leafSections.length} lexical leaves noted)`);
}

main();
