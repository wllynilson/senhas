// Configuração: nome da unidade, serviços e ações da demonstração.
import { supabase } from '../supabase.js';
import { state, loadUnit } from '../app.js';
import { busy, fmtInt, h, mount, rpc, toast } from '../lib.js';

export async function viewConfig(app) {
    let services = [];

    const nameInput = h('input', { type: 'text', id: 'unit-name', value: state.unit.name, maxlength: '60', required: true });
    const saveName = h('button', { class: 'btn primary', type: 'submit' }, 'Salvar');
    const nameForm = h('form', { class: 'row', style: 'align-items:flex-end' },
        h('div', { style: 'flex:1 1 260px' }, h('label', { for: 'unit-name' }, 'Nome da unidade (aparece no totem e no painel)'), nameInput),
        saveName);
    nameForm.addEventListener('submit', (e) => {
        e.preventDefault();
        busy(saveName, async () => {
            const { error } = await supabase.from('units').update({ name: nameInput.value.trim() }).eq('id', state.unit.id);
            if (error) throw error;
            await loadUnit();
            toast('Nome salvo');
        });
    });

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

    async function load() {
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

    const reset = h('button', { class: 'btn', type: 'button' }, 'Zerar senhas de hoje');
    reset.addEventListener('click', () => {
        if (!confirm('Apagar todas as senhas de hoje e recomeçar a numeração?')) return;
        busy(reset, async () => toast(`${fmtInt(await rpc('reset_today'))} senhas apagadas`));
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
            h('section', { class: 'card' }, nameForm),
            h('section', { class: 'card' },
                h('h2', {}, 'Serviços'),
                h('p', { class: 'small muted' }, 'A letra forma a senha (ex.: A001; preferencial AP001). Serviços com senhas não podem ser excluídos, só desativados.'),
                list, addForm),
            h('section', { class: 'card' },
                h('h2', {}, 'Demonstração'),
                h('div', { class: 'row' }, seed, reset, end))));
    await load();
}
