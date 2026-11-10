// Relatórios: indicadores, senhas por dia e por hora, tabela por serviço.
import { state } from '../app.js';
import { addDays, busy, fmtDayShort, fmtDuration, fmtInt, fmtWeekday, h, mount, rpc, toast, todayIn } from '../lib.js';

const PERIODS = [['Hoje', 0], ['7 dias', 6], ['14 dias', 13], ['30 dias', 29]];
const SVG = 'http://www.w3.org/2000/svg';

export async function viewReports(app) {
    const unit = state.unit;
    let span = 13;
    const body = h('div', { class: 'stack' });
    const seg = h('div', { class: 'seg', role: 'group', 'aria-label': 'Período' });

    const renderSeg = () => mount(seg, PERIODS.map(([label, d]) => {
        const b = h('button', { type: 'button', class: d === span ? 'on' : '', 'aria-pressed': String(d === span) }, label);
        b.addEventListener('click', () => { span = d; renderSeg(); load(); });
        return b;
    }));
    renderSeg();

    mount(app,
        h('div', { class: 'row spread', style: 'margin-bottom:1rem' }, h('h1', { style: 'margin:0' }, 'Relatórios'), seg),
        body);

    async function load() {
        const to = todayIn(unit.timezone);
        const from = addDays(to, -span);
        mount(body, h('p', { class: 'muted' }, 'Carregando…'));
        const r = await rpc('report', { p_from: from, p_to: to });
        render(r, from, to);
    }

    function render(r, from, to) {
        const t = r.totals;
        const seed = h('button', { class: 'btn primary', type: 'button' }, 'Gerar histórico de exemplo');
        seed.addEventListener('click', () => busy(seed, async () => {
            const n = await rpc('seed_demo_history', { p_days: 30 });
            toast(`${fmtInt(n)} senhas de exemplo geradas`);
            if (span === 0) span = 13;
            renderSeg();
            await load();
        }));
        const noHistory = !r.by_day.some((d) => d.day < to);
        if (!t.issued) {
            mount(body, h('div', { class: 'card empty' },
                h('p', {}, 'Nenhuma senha neste período.'),
                h('p', { class: 'small' }, 'Para ver os relatórios em ação, gere 30 dias de movimento fictício.'),
                seed));
            return;
        }

        const kpi = (label, value) => h('div', { class: 'card kpi' }, h('div', { class: 'value' }, value), h('div', { class: 'label' }, label));
        const pct = (a, b) => (b ? `${Math.round((a / b) * 100)}%` : '—');

        // dias do período sem senha aparecem zerados
        const byDay = new Map(r.by_day.map((d) => [d.day, d]));
        const days = [];
        for (let d = from; d <= to; d = addDays(d, 1)) days.push(byDay.get(d) || { day: d, issued: 0, done: 0, avg_wait: null });
        const byHour = new Map(r.by_hour.map((x) => [x.hour, x.issued]));
        const hours = [];
        const hs = r.by_hour.map((x) => x.hour);
        for (let hr = Math.min(8, ...hs); hr <= Math.max(17, ...hs); hr++) hours.push({ hour: hr, issued: byHour.get(hr) || 0 });

        mount(body,
            noHistory && span > 0
                ? h('div', { class: 'notice row spread' },
                    h('span', {}, 'Só há senhas de hoje. Gere 30 dias de movimento fictício para ver os gráficos completos.'), seed)
                : null,
            h('div', { class: 'kpis' },
                kpi('Senhas emitidas', fmtInt(t.issued)),
                kpi('Atendidas', fmtInt(t.done)),
                kpi('Ausentes', `${fmtInt(t.no_show)} (${pct(t.no_show, t.issued)})`),
                kpi('Espera média', fmtDuration(t.avg_wait)),
                kpi('Atendimento médio', fmtDuration(t.avg_service)),
                kpi('Preferenciais', pct(t.preferential, t.issued))),
            span > 0
                ? h('section', { class: 'card' },
                    h('h2', {}, 'Senhas emitidas por dia'),
                    barChart(days.map((d) => ({
                        label: fmtDayShort(d.day), sub: fmtWeekday(d.day), value: d.issued,
                        tip: `${fmtWeekday(d.day)} ${fmtDayShort(d.day)}: ${fmtInt(d.issued)} senhas · espera média ${fmtDuration(d.avg_wait)}`,
                    }))),
                    dataTable(['Dia', 'Emitidas', 'Atendidas', 'Espera média'],
                        days.map((d) => [`${fmtWeekday(d.day)} ${fmtDayShort(d.day)}`, fmtInt(d.issued), fmtInt(d.done), fmtDuration(d.avg_wait)])))
                : null,
            h('section', { class: 'card' },
                h('h2', {}, 'Senhas por hora de emissão'),
                h('p', { class: 'small muted' }, 'Mostra os horários de pico para planejar quantos guichês abrir.'),
                barChart(hours.map((x) => ({
                    label: `${x.hour}h`, value: x.issued, tip: `${x.hour}h–${x.hour + 1}h: ${fmtInt(x.issued)} senhas`,
                })))),
            h('section', { class: 'card' },
                h('h2', {}, 'Por serviço'),
                h('div', { class: 'table-wrap' }, h('table', {},
                    h('thead', {}, h('tr', {},
                        h('th', {}, 'Serviço'), h('th', { class: 'num' }, 'Emitidas'), h('th', { class: 'num' }, 'Atendidas'),
                        h('th', { class: 'num' }, 'Ausentes'), h('th', { class: 'num' }, 'Preferenciais'),
                        h('th', { class: 'num' }, 'Espera média'), h('th', { class: 'num' }, 'Atendimento médio'))),
                    h('tbody', {}, r.by_service.map((s) => h('tr', {},
                        h('td', {}, `${s.prefix} · ${s.name}`), h('td', { class: 'num' }, fmtInt(s.issued)),
                        h('td', { class: 'num' }, fmtInt(s.done)), h('td', { class: 'num' }, fmtInt(s.no_show)),
                        h('td', { class: 'num' }, fmtInt(s.preferential)), h('td', { class: 'num' }, fmtDuration(s.avg_wait)),
                        h('td', { class: 'num' }, fmtDuration(s.avg_service)))))))));
    }

    await load();
}

// Tabela recolhível com os mesmos dados do gráfico (acessibilidade)
function dataTable(headers, rows) {
    return h('details', { style: 'margin-top:.75rem' },
        h('summary', { class: 'small muted', style: 'cursor:pointer' }, 'Ver em tabela'),
        h('div', { class: 'table-wrap' }, h('table', {},
            h('thead', {}, h('tr', {}, headers.map((x, i) => h('th', { class: i ? 'num' : '' }, x)))),
            h('tbody', {}, rows.map((r) => h('tr', {}, r.map((c, i) => h('td', { class: i ? 'num' : '' }, c))))))));
}

// Gráfico de barras de uma série (SVG): barras finas com topo arredondado,
// grade discreta, rótulo só no maior valor e dica ao passar o mouse.
function barChart(items) {
    const W = 720, H = 220, padL = 32, padR = 8, padT = 18, padB = items.some((i) => i.sub) ? 38 : 24;
    const max = Math.max(1, ...items.map((i) => i.value));
    const step = niceStep(max);
    const top = Math.ceil(max / step) * step;
    const plotW = W - padL - padR, plotH = H - padT - padB;
    const slot = plotW / items.length;
    const barW = Math.max(4, Math.min(28, slot - 6));
    const y = (v) => padT + plotH - (v / top) * plotH;

    const el = (tag, attrs) => {
        const n = document.createElementNS(SVG, tag);
        for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
        return n;
    };
    const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': 'Gráfico de barras' });
    for (let v = 0; v <= top; v += step) {
        svg.append(el('line', { class: 'grid-line', x1: padL, x2: W - padR, y1: y(v), y2: y(v) }));
        const t = el('text', { class: 'axis-label', x: padL - 6, y: y(v) + 4, 'text-anchor': 'end' });
        t.textContent = v;
        svg.append(t);
    }
    const wrap = h('div', { class: 'chart' });
    const tip = h('div', { class: 'tooltip', hidden: true });
    const maxIdx = items.findIndex((i) => i.value === max);
    const labelEvery = Math.ceil(items.length / 16);

    items.forEach((it, i) => {
        const cx = padL + slot * i + slot / 2;
        const x = cx - barW / 2;
        const bh = (it.value / top) * plotH;
        const r = Math.min(4, barW / 2, bh);
        const base = padT + plotH;
        // retângulo com só o topo arredondado, ancorado na base
        const d = bh <= 0 ? '' : `M${x},${base} V${base - bh + r} Q${x},${base - bh} ${x + r},${base - bh} H${x + barW - r} Q${x + barW},${base - bh} ${x + barW},${base - bh + r} V${base} Z`;
        const bar = el('path', { class: 'bar', d });
        const hit = el('rect', { class: 'hit', x: padL + slot * i, y: padT, width: slot, height: plotH });
        hit.addEventListener('mouseenter', () => {
            bar.classList.add('hover');
            tip.textContent = it.tip;
            tip.hidden = false;
            const box = svg.getBoundingClientRect();
            tip.style.left = `${(cx / W) * box.width}px`;
            tip.style.top = `${(y(it.value) / H) * box.height}px`;
        });
        hit.addEventListener('mouseleave', () => { bar.classList.remove('hover'); tip.hidden = true; });
        svg.append(bar, hit);
        if (i % labelEvery === 0) {
            const lb = el('text', { class: 'axis-label', x: cx, y: base + 14, 'text-anchor': 'middle' });
            lb.textContent = it.label;
            svg.append(lb);
            if (it.sub) {
                const sb = el('text', { class: 'axis-label', x: cx, y: base + 27, 'text-anchor': 'middle' });
                sb.textContent = it.sub;
                svg.append(sb);
            }
        }
        if (i === maxIdx && it.value > 0) {
            const vl = el('text', { class: 'value-label', x: cx, y: y(it.value) - 5, 'text-anchor': 'middle' });
            vl.textContent = it.value;
            svg.append(vl);
        }
    });
    wrap.append(svg, tip);
    return wrap;
}

function niceStep(max) {
    const raw = max / 4;
    const p = 10 ** Math.floor(Math.log10(raw || 1));
    const n = raw / p;
    return Math.max(1, (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p);
}
