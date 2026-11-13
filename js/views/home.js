// Início: apresentação + criação da unidade de demonstração, ou painel de atalhos.
import { supabase } from '../supabase.js';
import { state, loadUnit, route } from '../app.js';
import { appUrl, busy, h, mount, qrSvg, rpc, toast } from '../lib.js';

const FEATURES = [
    ['🎫', 'Totem de senhas', 'Escolha do serviço e do tipo de atendimento (normal, prioritário, 80+ ou doador), impressão em cupom e QR code.'],
    ['🖥️', 'Painel com voz', 'Senha e guichê em destaque, histórico de chamadas e anúncio falado.'],
    ['🧑‍💼', 'Guichê do atendente', 'Chamar próxima, rechamar, finalizar ou marcar ausência, com atalhos de teclado.'],
    ['📱', 'Acompanhe no celular', 'Pelo QR code: posição na fila, espera estimada e aviso quando for chamado.'],
    ['📊', 'Relatórios', 'Senhas por dia e por hora, espera média, percentis, meta e exportação.'],
    ['⚡', 'Tempo real', 'Todas as telas se atualizam na hora, em qualquer dispositivo.'],
];

export async function viewHome(app) {
    if (!state.unit) return landing(app);
    return dashboard(app);
}

function landing(app) {
    const start = h('button', { class: 'btn primary big', type: 'button' }, 'Criar minha unidade de demonstração');
    start.addEventListener('click', () => busy(start, async () => {
        if (!state.session) {
            const { data, error } = await supabase.auth.signInAnonymously();
            if (error) {
                if (/anonymous sign-ins are disabled/i.test(error.message)) {
                    throw new Error('A demonstração está temporariamente indisponível (login anônimo desativado no servidor).');
                }
                throw error;
            }
            state.session = data.session;
        }
        await rpc('create_demo_unit', { p_name: 'Unidade de demonstração' });
        await loadUnit();
        toast('Unidade criada!');
        route();
    }));

    mount(app,
        h('section', { class: 'hero' },
            h('div', { class: 'eyebrow' }, 'Demonstração'),
            h('h1', {}, 'Senhas de atendimento, do totem ao painel'),
            h('p', {}, 'Organize filas de atendimento com serviços, prioridades da lei (incluindo 80+ e doadores), painel com voz e relatórios. Experimente: você ganha uma unidade só sua, sem cadastro.'),
            h('div', { class: 'row' }, start, h('a', { class: 'btn ghost', href: 'https://wllynilson.com.br' }, 'Sobre o autor'))),
        h('section', { class: 'grid grid-3' },
            FEATURES.map(([icon, title, text]) => h('div', { class: 'card feature' },
                h('div', { class: 'icon', 'aria-hidden': 'true' }, icon), h('h3', {}, title), h('p', {}, text)))),
        h('p', { class: 'footer' },
            'Os dados de demonstração são fictícios e ficam vinculados a este navegador. Unidades sem uso por 30 dias são apagadas.'));
}

function dashboard(app) {
    const u = state.unit;
    // o painel fica exposto numa TV: usa o token que só lê
    const totemUrl = appUrl(`/totem/${u.kiosk_token}`);
    const panelUrl = appUrl(`/painel/${u.display_token}`);

    const device = (title, text, url, qrLabel) => h('div', { class: 'card device' },
        h('h3', {}, title),
        h('p', { class: 'muted small', style: 'margin:0' }, text),
        qrSvg(url, qrLabel),
        h('div', { class: 'row' },
            h('a', { class: 'btn primary', href: url, target: '_blank', rel: 'noopener' }, 'Abrir'),
            copyBtn(url)));

    mount(app,
        h('div', { class: 'row spread', style: 'margin-bottom:1rem' },
            h('div', {},
                h('div', { class: 'eyebrow' }, 'Sua unidade'),
                h('h1', { style: 'margin:0' }, u.name))),
        h('div', { class: 'card notice', style: 'margin-bottom:1rem' },
            h('h3', {}, 'Teste em 1 minuto'),
            h('ol', { class: 'steps' },
                h('li', {}, 'Abra o painel numa aba (ou numa TV) e toque em “Ativar som”.'),
                h('li', {}, 'Tire senhas no totem: aqui ou no celular, lendo o QR code.'),
                h('li', {}, 'No guichê, clique em “Chamar próxima” e ouça o painel anunciar.'))),
        h('div', { class: 'grid grid-3' },
            device('Totem', 'Para a recepção ou um tablet. Quem tem este link emite senhas.', totemUrl, 'QR code do totem'),
            device('Painel (TV)', 'Mostra as chamadas com som e voz. Este link só lê.', panelUrl, 'QR code do painel'),
            h('div', { class: 'card device' },
                h('h3', {}, 'Guichê e gestão'),
                h('p', { class: 'muted small', style: 'margin:0' }, 'Para o atendente, neste navegador. Abra várias abas para simular mais guichês.'),
                h('a', { class: 'btn primary', href: '#/guiche' }, 'Abrir guichê'),
                h('a', { class: 'btn', href: '#/relatorios' }, 'Ver relatórios'),
                h('a', { class: 'btn', href: '#/config' }, 'Configurar serviços'))),
        h('p', { class: 'footer' },
            'Quem tem o link do totem pode tirar senhas, como no balcão físico; o do painel só mostra as chamadas. ',
            'Dá para trocar os dois em Configurar. ',
            'Projeto de ', h('a', { href: 'https://wllynilson.com.br' }, 'Wllynilson Pereira'), '.'));
}

function copyBtn(text) {
    const b = h('button', { class: 'btn', type: 'button' }, 'Copiar link');
    b.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(text); toast('Link copiado'); } catch { toast(text); }
    });
    return b;
}
