// Configuração: unidade, serviços, guichês, links públicos e ações da demonstração.
import { supabase } from '../supabase.js';
import { state, loadUnit } from '../app.js';
import { busy, fmtInt, h, mount, rpc, toast } from '../lib.js';

export async function viewConfig(app) {
    let services = [];
    let counters = [];

    // ---------- unidade ----------
    const nameInput = h('input', { type: 'text', id: 'unit-name', value: state.unit.name, maxlength: '60', required: true });
    const recallsInput = h('input', { type: 'number', id: 'max-recalls', value: state.unit.max_recalls, min: '1', max: '10', required: true });
    const targetInput = h('input', { type: 'number', id: 'wait-target', value: state.unit.wait_target_minutes, min: '1', max: '240', required: true });
    const saveUnit = h('button', { class: 'btn primary', type: 'submit' }, 'Salvar');
    const unitForm = h('form', { class: 'row', style: 'align-items:flex-end' },
        h('div', { style: 'flex:1 1 240px' }, h('label', { for: 'unit-name' }, 'Nome da unidade (aparece no totem e no painel)'), nameInput),
        h('div', { style: 'flex:0 1 150px' }, h('label', { for: 'max-recalls' }, 'Rechamadas até ausente'), recallsInput),
        h('div', { style: 'flex:0 1 150px' }, h('label', { for: 'wait-target' }, 'Meta de espera (min)'), targetInput),
        saveUnit);
    unitForm.addEventListener('submit', (e) => {
        e.preventDefault();
        busy(saveUnit, async () => {
            const { error } = await supabase.from('units').update({
                name: nameInput.value.trim(),
                max_recalls: Number(recallsInput.value),
                wait_target_minutes: Number(targetInput.value),
            }).eq('id', state.unit.id);
            if (error) throw error;
            await loadUnit();
            toast('Configuração salva');
        });
    });

    // ---------- serviços ----------
    const list = h('div');
    const newName = h('input', { type: 'text', id: 'svc-name', maxlength: '40', placeholder: 'Ex.: Matrícula', required: true });
    const newPrefix = h('input', { type: 'text', id: 'svc-prefix', maxlength: '1', placeholder: 'D', required: true, style: 'text-transform:uppercase', pattern: '[A-Za-z]' });
    const addBtn = h('button', { class: 'btn primary', type: 'submit' }, 'Adicionar');
    const addForm = h('form', { class: 'row', style: 'align-items:flex-end;margin-top:1rem' },
        h('div', { style: 'flex:1 1 220px' }, h('label', { for: 'svc-name' }, 'Novo serviço'), newName),
        h('div', { style: 'flex:0 0 90px' }, h('label', { for: 'svc-prefix' }, 'Letra'), newPrefix),
        addBtn);
    addForm.addEventListener('submit', (e) => {
        e.preventDefault();
        busy(addBtn, async () => {
            const prefix = newPrefix.value.trim().toUpperCase();
            if (services.some((s) => s.prefix === prefix)) throw new Error(`A letra ${prefix} já está em uso.`);
            const { error } = await supabase.from('services').insert({
                unit_id: state.unit.id, name: newName.value.trim(), prefix,
                sort_order: Math.max(0, ...services.map((s) => s.sort_order)) + 1,
            });
            if (error) throw error;
            newName.value = '';
            newPrefix.value = '';
            toast('Serviço adicionado');
            await load();
        });
    });

    async function loadServices() {
        const { data, error } = await supabase.from('services').select('*').order('sort_order').order('prefix');
        if (error) throw error;
        services = data;
        mount(list, h('div', { class: 'table-wrap' }, h('table', {},
            h('thead', {}, h('tr', {}, h('th', {}, 'Letra'), h('th', {}, 'Serviço'), h('th', {}, 'No totem'), h('th', {}, ''))),
            h('tbody', {}, services.map((s) => {
                const active = h('input', { type: 'checkbox', checked: s.active, 'aria-label': `Mostrar ${s.name} no totem` });
                active.addEventListener('change', async () => {
                    const { error: err } = await supabase.from('services').update({ active: active.checked }).eq('id', s.id);
                    if (err) { active.checked = !active.checked; toast(err.message, true); return; }
                    toast(active.checked ? `${s.name} ativado` : `${s.name} desativado`);
                });
                const del = h('button', { class: 'btn ghost danger', type: 'button' }, 'Excluir');
                del.addEventListener('click', () => {
                    if (!confirm(`Excluir o serviço "${s.name}"?`)) return;
                    busy(del, async () => {
                        const { error: err } = await supabase.from('services').delete().eq('id', s.id);
                        if (err) {
                            if (err.code === '23503') throw new Error('Este serviço já tem senhas. Desmarque “No totem” para desativá-lo.');
                            throw err;
                        }
                        toast('Serviço excluído');
                        await load();
                    });
                });
                return h('tr', {},
                    h('td', { class: 'code' }, s.prefix),
                    h('td', {}, s.name),
                    h('td', {}, h('label', { class: 'check' }, active, s.active ? 'Ativo' : 'Inativo')),
                    h('td', { class: 'num' }, del));
            })))));
    }

    // ---------- guichês ----------
    const counterList = h('div');
    const newCounter = h('input', { type: 'text', id: 'cnt-name', maxlength: '30', placeholder: 'Ex.: Guichê 3', required: true });
    const addCounter = h('button', { class: 'btn primary', type: 'submit' }, 'Adicionar');
    const counterForm = h('form', { class: 'row', style: 'align-items:flex-end;margin-top:1rem' },
        h('div', { style: 'flex:1 1 220px' }, h('label', { for: 'cnt-name' }, 'Novo guichê'), newCounter),
        addCounter);
    counterForm.addEventListener('submit', (e) => {
        e.preventDefault();
        busy(addCounter, async () => {
            const { error } = await supabase.from('counters').insert({
                unit_id: state.unit.id, name: newCounter.value.trim(),
                sort_order: Math.max(0, ...counters.map((c) => c.sort_order)) + 1,
            });
            if (error) throw error;
            newCounter.value = '';
            toast('Guichê adicionado');
            await load();
        });
    });

    const saveCounter = async (c, patch, revert) => {
        const { error } = await supabase.from('counters').update(patch).eq('id', c.id);
        if (error) { revert?.(); toast(error.message, true); return false; }
        return true;
    };

    async function loadCounters() {
        const { data, error } = await supabase.from('counters').select('*').order('sort_order').order('name');
        if (error) throw error;
        counters = data;
        mount(counterList, h('div', { class: 'table-wrap' }, h('table', {},
            h('thead', {}, h('tr', {},
                h('th', {}, 'Guichê'), h('th', {}, 'Serviços que atende'),
                h('th', {}, 'Só prioritárias'), h('th', {}, 'Ativo'), h('th', {}, ''))),
            h('tbody', {}, counters.map((c) => {
                const picks = h('div', { class: 'service-picks' }, services.filter((s) => s.active).map((s) => {
                    const on = !c.service_ids.length || c.service_ids.includes(s.id);
                    const cb = h('input', { type: 'checkbox', checked: on, 'aria-label': `${c.name} atende ${s.name}` });
                    cb.addEventListener('change', async () => {
                        const active = services.filter((x) => x.active);
                        const ids = active.filter((x) => (x.id === s.id
                            ? cb.checked
                            : !c.service_ids.length || c.service_ids.includes(x.id))).map((x) => x.id);
                        // todos marcados = lista vazia: o guichê acompanha os serviços novos
                        const next = ids.length === active.length ? [] : ids;
                        if (await saveCounter(c, { service_ids: next }, () => { cb.checked = !cb.checked; })) await load();
                    });
                    return h('label', { class: 'check' }, cb, s.prefix);
                }));
                const only = h('input', { type: 'checkbox', checked: c.priority_only, 'aria-label': `${c.name} atende só prioritárias` });
                only.addEventListener('change', () => saveCounter(c, { priority_only: only.checked },
                    () => { only.checked = !only.checked; }));
                const active = h('input', { type: 'checkbox', checked: c.active, 'aria-label': `${c.name} ativo` });
                active.addEventListener('change', () => saveCounter(c, { active: active.checked },
                    () => { active.checked = !active.checked; }));
                const del = h('button', { class: 'btn ghost danger', type: 'button' }, 'Excluir');
                del.addEventListener('click', () => {
                    if (!confirm(`Excluir o guichê "${c.name}"?`)) return;
                    busy(del, async () => {
                        const { error: err } = await supabase.from('counters').delete().eq('id', c.id);
                        if (err) throw err;
                        toast('Guichê excluído');
                        await load();
                    });
                });
                return h('tr', {},
                    h('td', {}, c.name),
                    h('td', {}, picks),
                    h('td', {}, h('label', { class: 'check' }, only)),
                    h('td', {}, h('label', { class: 'check' }, active)),
                    h('td', { class: 'num' }, del));
            })))));
    }

    const load = async () => { await loadServices(); await loadCounters(); };

    // ---------- links e demonstração ----------
    const rotate = h('button', { class: 'btn', type: 'button' }, 'Gerar novos links');
    rotate.addEventListener('click', () => {
        if (!confirm('Os links atuais do totem e do painel deixam de funcionar. Continuar?')) return;
        busy(rotate, async () => {
            await rpc('rotate_tokens');
            await loadUnit();
            toast('Links trocados. Abra o início para pegar os novos.');
        });
    });
    const closeDay = h('button', { class: 'btn', type: 'button' }, 'Encerrar senhas em aberto');
    closeDay.addEventListener('click', () => {
        if (!confirm('Cancelar as senhas que ainda estão na fila ou em atendimento?')) return;
        busy(closeDay, async () => toast(`${fmtInt(await rpc('reset_today'))} senhas encerradas`));
    });
    const reset = h('button', { class: 'btn', type: 'button' }, 'Apagar senhas de hoje');
    reset.addEventListener('click', () => {
        if (!confirm('Apagar todas as senhas de hoje e recomeçar a numeração? Não dá para desfazer.')) return;
        busy(reset, async () => toast(`${fmtInt(await rpc('reset_today', { p_delete: true }))} senhas apagadas`));
    });
    const seed = h('button', { class: 'btn', type: 'button' }, 'Gerar histórico de exemplo');
    seed.addEventListener('click', () => busy(seed, async () => {
        toast(`${fmtInt(await rpc('seed_demo_history', { p_days: 30 }))} senhas de exemplo geradas`);
    }));
    const end = h('button', { class: 'btn danger', type: 'button' }, 'Encerrar demonstração');
    end.addEventListener('click', () => {
        if (!confirm('Apagar sua unidade, serviços e senhas? Não dá para desfazer.')) return;
        busy(end, async () => {
            const { error } = await supabase.from('units').delete().eq('id', state.unit.id);
            if (error) throw error;
            await supabase.auth.signOut();
            toast('Demonstração encerrada');
        });
    });

    mount(app,
        h('h1', {}, 'Configurar'),
        h('div', { class: 'stack' },
            h('section', { class: 'card' }, unitForm),
            h('section', { class: 'card' },
                h('h2', {}, 'Serviços'),
                h('p', { class: 'small muted' }, 'A letra forma a senha (ex.: A001; prioritária AP001, 80+ AE001, doador AD001). Serviços com senhas não podem ser excluídos, só desativados.'),
                list, addForm),
            h('section', { class: 'card' },
                h('h2', {}, 'Guichês'),
                h('p', { class: 'small muted' }, 'Cada guichê atende os serviços marcados; sem marcação própria, atende todos. “Só prioritárias” cria o guichê exclusivo previsto na Lei 14.626/2023.'),
                counterList, counterForm),
            h('section', { class: 'card' },
                h('h2', {}, 'Operação do dia'),
                h('p', { class: 'small muted' }, 'Encerrar cancela as senhas em aberto e mantém o histórico dos relatórios. Apagar recomeça a numeração e serve para testar.'),
                h('div', { class: 'row' }, closeDay, reset, rotate)),
            h('section', { class: 'card' },
                h('h2', {}, 'Demonstração'),
                h('div', { class: 'row' }, seed, end))));
    await load();
}
