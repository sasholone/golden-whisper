/* util.js - namespace GW, helper DOM sicuri (mai innerHTML), sanificazione, throttle. */
(function (root) {
  'use strict';
  var GW = root.GW || (root.GW = {});

  var SVGNS = 'http://www.w3.org/2000/svg';

  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
  function isNum(v) { return typeof v === 'number' && isFinite(v); }
  function asNum(v) {
    if (typeof v === 'string' && v.trim() !== '') v = Number(v);
    return isNum(v) ? v : null;
  }
  function asBool(v, d) {
    if (v === true || v === 'true' || v === 1 || v === '1') return true;
    if (v === false || v === 'false' || v === 0 || v === '0') return false;
    return d;
  }

  /* Testo che arriva dal sistema (nomi microfono, messaggi): sempre stringa, senza caratteri di controllo, con tetto. */
  function cleanText(v, max) {
    if (v === null || v === undefined) return '';
    var s = String(v).replace(/[\u0000-\u001f\u007f-\u009f  ]/g, ' ').trim();
    max = max || 200;
    return s.length > max ? s.slice(0, max - 1) + '…' : s;
  }
  var HEX = /^#?[0-9a-fA-F]{6}$/;
  function cleanHex(v, d) {
    if (typeof v !== 'string' || !HEX.test(v.trim())) return d;
    v = v.trim();
    return (v[0] === '#' ? v : '#' + v).toLowerCase();
  }
  /* URL asset: solo file:, data:image, blob:. Mai http(s). */
  function cleanUrl(v) {
    if (typeof v !== 'string') return null;
    if (/^(file:\/\/|blob:|data:image\/(png|gif|jpeg|webp|svg\+xml);)/i.test(v) && v.length < 2e6) return v;
    return null;
  }

  /* h('div', {class:'x', text:'ciao', on:{click:fn}, aria:{label:'..'}, data:{id:'..'}, style:{'--p':'1'}}, [children]) */
  function h(tag, attrs, kids) {
    var el = document.createElement(tag);
    if (attrs) {
      for (var k in attrs) {
        var v = attrs[k];
        if (v === undefined || v === null || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = v;
        else if (k === 'on') { for (var ev in v) el.addEventListener(ev, v[ev]); }
        else if (k === 'aria') { for (var a in v) el.setAttribute('aria-' + a, v[a]); }
        else if (k === 'data') { for (var d in v) el.dataset[d] = v[d]; }
        else if (k === 'style') { for (var s in v) el.style.setProperty(s, v[s]); }
        else if (k === 'props') { for (var p in v) el[p] = v[p]; }
        else el.setAttribute(k, v === true ? '' : v);
      }
    }
    append(el, kids);
    return el;
  }
  function append(el, kids) {
    if (kids === undefined || kids === null) return el;
    if (!Array.isArray(kids)) kids = [kids];
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) append(el, c);
      else el.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c)));
    }
    return el;
  }
  function svg(tag, attrs, kids) {
    var el = document.createElementNS(SVGNS, tag);
    if (attrs) for (var k in attrs) { if (attrs[k] !== undefined && attrs[k] !== null) el.setAttribute(k, attrs[k]); }
    if (kids) for (var i = 0; i < kids.length; i++) el.appendChild(kids[i]);
    return el;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

  function throttle(fn, ms) {
    var last = 0, timer = null, pendingArgs = null;
    function run() { timer = null; last = Date.now(); var a = pendingArgs; pendingArgs = null; fn.apply(null, a); }
    var t = function () {
      pendingArgs = arguments;
      var wait = ms - (Date.now() - last);
      if (wait <= 0) { if (timer) { clearTimeout(timer); timer = null; } run(); }
      else if (!timer) timer = setTimeout(run, wait);
    };
    t.flush = function () { if (timer) { clearTimeout(timer); timer = null; if (pendingArgs) run(); } };
    return t;
  }

  GW.util = { SVGNS: SVGNS, clamp: clamp, isNum: isNum, asNum: asNum, asBool: asBool, cleanText: cleanText, cleanHex: cleanHex,
    cleanUrl: cleanUrl, h: h, svg: svg, append: append, clear: clear, throttle: throttle };
  if (typeof module !== 'undefined') module.exports = GW.util;
})(typeof globalThis !== 'undefined' ? globalThis : this);
