// Roteamento e sessão. Telas em js/views/.
import { isConfigured, supabase } from './supabase.js';
import { fail, h, mount } from './lib.js';
import { viewHome } from './views/home.js';
import { viewTotem } from './views/totem.js';
import { viewPanel } from './views/panel.js';
import { viewTrack } from './views/track.js';
import { viewDesk } from './views/desk.js';
import { viewReports } from './views/reports.js';
import { viewConfig } from './views/config.js';

const app = document.getElementById('app');
const topbar = document.getElementById('topbar');

// Sessão (login anônimo de demonstração) e unidade do visitante
export const state = { session: null, unit: null };

export async function loadUnit() {
    if (!state.session) { state.unit = null; return null; }
    const { data, error } = await supabase.from('units').select('*').maybeSingle();
    if (error) throw error;
    state.unit = data;
    return data;
}

const TOKEN = '([a-f0-9]{32})';
const routes = [
    { re: /^\/?$/, view: viewHome, nav: 'home' },
    { re: new RegExp(`^/totem/${TOKEN}$`), view: viewTotem, kiosk: true, title: 'Totem' },
    { re: new RegExp(`^/painel/${TOKEN}$`), view: viewPanel, kiosk: true, title: 'Painel' },
    { re: new RegExp(`^/senha/${TOKEN}$`), view: viewTrack, bare: true, title: 'Minha senha' },
    { re: /^\/guiche$/, view: viewDesk, owner: true, nav: 'guiche', title: 'Guichê' },
    { re: /^\/relatorios$/, view: viewReports, owner: true, nav: 'relatorios', title: 'Relatórios' },
    { re: /^\/config$/, view: viewConfig, owner: true, nav: 'config', title: 'Configurar' },
];

let cleanup = null;
let routeSeq = 0;

export async function route() {
    const seq = ++routeSeq;
    if (cleanup) { try { cleanup(); } catch { /* ignora */ } cleanup = null; }

    const path = decodeURIComponent(location.hash.replace(/^#/, '')) || '/';
    const match = routes.map((r) => ({ r, m: r.re.exec(path) })).find((x) => x.m);
    if (!match) { location.replace('#/'); return; }
    const { r, m } = match;

    if (r.owner && !state.unit) { location.replace('#/'); return; }

    document.body.classList.toggle('kiosk', Boolean(r.kiosk));
    topbar.hidden = Boolean(r.kiosk || r.bare || !state.unit);
    for (const a of topbar.querySelectorAll('[data-nav]')) a.classList.toggle('active', a.dataset.nav === r.nav);
    document.title = r.title ? `${r.title} · Senhas de Atendimento` : 'Senhas de Atendimento';

    // Cada tela desenha no próprio contêiner: atualizações atrasadas de uma
    // tela que já saiu caem num elemento fora da página.
    const root = h('div', { class: 'view' }, h('p', { class: 'muted' }, 'Carregando…'));
    mount(app, root);
    try {
        const c = await r.view(root, ...m.slice(1));
        if (seq !== routeSeq) { if (typeof c === 'function') c(); return; }
        cleanup = typeof c === 'function' ? c : null;
    } catch (e) {
        if (seq !== routeSeq) return;
        fail(e);
        mount(app, h('div', { class: 'card empty' },
            h('p', {}, e?.message || 'Não foi possível carregar esta tela.'),
            h('a', { class: 'btn', href: '#/' }, 'Voltar ao início')));
    }
}

async function start() {
    if (!isConfigured) {
        mount(app, h('div', { class: 'card' },
            h('h1', {}, 'Configuração pendente'),
            h('p', {}, 'Preencha a URL e a chave pública do Supabase em js/config.js (veja o README).')));
        return;
    }
    const { data } = await supabase.auth.getSession();
    state.session = data.session;
    try { await loadUnit(); } catch (e) { fail(e); }

    supabase.auth.onAuthStateChange((event, session) => {
        state.session = session;
        if (event === 'SIGNED_OUT') {
            state.unit = null;
            // fora do callback, para não travar o lock de autenticação
            setTimeout(() => { location.hash = '#/'; route(); }, 0);
        }
    });

    window.addEventListener('hashchange', route);
    route();
}

start();
