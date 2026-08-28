// ============================================================
// renderer.js — extracted EBNF IR  ->  railroad SVG + index.html
// ============================================================
//
// Reads grammar.ebnf.json (emitted by the extractor) and writes one
// SVG per rule plus a cross-linked index.html in the SQLite "factored"
// presentation: every rule drawn separately, sub-rules linked rather
// than inlined.
//
// SVG geometry comes from the vendored `railroad-diagrams` library
// (vendor/railroad.js, CC0 — see vendor/README.md). This file only maps
// the extractor's IR onto the library's constructors and assembles the
// page; it draws no rails itself.
//
//   node renderer.js   # run from railroad/, after the gate passes
//
// Per railroad-diagrams.md scope: whitespace is not drawn; keywords are
// uppercase terminals; identifier / string-literal / integer-literal /
// decimal-literal are lexical leaf terminals (a single box, with the
// prose note below the diagrams), not expanded.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import rr from './vendor/railroad.js';

const { Diagram, Terminal, NonTerminal, Sequence, Choice, Optional, OneOrMore, ZeroOrMore, Skip } = rr;

const HERE = path.dirname(fileURLToPath(import.meta.url));
const IR = JSON.parse(fs.readFileSync(path.join(HERE, 'grammar.ebnf.json'), 'utf8'));

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
                  .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// --- IR node -> railroad-diagrams element -------------------
// Leaves carry the `leaf` class for the dashed-amber lexical styling;
// nonterminals get an href so the diagram cross-links to their rule.
function build(node) {
  switch (node.t) {
    case 'term':       return Terminal(node.text);
    case 'leaf':       return Terminal(node.name, { cls: 'leaf' });
    case 'nt':         return NonTerminal(node.name, { href: '#' + node.name });
    case 'eps':        return Skip();
    case 'seq':        return node.items.length ? Sequence(...node.items.map(build)) : Skip();
    case 'choice':     return Choice(0, ...node.items.map(build));
    case 'opt':        return Optional(build(node.item));
    case 'zeroOrMore': return ZeroOrMore(build(node.item));
    case 'oneOrMore':  return OneOrMore(build(node.item), node.sep ? build(node.sep) : undefined);
    default: throw new Error('unknown node: ' + JSON.stringify(node));
  }
}

// Bare SVG (no embedded <style>) for inlining into the page, which
// carries one shared stylesheet.
function svgFor(node) { return Diagram(build(node)).toString(); }
// Self-contained SVG with its own <style>, for the standalone .svg file.
function standaloneSvgFor(node) { return Diagram(build(node)).toStandalone(RAIL_CSS); }

// --- styling ------------------------------------------------
// Recolour the library's classes to the project palette: green keyword
// terminals, blue linked nonterminals, dashed-amber lexical leaves.
const RAIL_CSS = `
svg.railroad-diagram { background: transparent; }
svg.railroad-diagram path { stroke-width: 2; stroke: #444; fill: none; }
svg.railroad-diagram text { font: bold 13px ui-monospace, Menlo, Consolas, monospace; text-anchor: middle; }
svg.railroad-diagram text.comment { font: italic 12px ui-monospace, Menlo, Consolas, monospace; }
svg.railroad-diagram rect { stroke-width: 1.6px; stroke: #3a8a3a; fill: #d7f0d7; }
svg.railroad-diagram g.terminal text { fill: #143a14; }
svg.railroad-diagram g.non-terminal rect { stroke: #3a5a9a; fill: #e3ecfb; }
svg.railroad-diagram g.non-terminal text { fill: #142a5a; }
svg.railroad-diagram g.terminal.leaf rect { stroke: #b8862b; fill: #fbeede; stroke-dasharray: 4 2; }
svg.railroad-diagram g.terminal.leaf text { fill: #5a3d05; font-style: italic; }
svg.railroad-diagram a:hover g.non-terminal rect { fill: #cfe0fb; }
`;

const PAGE_CSS = `
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
.note { font-size:13px; color:#555; background:#fff8ec; border-left:3px solid #b8862b;
        padding:8px 12px; margin:8px 0; border-radius:0 5px 5px 0; }
svg.railroad-diagram { display:block; max-width:100%; height:auto; margin:4px 0; }
`;

const LEAF_NOTE = {
  identifier: 'A DBISAM identifier: a bare word (letter/underscore then letters, digits, underscores), a <code>"double-quoted"</code> name, or a <code>[bracketed]</code> name (bracket contents must still be a valid bare identifier). Drawn as a single terminal; the three lexical forms are not expanded.',
  string_literal: "A single-quoted string with SQL-standard doubled-quote escaping (<code>'O''Brien'</code>). Backslashes are literal.",
  integer_literal: 'A run of decimal digits.',
  decimal_literal: 'A decimal / float literal: <code>3.14</code>, <code>.5</code>, <code>5.</code>, <code>1.5e3</code>, <code>1E-5</code>, etc.'
};

// EBNF one-liner shown above each diagram (unchanged from the IR).
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

  // per-rule SVG files (standalone) + collect bare SVGs for the page
  const sections = [];
  IR.order.forEach(name => {
    const node = ruleByName[name];
    if (!node) return;
    fs.writeFileSync(path.join(outDir, name + '.svg'), standaloneSvgFor(node));
    sections.push({ name, svg: svgFor(node), ebnf: ebnfText(node) });
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
<style>${PAGE_CSS}${RAIL_CSS}</style></head>
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
