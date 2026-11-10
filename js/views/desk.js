// Guichê do atendente: chamar próxima, rechamar, finalizar, ausente; fila ao vivo.
import { supabase } from '../supabase.js';
import { state } from '../app.js';
import { busy, fmtTime, h, live, minutesSince, mount, rpc, toast, todayIn } from '../lib.js';

const store = {
    get(k, d) { try { return sessionStorage.getItem(k) ?? localStorage.getItem(k) ?? d; } catch { return d; } },
    set(k, v) { try { sessionStorage.setItem(k, v); localStorage.setItem(k, v); } catch { /* sem storage */ } },
};

export async function viewDesk(app) {
    const unit = state.unit;
    let services = [];
    let tickets = [];
    let counter = store.get('desk.counter', 'Guichê 1');
    let picked = null; // ids dos serviços atendidos; null = todos
    try { picked = JSON.parse(store.get('desk.services', 'null')); } catch { picked = null; }

    const counterInput = h('input', { type: 'text', id: 'counter', value: counter, maxlength: '30', autocomplete: 'off' });
    counterInput.addEventListener('change', () => {
        counter = counterInput.value.trim() || 'Guichê 1';
        counterInput.value = counter;
        store.set('desk.counter', counter);
        render();
    });
    const picksEl = h('div', { class: 'service-picks' });
    const body = h('div');

    mount(app,
        h('div', { class: 'row spread', style: 'margin-bottom:1rem' },
            h('h1', { style: 'margin:0' }, 'Guichê'),
            h('span', { class: 'small muted' }, 'Atalhos: ', h('span', { class: 'kbd' }, 'N'), ' próxima · ',
                h('span', { class: 'kbd' }, 'R'), ' rechamar · ', h('span', { class: 'kbd' }, 'F'), ' finalizar')),
        h('div', { class: 'card row', style: 'margin-bottom:1rem;align-items:flex-end' },
            h('div', { style: 'flex:0 1 220px' }, h('label', { for: 'counter' }, 'Nome do guichê'), counterInput),
            h('div', { style: 'flex:1 1 300px' }, h('label', {}, 'Serviços que este guichê atende'), picksEl)),
        body);

    const isPicked = (id) => !picked || picked.includes(id);
    const svcName = (id) => services.find((s) => s.id === id)?.name ?? '';

    function renderPicks() {
        mount(picksEl, services.filter((s) => s.active).map((s) => {
            const cb = h('input', { type: 'checkbox', checked: isPicked(s.id) });
            cb.addEventListener('change', () => {
                const ids = services.filter((x) => x.active && (x.id === s.id ? cb.checked : isPicked(x.id))).map((x) => x.id);
                picked = ids.length === services.filter((x) => x.active).length ? null : ids;
                store.set('desk.services', JSON.stringify(picked));
                render();
            });
            return h('label', { class: 'check' }, cb, `${s.prefix} · ${s.name}`);
        }));
    }

    const current = () => tickets.find((t) => t.status === 'called' && t.counter === counter);

    async function callNext(btn) {
        await busy(btn, async () => {
            const t = await rpc('call_next', { p_counter: counter, p_services: picked });
            if (!t) toast('Não há senhas aguardando nos serviços deste guichê.');
            await refresh();
        });
    }
    async function act(btn, fn, msg) {
        await busy(btn, async () => { await fn(); if (msg) toast(msg); await refresh(); });
    }
    const recall = (btn, t) => act(btn, () => rpc('recall_ticket', { p_ticket: t.id }), `Senha ${t.code} chamada novamente`);
    const finish = (btn, t, status) => act(btn, () => rpc('finish_ticket', { p_ticket: t.id, p_status: status }),
        status === 'done' ? `Atendimento ${t.code} finalizado` : status === 'no_show' ? `${t.code} marcada como ausente` : `${t.code} cancelada`);

    function render() {
        const cur = current();
        const waiting = tickets.filter((t) => t.status === 'waiting' && isPicked(t.service_id));
        const others = tickets.filter((t) => t.status === 'called' && t.counter !== counter);

        const nextBtn = h('button', { class: 'btn primary big', type: 'button', id: 'next' },
            cur ? 'Finalizar e chamar próxima' : 'Chamar próxima', ` (${waiting.length})`);
        nextBtn.addEventListener('click', () => callNext(nextBtn));

        const curCard = h('section', { class: 'card desk-current', 'aria-live': 'polite' },
            cur
                ? [h('div', { class: 'muted' }, 'Em atendimento · ', svcName(cur.service_id)),
                    h('div', { class: 'code' }, cur.code),
                    h('div', { class: 'row', style: 'justify-content:center;margin-top:.5rem' },
                        cur.preferential ? h('span', { class: 'badge pref' }, 'Preferencial') : null,
                        h('span', { class: 'badge' }, `chamada há ${minutesSince(cur.called_at)} min`),
                        cur.call_count > 1 ? h('span', { class: 'badge' }, `${cur.call_count}ª chamada`) : null),
                    h('div', { class: 'desk-actions' },
                        btn('🔁 Rechamar', (b) => recall(b, cur), { id: 'recall' }),
                        btn('✅ Finalizar', (b) => finish(b, cur, 'done'), { id: 'finish' }),
                        btn('🚫 Ausente', (b) => finish(b, cur, 'no_show'), { class: 'btn danger' }))]
                : [h('div', { class: 'muted' }, counter), h('p', { style: 'font-size:1.2rem;margin:.75rem 0 0' }, 'Nenhuma senha em atendimento')],
            h('div', { style: 'margin-top:1.25rem' }, nextBtn));

        const queueCard = h('section', { class: 'card' },
            h('div', { class: 'row spread' }, h('h2', { style: 'margin:0' }, 'Fila'), h('span', { class: 'muted small' }, `${waiting.length} aguardando`)),
            waiting.length
                ? h('ol', { class: 'queue-list' }, waiting.map((t) => h('li', {},
                    h('span', { class: 'code' }, t.code),
                    h('span', { class: 'grow' }, svcName(t.service_id), ' · ', fmtTime(t.issued_at, unit.timezone), ` · ${minutesSince(t.issued_at)} min`),
                    t.preferential ? h('span', { class: 'badge pref' }, 'Pref.') : null,
                    btn('Cancelar', (b) => { if (confirm(`Cancelar a senha ${t.code}?`)) finish(b, t, 'cancelled'); }, { class: 'btn ghost small', 'aria-label': `Cancelar senha ${t.code}` }))))
                : h('p', { class: 'empty' }, 'Ninguém aguardando.'),
            others.length
                ? h('div', { style: 'margin-top:1rem' },
                    h('h3', { class: 'muted' }, 'Em outros guichês'),
                    h('ul', { class: 'queue-list' }, others.map((t) => h('li', {},
                        h('span', { class: 'code' }, t.code), h('span', { class: 'grow' }, t.counter),
                        btn('Finalizar', (b) => finish(b, t, 'done'), { class: 'btn ghost small' })))))
                : null);

        mount(body, h('div', { class: 'desk' }, curCard, queueCard));
    }

    function btn(label, onClick, attrs = {}) {
        const b = h('button', { class: 'btn', type: 'button', ...attrs }, label);
        b.addEventListener('click', () => onClick(b));
        return b;
    }

    const refresh = async () => {
        const [s, t] = await Promise.all([
            supabase.from('services').select('*').order('sort_order').order('prefix'),
            supabase.from('tickets')
                .select('id,code,status,preferential,counter,issued_at,called_at,last_call_at,call_count,service_id')
                .eq('service_day', todayIn(unit.timezone))
                .in('status', ['waiting', 'called'])
                .order('preferential', { ascending: false })
                .order('issued_at'),
        ]);
        if (s.error) throw s.error;
        if (t.error) throw t.error;
        const servicesChanged = JSON.stringify(s.data) !== JSON.stringify(services);
        services = s.data;
        tickets = t.data;
        if (servicesChanged) renderPicks();
        render();
    };

    const onKey = (e) => {
        if (e.target.closest('input, textarea, select') || e.metaKey || e.ctrlKey || e.altKey) return;
        const k = e.key.toLowerCase();
        const id = k === 'n' ? 'next' : k === 'r' ? 'recall' : k === 'f' ? 'finish' : null;
        const el = id && document.getElementById(id);
        if (el && !el.disabled) { e.preventDefault(); el.click(); }
    };
    document.addEventListener('keydown', onKey);

    await refresh();
    const stop = live(unit.kiosk_token, refresh);
    const ageTimer = setInterval(render, 30000);
    return () => { stop(); clearInterval(ageTimer); document.removeEventListener('keydown', onKey); };
}
