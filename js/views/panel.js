// Painel (TV): senha atual em destaque, últimas chamadas e anúncio com som e voz.
import { chime, h, live, mount, priorityShort, rpc, speak, spokenCall, unlockAudio } from '../lib.js';

export async function viewPanel(app, token) {
    let st = null;
    let soundOn = false;
    let overlayOpen = true;
    let first = true;
    let flashId = null;
    const seen = new Set();
    const queue = [];
    let speaking = false;
    let alive = true;

    const clock = h('div', { class: 'clock', 'aria-label': 'Hora atual' });
    const tick = () => { clock.textContent = new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }); };
    tick();
    const clockTimer = setInterval(tick, 1000);

    const overlay = h('div', { class: 'overlay' },
        h('div', { class: 'card stack' },
            h('h2', {}, 'Painel de chamadas'),
            h('p', { class: 'muted' }, 'O navegador só toca som depois de um toque na tela.'),
            h('button', { class: 'btn primary big', type: 'button', onclick: () => enable(true) }, '🔊 Ativar som e tela cheia'),
            h('button', { class: 'btn', type: 'button', onclick: () => enable(false) }, 'Continuar sem som')));

    function enable(withSound) {
        soundOn = withSound;
        if (withSound) {
            unlockAudio();
            document.documentElement.requestFullscreen?.().catch(() => {});
        }
        overlayOpen = false;
        overlay.remove();
    }

    async function processQueue() {
        if (speaking) return;
        speaking = true;
        while (alive && queue.length) {
            const c = queue.shift();
            flashId = c.id;
            render();
            if (soundOn) {
                await chime();
                await speak(spokenCall(c.code, c.counter));
            } else {
                await new Promise((r) => setTimeout(r, 2500));
            }
        }
        speaking = false;
    }

    function render() {
        if (!st) return;
        const [current, ...history] = st.calls;
        const currentEl = h('section', { class: 'panel-current', 'aria-live': 'assertive' },
            current
                ? [h('div', { class: 'label' }, 'Senha'),
                    h('div', { class: 'code' }, current.code),
                    h('div', { class: 'counter' }, current.counter),
                    h('div', { class: 'service' }, current.service,
                        priorityShort(current.priority) ? ` · ${priorityShort(current.priority)}` : '')]
                : [h('div', { class: 'label' }, 'Aguardando'), h('div', { class: 'service' }, 'Nenhuma senha chamada hoje')]);
        if (current && flashId === current.id) {
            currentEl.classList.add('flash');
            flashId = null;
        }
        mount(app,
            h('div', { class: 'panel' },
                h('header', { class: 'panel-head' }, h('div', { class: 'unit' }, st.unit), clock),
                currentEl,
                h('section', { class: 'panel-history' },
                    h('h2', {}, 'Últimas chamadas'),
                    history.length
                        ? h('ol', {}, history.slice(0, 5).map((c) => h('li', {},
                            h('span', { class: 'code' }, c.code), h('span', { class: 'counter' }, c.counter))))
                        : h('p', { class: 'muted' }, '—')),
                h('footer', { class: 'panel-foot' },
                    st.services.map((s) => h('div', { class: 'wait' }, `${s.name}: `, h('b', {}, s.waiting), ' aguardando')))),
            overlayOpen ? overlay : null);
    }

    const refresh = async () => {
        st = await rpc('panel_state', { p_token: token });
        const now = new Date(st.server_time).getTime();
        // anuncia chamadas e rechamadas novas (as antigas só entram no histórico)
        for (const c of [...st.calls].reverse()) {
            const key = `${c.id}:${c.call_count}`;
            if (seen.has(key)) continue;
            seen.add(key);
            if (!first && now - new Date(c.last_call_at).getTime() < 120000) queue.push(c);
        }
        render();
        first = false;
        processQueue();
    };

    await refresh();
    const stop = live(`unit:${token}`, refresh, { pollMs: 10000 });
    return () => {
        alive = false;
        stop();
        clearInterval(clockTimer);
        if ('speechSynthesis' in window) speechSynthesis.cancel();
        if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    };
}
