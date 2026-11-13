// Acompanhamento pelo QR code: posição na fila, espera estimada e aviso
// quando a senha é chamada — na tela, por vibração, som e Web Push.
import { busy, chime, fmtEta, h, live, mount, priorityShort, pushAvailable, rpc, subscribePush, toast, unlockAudio } from '../lib.js';

const STATUS = {
    waiting: 'Aguardando',
    called: 'É a sua vez!',
    done: 'Atendimento concluído',
    no_show: 'Senha encerrada (ausente)',
    cancelled: 'Senha cancelada',
    expired: 'Senha encerrada (dia anterior)',
};

export async function viewTrack(app, code) {
    let t = null;
    let lastCalls = null;
    let soundOn = false;
    let pushOn = false;
    const baseTitle = document.title;

    const soundBtn = h('button', { class: 'btn', type: 'button' }, '🔔 Ativar alerta sonoro');
    soundBtn.addEventListener('click', () => {
        unlockAudio();
        soundOn = true;
        chime();
        soundBtn.textContent = '🔔 Alerta sonoro ativado';
        soundBtn.disabled = true;
    });

    // Com a aba em segundo plano o celular congela a página: só o Web Push
    // garante o aviso de quem guardou o telefone no bolso.
    const pushBtn = h('button', { class: 'btn primary', type: 'button' }, '📲 Avisar quando chegar minha vez');
    pushBtn.addEventListener('click', () => busy(pushBtn, async () => {
        await subscribePush(code);
        pushOn = true;
        pushBtn.textContent = '📲 Você será avisado';
        pushBtn.disabled = true;
        toast('Pronto: avisamos mesmo com a tela desligada.');
    }));

    function alertCalled() {
        navigator.vibrate?.([300, 150, 300, 150, 600]);
        if (soundOn) chime();
        document.title = `🔔 ${t.code}: ${t.counter}`;
    }

    function render() {
        if (!t) {
            mount(app, h('div', { class: 'track card empty' },
                h('h1', {}, 'Senha não encontrada'),
                h('p', {}, 'Confira o QR code ou peça uma nova senha no totem.')));
            return;
        }
        const called = t.status === 'called';
        const open = t.status === 'waiting' || called;
        const pref = priorityShort(t.priority);
        mount(app, h('div', { class: 'track stack' },
            h('div', { class: 'muted' }, t.unit),
            h('div', { class: `card${called ? ' called' : ''}` },
                h('div', {}, t.service, pref ? ` · ${pref}` : ''),
                h('div', { class: 'code' }, t.code),
                h('div', { class: 'status', role: 'status' }, STATUS[t.status] || t.status),
                called ? h('p', { style: 'font-size:1.6rem;font-weight:800;margin:.5rem 0 0' }, `Dirija-se ao ${t.counter}`) : null),
            t.status === 'waiting'
                ? h('div', { class: 'card' },
                    t.ahead === 0
                        ? h('div', { class: 'status' }, 'Você é o próximo!')
                        : [h('div', { class: 'ahead' }, t.ahead),
                            h('div', { class: 'muted' }, t.ahead === 1 ? 'pessoa na sua frente' : 'pessoas na sua frente')],
                    h('div', { class: 'muted', style: 'margin-top:.5rem' }, 'Espera estimada: ', h('b', {}, fmtEta(t.eta))),
                    h('p', { class: 'small muted', style: 'margin:.75rem 0 0' }, 'Esta página se atualiza sozinha. Deixe-a aberta para ser avisado.'))
                : null,
            open && pushAvailable && !pushOn ? pushBtn : null,
            open ? soundBtn : null,
            h('p', { class: 'small muted' }, 'Senhas de Atendimento · demonstração')));
    }

    const refresh = async () => {
        t = await rpc('ticket_status', { p_code: code });
        if (t && t.status === 'called' && lastCalls !== null && t.call_count !== lastCalls) alertCalled();
        if (t && t.status !== 'called') document.title = baseTitle;
        if (t) lastCalls = t.status === 'called' ? t.call_count : 0;
        render();
    };

    await refresh();
    // o banco avisa no canal desta senha; a consulta periódica é a reserva
    const stop = live(`ticket:${code}`, refresh, { pollMs: 30000 });
    return () => { stop(); document.title = baseTitle; };
}
