// Utilitários compartilhados: DOM seguro, avisos, formatação, QR code, som e tempo real.
import { supabase } from './supabase.js';

// ---------- DOM (sempre textContent; nunca innerHTML com dados) ----------
export function h(tag, attrs = {}, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
        if (v == null || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'dataset') Object.assign(el.dataset, v);
        else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
        else if (v === true) el.setAttribute(k, '');
        else el.setAttribute(k, v);
    }
    append(el, children);
    return el;
}
function append(el, children) {
    for (const c of children.flat(Infinity)) {
        if (c == null || c === false) continue;
        el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
}
export function mount(el, ...children) {
    el.replaceChildren();
    append(el, children);
}

let toastTimer;
export function toast(msg, isError = false) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.className = isError ? 'error' : '';
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 3000);
}
export function fail(err) {
    console.error(err);
    toast(err?.message || 'Algo deu errado. Tente novamente.', true);
}
export async function busy(btn, fn) {
    if (btn) btn.disabled = true;
    try { return await fn(); } catch (e) { fail(e); } finally { if (btn) btn.disabled = false; }
}
// Chamada de função no banco: devolve os dados ou lança o erro
export async function rpc(name, args) {
    const { data, error } = await supabase.rpc(name, args);
    if (error) throw error;
    return data;
}

// ---------- Datas e números ----------
export function todayIn(tz) {
    // yyyy-mm-dd no fuso da unidade
    return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}
export function addDays(iso, n) {
    const d = new Date(iso + 'T12:00:00Z');
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
}
export const fmtTime = (iso, tz) => new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: tz });
export const fmtDayShort = (isoDate) => new Date(isoDate + 'T12:00:00Z').toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', timeZone: 'UTC' });
export const fmtWeekday = (isoDate) => new Date(isoDate + 'T12:00:00Z').toLocaleDateString('pt-BR', { weekday: 'short', timeZone: 'UTC' }).replace('.', '');
export const fmtInt = (n) => Number(n || 0).toLocaleString('pt-BR');
export function fmtDuration(sec) {
    if (sec == null) return '—';
    const s = Math.max(0, Math.round(sec));
    if (s < 60) return `${s} s`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m} min`;
    return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')}`;
}
export function minutesSince(iso, now = Date.now()) {
    return Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60000));
}

// ---------- Links ----------
export function appUrl(route) {
    return `${location.origin}${location.pathname}#${route}`;
}

// ---------- QR code (biblioteca qrcode-generator, desenhado em SVG via DOM) ----------
const SVG = 'http://www.w3.org/2000/svg';
export function qrSvg(text, label = 'QR code') {
    const wrap = h('div', { class: 'qr', role: 'img', 'aria-label': label });
    if (!window.qrcode) {
        wrap.append(h('span', { class: 'small muted' }, 'QR indisponível'));
        return wrap;
    }
    const qr = window.qrcode(0, 'M');
    qr.addData(text);
    qr.make();
    const n = qr.getModuleCount();
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', `0 0 ${n} ${n}`);
    svg.setAttribute('shape-rendering', 'crispEdges');
    svg.style.width = '100%';
    svg.style.display = 'block';
    let d = '';
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (qr.isDark(y, x)) d += `M${x} ${y}h1v1h-1z`;
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', d);
    path.setAttribute('fill', '#000');
    svg.append(path);
    wrap.append(svg);
    return wrap;
}

// ---------- Som e voz ----------
let audioCtx;
export function unlockAudio() {
    try {
        audioCtx ??= new (window.AudioContext || window.webkitAudioContext)();
        audioCtx.resume();
        if ('speechSynthesis' in window) speechSynthesis.speak(new SpeechSynthesisUtterance(''));
    } catch { /* sem áudio */ }
}
export function chime() {
    if (!audioCtx) return Promise.resolve();
    const t0 = audioCtx.currentTime;
    [[784, 0], [1047, 0.28]].forEach(([freq, at]) => {
        const o = audioCtx.createOscillator();
        const g = audioCtx.createGain();
        o.type = 'sine';
        o.frequency.value = freq;
        g.gain.setValueAtTime(0.0001, t0 + at);
        g.gain.exponentialRampToValueAtTime(0.35, t0 + at + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + at + 0.9);
        o.connect(g).connect(audioCtx.destination);
        o.start(t0 + at);
        o.stop(t0 + at + 1);
    });
    return new Promise((r) => setTimeout(r, 1100));
}
let voice;
function ptVoice() {
    if (voice !== undefined) return voice;
    const voices = speechSynthesis.getVoices();
    voice = voices.find((v) => v.lang === 'pt-BR') || voices.find((v) => v.lang?.startsWith('pt')) || null;
    if (!voices.length) voice = undefined; // ainda carregando
    return voice;
}
// "AP012" → "Senha A P, 12. Guichê 2."
export function spokenCall(code, counter) {
    const m = /^([A-Z]+)(\d+)$/.exec(code) || [];
    const letters = (m[1] || code).split('').join(' ');
    const num = m[2] ? String(Number(m[2])) : '';
    return `Senha ${letters}, ${num}. ${counter || ''}.`;
}
export function speak(text) {
    return new Promise((resolve) => {
        if (!('speechSynthesis' in window)) return resolve();
        const u = new SpeechSynthesisUtterance(text);
        u.lang = 'pt-BR';
        const v = ptVoice();
        if (v) u.voice = v;
        u.rate = 0.9;
        u.onend = u.onerror = () => resolve();
        speechSynthesis.speak(u);
        setTimeout(resolve, 8000); // garante que a fila não trava
    });
}

// ---------- Tempo real ----------
// Escuta o canal da unidade (aviso "changed" disparado pelo banco) e também
// consulta periodicamente, caso o tempo real caia. Devolve a função que para tudo.
export function live(token, refresh, { pollMs = 15000, immediate = false } = {}) {
    let timer;
    let pending = false;
    let again = false;
    let stopped = false;
    const run = async () => {
        if (stopped) return;
        if (pending) { again = true; return; } // aviso chegou durante a busca: busca de novo depois
        pending = true;
        try { await refresh(); } catch (e) { console.warn(e); } finally { pending = false; }
        if (again) { again = false; run(); }
    };
    const schedule = () => { clearTimeout(timer); timer = setTimeout(async () => { await run(); schedule(); }, pollMs); };
    const channel = token
        ? supabase.channel(`unit:${token}`).on('broadcast', { event: 'changed' }, () => { run(); schedule(); }).subscribe()
        : null;
    const onVisible = () => { if (document.visibilityState === 'visible') run(); };
    document.addEventListener('visibilitychange', onVisible);
    if (immediate) run();
    schedule();
    return () => {
        stopped = true;
        clearTimeout(timer);
        document.removeEventListener('visibilitychange', onVisible);
        if (channel) supabase.removeChannel(channel);
    };
}
