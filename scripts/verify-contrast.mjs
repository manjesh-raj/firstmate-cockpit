// Single source of truth for the Helm theme tokens.
// Converts OKLCH -> sRGB -> WCAG relative luminance, verifies contrast for every
// theme's key text/UI pairs against WCAG AA, and emits the CSS :root blocks.
//
// This is the single source of truth for the shipped theme token values in
// backend/static/index.html — the CSS blocks there were emitted by `css` below.
//
// Run:  node scripts/verify-contrast.mjs verify   (contrast report + pass/fail gate)
//       node scripts/verify-contrast.mjs css       (emit the CSS token blocks)

'use strict';

/* ---- OKLCH -> linear sRGB -> sRGB (matches CSS Color 4 / browsers) ---- */
function oklchToSrgb(L, C, hDeg) {
  const h = (hDeg * Math.PI) / 180;
  const a = C * Math.cos(h);
  const b = C * Math.sin(h);
  // OKLab -> LMS
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
  // LMS -> linear sRGB
  let r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
  return [r, g, bl]; // linear, may be out of [0,1]
}
function clamp01(x) { return Math.min(1, Math.max(0, x)); }
function linToSrgb(c) { c = clamp01(c); return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; }
function relLuminance(L, C, h) {
  const [r, g, b] = oklchToSrgb(L, C, h);
  // WCAG luminance uses linear-light values; our linear rgb (clamped) is exactly that.
  return 0.2126 * clamp01(r) + 0.7152 * clamp01(g) + 0.0722 * clamp01(b);
}
function contrast(fg, bg) {
  const L1 = relLuminance(...fg), L2 = relLuminance(...bg);
  const hi = Math.max(L1, L2), lo = Math.min(L1, L2);
  return (hi + 0.05) / (lo + 0.05);
}
function hex(L, C, h) {
  const [r, g, b] = oklchToSrgb(L, C, h).map(linToSrgb).map(clamp01);
  const to = (x) => Math.round(x * 255).toString(16).padStart(2, '0');
  return '#' + to(r) + to(g) + to(b);
}

/* Each token is [L, C, hue]. Tints are derived in CSS via color-mix. */
const THEMES = [
  // ---------------- DARK ----------------
  { id: 'helm-dark', name: 'Helm Dark', mode: 'dark', t: {
    bg:[0.165,0.017,250], bg2:[0.135,0.016,250], surface:[0.205,0.019,250], surface2:[0.245,0.021,250],
    hover:[0.285,0.022,250], line:[0.345,0.02,250], lineSoft:[0.275,0.018,250],
    ink:[0.965,0.006,240], muted:[0.775,0.016,240], faint:[0.635,0.017,245],
    accent:[0.82,0.10,205], accent2:[0.88,0.085,200], accentInk:[0.20,0.04,220],
    ok:[0.80,0.15,155], need:[0.84,0.145,84], needInk:[0.24,0.05,80], bad:[0.72,0.16,25], info:[0.77,0.10,250],
    termBg:[0.135,0.015,250] } },
  { id: 'midnight', name: 'Midnight', mode: 'dark', t: {
    bg:[0.155,0.028,262], bg2:[0.128,0.026,262], surface:[0.20,0.03,262], surface2:[0.24,0.032,262],
    hover:[0.285,0.034,262], line:[0.35,0.032,262], lineSoft:[0.275,0.028,262],
    ink:[0.96,0.01,255], muted:[0.775,0.024,255], faint:[0.63,0.026,258],
    accent:[0.78,0.12,242], accent2:[0.85,0.10,240], accentInk:[0.17,0.05,255],
    ok:[0.80,0.15,155], need:[0.84,0.14,86], needInk:[0.24,0.05,80], bad:[0.72,0.16,25], info:[0.80,0.10,250],
    termBg:[0.13,0.026,262] } },
  { id: 'graphite', name: 'Graphite', mode: 'dark', t: {
    bg:[0.175,0.005,285], bg2:[0.145,0.005,285], surface:[0.215,0.006,285], surface2:[0.255,0.007,285],
    hover:[0.295,0.008,285], line:[0.355,0.009,285], lineSoft:[0.285,0.007,285],
    ink:[0.965,0.003,285], muted:[0.775,0.006,285], faint:[0.635,0.008,285],
    accent:[0.80,0.12,300], accent2:[0.86,0.10,300], accentInk:[0.18,0.05,300],
    ok:[0.80,0.15,155], need:[0.83,0.145,82], needInk:[0.24,0.05,80], bad:[0.72,0.16,25], info:[0.77,0.10,250],
    termBg:[0.145,0.005,285] } },
  { id: 'nocturne', name: 'Nocturne', mode: 'dark', t: {
    bg:[0.165,0.018,300], bg2:[0.138,0.017,300], surface:[0.205,0.02,300], surface2:[0.245,0.022,300],
    hover:[0.285,0.024,300], line:[0.345,0.022,300], lineSoft:[0.275,0.02,300],
    ink:[0.965,0.006,320], muted:[0.775,0.016,320], faint:[0.635,0.018,315],
    accent:[0.78,0.13,345], accent2:[0.85,0.11,345], accentInk:[0.20,0.06,345],
    ok:[0.80,0.15,155], need:[0.84,0.145,84], needInk:[0.24,0.05,80], bad:[0.72,0.16,25], info:[0.77,0.10,255],
    termBg:[0.138,0.016,300] } },
  // ---------------- LIGHT ----------------
  { id: 'helm-light', name: 'Helm Light', mode: 'light', t: {
    bg:[0.955,0.006,245], bg2:[0.925,0.008,245], surface:[0.995,0.002,245], surface2:[0.975,0.005,245],
    hover:[0.945,0.008,245], line:[0.87,0.014,245], lineSoft:[0.915,0.009,245],
    ink:[0.29,0.03,255], muted:[0.455,0.028,255], faint:[0.52,0.026,255],
    accent:[0.50,0.12,222], accent2:[0.44,0.12,225], accentInk:[0.99,0.005,245],
    ok:[0.50,0.14,158], need:[0.52,0.135,66], needInk:[0.99,0.005,80], bad:[0.53,0.19,27], info:[0.51,0.12,250],
    termBg:[0.975,0.004,245] } },
  { id: 'paper', name: 'Paper', mode: 'light', t: {
    bg:[0.955,0.012,80], bg2:[0.925,0.014,80], surface:[0.995,0.004,80], surface2:[0.975,0.01,80],
    hover:[0.945,0.014,80], line:[0.87,0.02,80], lineSoft:[0.915,0.014,80],
    ink:[0.30,0.03,70], muted:[0.46,0.03,70], faint:[0.52,0.028,72],
    accent:[0.49,0.15,305], accent2:[0.42,0.15,305], accentInk:[0.99,0.004,80],
    ok:[0.50,0.14,158], need:[0.52,0.14,64], needInk:[0.99,0.005,80], bad:[0.53,0.19,27], info:[0.51,0.12,290],
    termBg:[0.975,0.008,80] } },
  { id: 'frost', name: 'Frost', mode: 'light', t: {
    bg:[0.955,0.008,240], bg2:[0.925,0.01,240], surface:[0.995,0.003,240], surface2:[0.975,0.006,240],
    hover:[0.945,0.01,240], line:[0.87,0.016,240], lineSoft:[0.915,0.01,240],
    ink:[0.29,0.035,250], muted:[0.45,0.03,250], faint:[0.52,0.028,250],
    accent:[0.51,0.14,248], accent2:[0.44,0.14,250], accentInk:[0.99,0.004,240],
    ok:[0.50,0.14,158], need:[0.52,0.135,66], needInk:[0.99,0.005,80], bad:[0.53,0.19,27], info:[0.51,0.13,248],
    termBg:[0.975,0.005,240] } },
  { id: 'linen', name: 'Linen', mode: 'light', t: {
    bg:[0.95,0.012,60], bg2:[0.92,0.014,60], surface:[0.99,0.006,60], surface2:[0.968,0.011,60],
    hover:[0.94,0.014,60], line:[0.865,0.02,60], lineSoft:[0.91,0.014,60],
    ink:[0.29,0.028,55], muted:[0.455,0.026,58], faint:[0.52,0.024,58],
    accent:[0.48,0.11,200], accent2:[0.42,0.11,202], accentInk:[0.99,0.004,200],
    ok:[0.50,0.14,158], need:[0.52,0.14,62], needInk:[0.99,0.005,80], bad:[0.53,0.19,27], info:[0.51,0.12,250],
    termBg:[0.968,0.008,60] } },
];

/* Pairs to verify. label: [fgToken, bgToken, minRatio, kind] */
const PAIRS = [
  ['ink / surface', 'ink', 'surface', 4.5, 'body'],
  ['ink / bg', 'ink', 'bg', 4.5, 'body'],
  ['ink / surface2', 'ink', 'surface2', 4.5, 'body'],
  ['muted / surface', 'muted', 'surface', 4.5, 'body'],
  ['muted / bg', 'muted', 'bg', 4.5, 'body'],
  ['faint / surface', 'faint', 'surface', 4.5, 'body'],
  ['accent / surface', 'accent', 'surface', 4.5, 'link'],
  ['accent / bg', 'accent', 'bg', 4.5, 'link'],
  ['accentInk / accent', 'accentInk', 'accent', 4.5, 'btn'],
  ['ok / surface', 'ok', 'surface', 4.5, 'state'],
  ['need / surface', 'need', 'surface', 4.5, 'state'],
  ['needInk / need', 'needInk', 'need', 4.5, 'on-amber'],
  ['bad / surface', 'bad', 'surface', 4.5, 'state'],
  ['info / surface', 'info', 'surface', 4.5, 'state'],
];

/* Mix two OKLCH colors in oklab space (matches CSS color-mix(in oklab,...)). */
function mixOklab(cA, pctA, cB) {
  // cA at pctA%, cB filling the rest. Convert both to oklab, lerp, back to oklch-ish [L,C,h].
  const toLab = ([L, C, h]) => [L, C * Math.cos((h * Math.PI) / 180), C * Math.sin((h * Math.PI) / 180)];
  const [La, aa, ba] = toLab(cA), [Lb, ab, bb] = toLab(cB);
  const w = pctA / 100;
  const L = La * w + Lb * (1 - w), a = aa * w + ab * (1 - w), b = ba * w + bb * (1 - w);
  const C = Math.hypot(a, b), h = (Math.atan2(b, a) * 180) / Math.PI;
  return [L, C, (h + 360) % 360];
}

function verify() {
  let hardFails = 0;
  for (const th of THEMES) {
    console.log(`\n=== ${th.name}  (${th.mode}) [${th.id}] ===`);
    for (const [label, fg, bg, min] of PAIRS) {
      const r = contrast(th.t[fg], th.t[bg]);
      const ok = r >= min;
      const tag = ok ? 'PASS' : '**FAIL**';
      if (!ok) hardFails++;
      console.log(`  ${tag}  ${label.padEnd(20)} ${r.toFixed(2)}:1  (min ${min})  ${hex(...th.t[fg])} on ${hex(...th.t[bg])}`);
    }
    // pill text-on-tint: full-color text over a color-tint-of-surface background
    const tintPct = th.mode === 'light' ? 10 : 15;
    for (const k of ['ok', 'need', 'bad', 'info', 'accent']) {
      const tint = mixOklab(th.t[k], tintPct, th.t.surface);
      const r = contrast(th.t[k], tint);
      const ok = r >= 4.5;
      if (!ok) hardFails++;
      console.log(`  ${ok ? 'PASS' : '**FAIL**'}  ${(k + ' / ' + k + '-tint').padEnd(20)} ${r.toFixed(2)}:1  (min 4.5, tint ${tintPct}%)`);
    }
  }
  console.log(`\n${hardFails === 0 ? 'ALL THEMES PASS WCAG AA' : hardFails + ' PAIR(S) FAIL'}`);
  process.exit(hardFails === 0 ? 0 : 1);
}

function css() {
  const order = ['bg','bg2','surface','surface2','hover','line','lineSoft','ink','muted','faint',
    'accent','accent2','accentInk','ok','need','needInk','bad','info','termBg'];
  const varName = { bg:'--bg', bg2:'--bg-2', surface:'--surface', surface2:'--surface-2', hover:'--hover',
    line:'--line', lineSoft:'--line-soft', ink:'--ink', muted:'--muted', faint:'--faint',
    accent:'--accent', accent2:'--accent-2', accentInk:'--accent-ink', ok:'--ok', need:'--need',
    needInk:'--need-ink', bad:'--bad', info:'--info', termBg:'--term-bg' };
  const okl = ([L,C,h]) => `oklch(${L} ${C} ${h})`;
  let out = '';
  for (const th of THEMES) {
    out += `  :root[data-theme="${th.id}"]{\n    color-scheme:${th.mode};\n`;
    for (const k of order) out += `    ${varName[k]}: ${okl(th.t[k])};\n`;
    out += `  }\n`;
  }
  process.stdout.write(out);
}

const cmd = process.argv[2] || 'verify';
if (cmd === 'css') css(); else verify();
