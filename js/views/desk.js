// Guichê do atendente: chamar próxima, rechamar, finalizar, ausente,
// transferir e emitir senha no balcão; fila ao vivo.
import { supabase } from '../supabase.js';
import { state } from '../app.js';
import { busy, fmtTime, h, live, minutesSince, mount, PRIORITIES, priorityShort, rpc, toast, todayIn } from '../lib.js';

const store = {
    get(k, d) { try { return sessionStorage.getItem(k) ?? localStorage.getItem(k) ?? d; } catch { return d; } },
    set(k, v) { try { sessionStorage.setItem(k, v); localStorage.setItem(k, v); } catch { /* sem storage */ } },
};

// Duas abas no mesmo guichê se atrapalham: uma finaliza a senha da outra ao
// chamar a próxima. As abas se cumprimentam para que o atendente perceba.
const TAB_ID = Math.random().toString(36).slice(2);
const HELLO_MS = 20000;

export async function viewDesk(app) {
    const unit = state.unit;
    let counters = [];
    let services = [];
    let tickets = [];
    let counterId = store.get('desk.counter_id', '');
    let duplicate = false;

    const counterSelect = h('select', { id: 'counter' });
    counterSelect.addEventListener('change', () => {
        counterId = counterSelect.value;
        store.set('desk.counter_id', counterId);
        duplicate = false;
        hello();
        render();
    });
    const scope = h('div', { class: 'small muted' });
    const warn = h('div', { class: 'notice warn', hidden: true },
        'Outra aba parece estar usando este guichê. Escolha outro para as chamadas não se misturarem.');
    const body = h('div');

    mount(app,
        h('div', { class: 'row spread', style: 'margin-bottom:1rem' },
            h('h1', { style: 'margin:0' }, 'Guichê'),
            h('span', { class: 'small muted' }, 'Atalhos: ', h('span', { class: 'kbd' }, 'N'), ' próxima · ',
                h('span', { class: 'kbd' }, 'R'), ' rechamar · ', h('span', { class: 'kbd' }, 'F'), ' finalizar')),
        h('div', { class: 'card', style: 'margin-bottom:1rem' },
            h('div', { class: 'row', style: 'align-items:flex-end' },
                h('div', { style: 'flex:0 1 240px' }, h('label', { for: 'counter' }, 'Guichê'), counterSelect),
                h('div', { style: 'flex:1 1 300px' }, scope)),
            warn),
        body);

    const counter = () => counters.find((c) => c.id === counterId) ?? null;
    const svcName = (id) => services.find((s) => s.id === id)?.name ?? '';
    const serves = (t) => {
        const c = counter();
        if (!c) return false;
        if (c.priority_only && !t.priority) return false;
        return !c.service_ids?.length || c.service_ids.includes(t.service_id);
    };

    // ---------- avisos entre abas ----------
    const bc = 'BroadcastChannel' in window ? new BroadcastChannel('senhas-desk') : null;
    const hello = () => bc?.postMessage({ type: 'hello', from: TAB_ID, counter: counterId });
    bc?.addEventListener('message', (e) => {
        const m = e.data;
        if (!m || m.from === TAB_ID || !counterId || m.counter !== counterId) return;
        if (m.type === 'hello') bc.postMessage({ type: 'here', from: TAB_ID, counter: counterId });
        if (!duplicate) { duplicate = true; warn.hidden = false; }
    });
    const helloTimer = setInterval(() => { duplicate = false; warn.hidden = true; hello(); }, HELLO_MS);

    // ---------- ações ----------
    async function callNext(btn) {
        await busy(btn, async () => {
            const t = await rpc('call_next', { p_counter: counterId });
            if (!t) toast('Não há senhas aguardando nos serviços deste guichê.');
            await refresh();
        });
    }
    async function act(btn, fn, msg) {
        await busy(btn, async () => { await fn(); if (msg) toast(msg); await refresh(); });
    }
    const recall = (btn, t) => act(btn, async () => {
        const r = await rpc('recall_ticket', { p_ticket: t.id });
        toast(r.status === 'no_show'
            ? `${t.code} chamada ${r.call_count}× sem resposta: marcada como ausente`
            : `Senha ${t.code} chamada novamente (${r.call_count}ª)`);
    });
    const finish = (btn, t, status) => act(btn, () => rpc('finish_ticket', { p_ticket: t.id, p_status: status }),
        status === 'done' ? `Atendimento ${t.code} finalizado` : status === 'no_show' ? `${t.code} marcada como ausente` : `${t.code} cancelada`);

    function transfer(t) {
        const pick = h('select', { 'aria-label': 'Serviço de destino' },
            services.filter((s) => s.active && s.id !== t.service_id)
                .map((s) => h('option', { value: s.id }, `${s.prefix} · ${s.name}`)));
        const keep = h('input', { type: 'checkbox', checked: true });
        const ok = h('button', { class: 'btn primary', type: 'submit' }, 'Transferir');
        const form = h('form', { class: 'stack' },
            h('p', { style: 'margin:0' }, 'Enviar a senha ', h('b', {}, t.code), ' para:'),
            pick,
            h('label', { class: 'check' }, keep, 'Manter a posição na fila'),
            h('div', { class: 'row' }, ok, h('button', { class: 'btn ghost', type: 'button', onclick: () => dlg.close() }, 'Cancelar')));
        const dlg = h('dialog', { class: 'card' }, form);
        form.addEventListener('submit', (e) => {
            e.preventDefault();
            busy(ok, async () => {
                const r = await rpc('transfer_ticket', { p_ticket: t.id, p_service: pick.value, p_keep_position: keep.checked });
                dlg.close();
                toast(`${r.code} transferida para ${r.service}`);
                await refresh();
            });
        });
        dlg.addEventListener('close', () => dlg.remove());
        document.body.append(dlg);
        dlg.showModal();
    }

    // Senha emitida pela recepção, para quem não usa o totem.
    function issueAtDesk() {
        const pick = h('select', { 'aria-label': 'Serviço' },
            services.filter((s) => s.active).map((s) => h('option', { value: s.id }, `${s.prefix} · ${s.name}`)));
        const prio = h('select', { 'aria-label': 'Tipo de atendimento' },
            [...PRIORITIES].reverse().map((p) => h('option', { value: p.value }, p.label)));
        const ok = h('button', { class: 'btn primary', type: 'submit' }, 'Emitir');
        const form = h('form', { class: 'stack' },
            h('h2', { style: 'margin:0' }, 'Emitir senha no balcão'),
            h('div', {}, h('label', {}, 'Serviço'), pick),
            h('div', {}, h('label', {}, 'Tipo de atendimento'), prio),
            h('div', { class: 'row' }, ok, h('button', { class: 'btn ghost', type: 'button', onclick: () => dlg.close() }, 'Fechar')));
        const dlg = h('dialog', { class: 'card' }, form);
        form.addEventListener('submit', (e) => {
            e.preventDefault();
            busy(ok, async () => {
                const t = await rpc('issue_ticket', {
                    p_token: unit.kiosk_token, p_service: pick.value, p_priority: Number(prio.value),
                });
                dlg.close();
                toast(`Senha ${t.code} emitida · ${t.ahead} na frente`);
                await refresh();
            });
        });
        dlg.addEventListener('close', () => dlg.remove());
        document.body.append(dlg);
        dlg.showModal();
    }

    // ---------- desenho ----------
    function renderCounters() {
        const active = counters.filter((c) => c.active);
        if (!active.some((c) => c.id === counterId)) {
            counterId = active[0]?.id ?? '';
            store.set('desk.counter_id', counterId);
        }
        mount(counterSelect, active.map((c) => h('option', { value: c.id }, c.name)));
        counterSelect.value = counterId;
        counterSelect.disabled = active.length === 0;
    }

    function renderScope() {
        const c = counter();
        if (!c) {
            mount(scope, h('span', {}, 'Nenhum guichê cadastrado. ', h('a', { href: '#/config' }, 'Cadastre em Configurar')));
            return;
        }
        const names = c.service_ids?.length
            ? services.filter((s) => c.service_ids.includes(s.id)).map((s) => s.name).join(', ')
            : 'todos os serviços';
        mount(scope, `Atende ${names}${c.priority_only ? ' · só senhas prioritárias' : ''}. `,
            h('a', { href: '#/config' }, 'Alterar'));
    }

    function render() {
        renderScope();
        const c = counter();
        const cur = tickets.find((t) => t.status === 'called' && t.counter_id === counterId);
        const waiting = tickets.filter((t) => t.status === 'waiting' && serves(t));
        const others = tickets.filter((t) => t.status === 'called' && t.counter_id !== counterId);

        const nextBtn = h('button', { class: 'btn primary big', type: 'button', id: 'next' },
            cur ? 'Finalizar e chamar próxima' : 'Chamar próxima', ` (${waiting.length})`);
        nextBtn.disabled = !c;
        nextBtn.addEventListener('click', () => callNext(nextBtn));

        const curCard = h('section', { class: 'card desk-current', 'aria-live': 'polite' },
            cur
                ? [h('div', { class: 'muted' }, 'Em atendimento · ', svcName(cur.service_id)),
                    h('div', { class: 'code' }, cur.code),
                    h('div', { class: 'row', style: 'justify-content:center;margin-top:.5rem' },
                        priorityShort(cur.priority) ? h('span', { class: 'badge pref' }, priorityShort(cur.priority)) : null,
                        h('span', { class: 'badge' }, `chamada há ${minutesSince(cur.called_at)} min`),
                        cur.call_count > 1 ? h('span', { class: 'badge' }, `${cur.call_count}ª chamada`) : null),
                    h('div', { class: 'desk-actions' },
                        btn('🔁 Rechamar', (b) => recall(b, cur), { id: 'recall' }),
                        btn('✅ Finalizar', (b) => finish(b, cur, 'done'), { id: 'finish' }),
                        btn('↪️ Transferir', () => transfer(cur)),
                        btn('🚫 Ausente', (b) => finish(b, cur, 'no_show'), { class: 'btn danger' }))]
                : [h('div', { class: 'muted' }, c?.name ?? '—'),
                    h('p', { style: 'font-size:1.2rem;margin:.75rem 0 0' }, 'Nenhuma senha em atendimento')],
            h('div', { style: 'margin-top:1.25rem' }, nextBtn));

        const issueBtn = h('button', { class: 'btn small', type: 'button' }, '＋ Emitir senha');
        issueBtn.addEventListener('click', issueAtDesk);

        const queueCard = h('section', { class: 'card' },
            h('div', { class: 'row spread' },
                h('h2', { style: 'margin:0' }, 'Fila'),
                h('div', { class: 'row' }, h('span', { class: 'muted small' }, `${waiting.length} aguardando`), issueBtn)),
            waiting.length
                ? h('ol', { class: 'queue-list' }, waiting.map((t) => h('li', {},
                    h('span', { class: 'code' }, t.code),
                    h('span', { class: 'grow' }, svcName(t.service_id), ' · ', fmtTime(t.issued_at, unit.timezone), ` · ${minutesSince(t.issued_at)} min`),
                    priorityShort(t.priority) ? h('span', { class: 'badge pref' }, priorityShort(t.priority)) : null,
                    btn('Cancelar', (b) => { if (confirm(`Cancelar a senha ${t.code}?`)) finish(b, t, 'cancelled'); }, { class: 'btn ghost small', 'aria-label': `Cancelar senha ${t.code}` }))))
                : h('p', { class: 'empty' }, 'Ninguém aguardando.'),
            others.length
                ? h('div', { style: 'margin-top:1rem' },
                    h('h3', { class: 'muted' }, 'Em outros guichês'),
                    h('ul', { class: 'queue-list' }, others.map((t) => h('li', {},
                        h('span', { class: 'code' }, t.code),
                        h('span', { class: 'grow' }, t.counter_name)))))
                : null);

        mount(body, h('div', { class: 'desk' }, curCard, queueCard));
    }

    function btn(label, onClick, attrs = {}) {
        const b = h('button', { class: 'btn', type: 'button', ...attrs }, label);
        b.addEventListener('click', () => onClick(b));
        return b;
    }

    const refresh = async () => {
        const [s, c, t] = await Promise.all([
            supabase.from('services').select('*').order('sort_order').order('prefix'),
            supabase.from('counters').select('*').order('sort_order').order('name'),
            supabase.from('tickets')
                .select('id,code,status,priority,counter_id,counter_name,issued_at,called_at,last_call_at,call_count,service_id')
                .eq('service_day', todayIn(unit.timezone))
                .in('status', ['waiting', 'called'])
                .order('priority', { ascending: false })
                .order('issued_at'),
        ]);
        if (s.error) throw s.error;
        if (c.error) throw c.error;
        if (t.error) throw t.error;
        const countersChanged = JSON.stringify(c.data) !== JSON.stringify(counters);
        services = s.data;
        counters = c.data;
        tickets = t.data;
        if (countersChanged) renderCounters();
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
    hello();
    const stop = live(`unit:${unit.kiosk_token}`, refresh);
    const ageTimer = setInterval(render, 30000);
    return () => {
        stop();
        clearInterval(ageTimer);
        clearInterval(helloTimer);
        bc?.close();
        document.removeEventListener('keydown', onKey);
    };
}
