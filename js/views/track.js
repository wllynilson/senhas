// Acompanhamento pelo QR code: posição na fila e aviso quando a senha é chamada.
import { chime, h, live, mount, rpc, unlockAudio } from '../lib.js';

const STATUS = {
    waiting: 'Aguardando',
    called: 'É a sua vez!',
    done: 'Atendimento concluído',
    no_show: 'Senha encerrada (ausente)',
    cancelled: 'Senha cancelada',
};

export async function viewTrack(app, code) {
    let t = null;
    let lastCalls = null;
    let soundOn = false;
    const baseTitle = document.title;

    const soundBtn = h('button', { class: 'btn', type: 'button' }, '🔔 Ativar alerta sonoro');
    soundBtn.addEventListener('click', () => {
        unlockAudio();
        soundOn = true;
        chime();
        soundBtn.textContent = '🔔 Alerta sonoro ativado';
        soundBtn.disabled = true;
    });

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
        mount(app, h('div', { class: 'track stack' },
            h('div', { class: 'muted' }, t.unit),
            h('div', { class: `card${called ? ' called' : ''}` },
                h('div', {}, t.service, t.preferential ? ' · Preferencial' : ''),
                h('div', { class: 'code' }, t.code),
                h('div', { class: 'status', role: 'status' }, STATUS[t.status] || t.status),
                called ? h('p', { style: 'font-size:1.6rem;font-weight:800;margin:.5rem 0 0' }, `Dirija-se ao ${t.counter}`) : null),
            t.status === 'waiting'
                ? h('div', { class: 'card' },
                    h('div', { class: 'ahead' }, t.ahead),
                    h('div', { class: 'muted' }, t.ahead === 1 ? 'pessoa na sua frente' : 'pessoas na sua frente'),
                    h('p', { class: 'small muted', style: 'margin:.75rem 0 0' }, 'Esta página se atualiza sozinha. Deixe-a aberta para ser avisado.'))
                : null,
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
    const stop = live(null, refresh, { pollMs: 5000 });
    return () => { stop(); document.title = baseTitle; };
}
