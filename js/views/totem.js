// Totem: escolhe serviço → normal/preferencial → mostra, imprime e gera QR da senha.
import { appUrl, fail, fmtTime, h, live, mount, qrSvg, rpc } from '../lib.js';

const BACK_AFTER_MS = 25000;

export async function viewTotem(app, token) {
    let services = [];
    let unitName = '';
    let screen = 'services'; // services | kind | ticket
    let chosen = null;
    let backTimer;

    const render = () => {
        clearTimeout(backTimer);
        if (screen === 'services') return renderServices();
        if (screen === 'kind') return renderKind();
    };

    const head = (subtitle) => h('div', { class: 'totem-head' },
        h('div', { class: 'eyebrow' }, unitName),
        h('h1', {}, subtitle));

    function renderServices() {
        mount(app, h('div', { class: 'totem' },
            head('Toque no serviço desejado'),
            services.length
                ? h('div', { class: 'totem-services' }, services.map((s) => {
                    const b = h('button', { class: 'totem-btn', type: 'button' },
                        h('span', { class: 'letter', 'aria-hidden': 'true' }, s.prefix),
                        h('span', { class: 'name' }, s.name),
                        h('span', { class: 'meta' }, s.waiting === 1 ? '1 pessoa aguardando' : `${s.waiting} pessoas aguardando`));
                    b.addEventListener('click', () => { chosen = s; screen = 'kind'; render(); });
                    return b;
                }))
                : h('div', { class: 'card empty' }, 'Nenhum serviço disponível no momento.'),
            h('p', { class: 'totem-foot' }, 'Senhas de Atendimento')));
    }

    function renderKind() {
        const pick = (pref) => {
            const b = h('button', { class: `totem-btn${pref ? ' pref' : ''}`, type: 'button' },
                h('span', { class: 'letter', 'aria-hidden': 'true' }, pref ? `${chosen.prefix}P` : chosen.prefix),
                h('span', { class: 'name' }, pref ? 'Preferencial' : 'Normal'),
                h('span', { class: 'meta' }, pref
                    ? 'Idosos (60+), gestantes, lactantes, pessoas com deficiência, com criança de colo ou com obesidade (Lei 10.048/2000).'
                    : 'Atendimento por ordem de chegada.'));
            b.addEventListener('click', () => issue(b, pref));
            return b;
        };
        const back = h('button', { class: 'btn big', type: 'button' }, '← Voltar');
        back.addEventListener('click', () => { screen = 'services'; render(); });
        mount(app, h('div', { class: 'totem' },
            head(chosen.name),
            h('div', { class: 'totem-services' }, pick(false), pick(true)),
            h('div', { class: 'totem-foot' }, back)));
        backTimer = setTimeout(() => { screen = 'services'; render(); }, BACK_AFTER_MS);
    }

    async function issue(btn, pref) {
        btn.disabled = true;
        try {
            const t = await rpc('issue_ticket', { p_token: token, p_service: chosen.id, p_preferential: pref });
            screen = 'ticket';
            renderTicket(t);
        } catch (e) {
            fail(e);
            btn.disabled = false;
        }
    }

    function renderTicket(t) {
        const url = appUrl(`/senha/${t.public_code}`);
        const print = h('button', { class: 'btn big', type: 'button' }, '🖨️ Imprimir');
        print.addEventListener('click', () => window.print());
        const done = h('button', { class: 'btn primary big', type: 'button' }, 'Concluir');
        done.addEventListener('click', () => { screen = 'services'; render(); });
        const ahead = t.ahead === 0 ? 'Você é o próximo da fila' : t.ahead === 1 ? '1 pessoa na sua frente' : `${t.ahead} pessoas na sua frente`;

        mount(app,
            h('div', { class: 'totem' },
                h('div', { class: 'totem-ticket card' },
                    h('div', { class: 'muted' }, t.service),
                    h('div', { class: 'code', 'aria-label': `Sua senha: ${t.code}` }, t.code),
                    t.preferential ? h('span', { class: 'badge pref' }, 'Preferencial') : null,
                    h('p', { style: 'margin-top:.75rem;font-weight:600' }, ahead),
                    h('a', { href: url, target: '_blank', rel: 'noopener', title: 'Abrir o acompanhamento', class: 'qr-link' },
                        qrSvg(url, 'QR code para acompanhar a senha no celular')),
                    h('p', { class: 'small muted' }, 'Aponte a câmera do celular para acompanhar sua senha e ser avisado quando for chamado.'),
                    h('div', { class: 'row', style: 'justify-content:center' }, print, done))),
            // Cupom para impressora térmica (só aparece ao imprimir)
            h('div', { class: 'print-ticket', 'aria-hidden': 'true' },
                h('div', { class: 'p-unit' }, t.unit),
                h('div', { class: 'p-service' }, t.service),
                h('div', { class: 'p-code' }, t.code),
                t.preferential ? h('div', { class: 'p-pref' }, 'PREFERENCIAL') : null,
                h('div', { class: 'p-qr' }, qrSvg(url)),
                h('div', { class: 'p-small' }, 'Acompanhe pelo QR code'),
                h('div', { class: 'p-small' }, `Emitida às ${fmtTime(t.issued_at)} · ${ahead}`)));
        backTimer = setTimeout(() => { screen = 'services'; render(); }, BACK_AFTER_MS);
    }

    const refresh = async () => {
        const st = await rpc('panel_state', { p_token: token });
        unitName = st.unit;
        services = st.services;
        if (screen === 'services') render();
        else if (screen === 'kind' && !services.some((s) => s.id === chosen.id)) { screen = 'services'; render(); }
    };
    await refresh();
    const stop = live(token, refresh);
    return () => { stop(); clearTimeout(backTimer); };
}
