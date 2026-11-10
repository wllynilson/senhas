-- Testes do schema. Roda como superusuário e troca de papel com SET ROLE.
\set ON_ERROR_STOP 1

create schema t;
grant usage on schema t to public;
create function t.eq(got anyelement, want anyelement, msg text) returns void language plpgsql as $$
begin
    if got is distinct from want then
        raise exception 'FALHOU: % (obtido %, esperado %)', msg, got, want;
    end if;
end $$;
create function t.fails(q text, msg text) returns void language plpgsql as $$
begin
    begin
        execute q;
    exception when others then
        return;
    end;
    raise exception 'FALHOU: deveria dar erro: %', msg;
end $$;
create function t.as_user(u text) returns void language sql as $$
    select set_config('request.jwt.claim.sub', u, false);
$$;
grant execute on all functions in schema t to public;

\echo '-- unidade de demonstração'
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select (public.create_demo_unit('Clínica A')).kiosk_token as tok_a \gset
select t.eq((select count(*) from public.services)::int, 3, 'serviços padrão');
select t.eq((public.create_demo_unit()).kiosk_token, :'tok_a', 'segunda chamada devolve a mesma unidade');
select id as unit_a from public.units \gset
select id as svc_a from public.services where prefix = 'A' \gset
select id as svc_b from public.services where prefix = 'B' \gset
select t.fails($$update public.units set kiosk_token = 'x'$$, 'não pode trocar o token');
update public.units set name = 'Clínica A1';
select t.eq((select name from public.units), 'Clínica A1', 'pode renomear');

\echo '-- totem sem login'
reset role;
set role anon;
select t.as_user('');
select (public.issue_ticket(:'tok_a', :'svc_a', false))->>'code' as c1 \gset
select (public.issue_ticket(:'tok_a', :'svc_a', true))->>'code' as c2 \gset
select public.issue_ticket(:'tok_a', :'svc_a', false) as r3 \gset
select public.issue_ticket(:'tok_a', :'svc_b', false) as r4 \gset
select t.eq(:'c1'::text, 'A001', 'primeira senha');
select t.eq(:'c2'::text, 'AP001', 'preferencial tem numeração própria');
select t.eq((:'r3'::jsonb)->>'code', 'A002', 'segunda normal');
select t.eq(((:'r3'::jsonb)->>'ahead')::int, 2, 'A002 tem duas na frente (AP001 e A001)');
select t.eq((:'r4'::jsonb)->>'code', 'B001', 'outro serviço');
select t.eq(((:'r4'::jsonb)->>'ahead')::int, 0, 'fila por serviço');
select t.fails($$select public.issue_ticket('errado', null, false)$$, 'token inválido');
select t.fails($$select * from public.tickets$$, 'anon não lê tabelas');
select t.fails($$select public.call_next('G1')$$, 'anon não chama senha');
select t.eq(jsonb_array_length((public.panel_state(:'tok_a'))->'services'), 3, 'painel lista serviços');
select t.eq(((public.ticket_status((:'r3'::jsonb)->>'public_code'))->>'status'), 'waiting', 'QR mostra aguardando');
select t.eq(public.ticket_status('inexistente'), null::jsonb, 'QR inválido');

\echo '-- guichê'
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select t.eq((public.call_next('Guichê 1', array[:'svc_a']::uuid[]))->>'code', 'AP001', 'preferencial primeiro');
select t.eq((public.call_next('Guichê 1', array[:'svc_a']::uuid[]))->>'code', 'A001', 'depois ordem de chegada');
select t.eq((select status from public.tickets where code = 'AP001'), 'done', 'anterior finalizada ao chamar a próxima');
select t.eq((public.call_next('Guichê 2'))->>'code', 'A002', 'guichê 2 pega a próxima de todos os serviços');
select t.eq(((public.ticket_status((:'r3'::jsonb)->>'public_code'))->>'counter'), 'Guichê 2', 'QR mostra o guichê');
select id as a002 from public.tickets where code = 'A002' \gset
select public.recall_ticket(:'a002');
select t.eq((select call_count from public.tickets where id = :'a002'), 2, 'rechamada conta');
select t.eq(((public.panel_state(:'tok_a'))->'calls'->0->>'code'), 'A002', 'painel mostra a última chamada no topo');
select public.finish_ticket(:'a002', 'no_show');
select t.fails(format($$select public.finish_ticket(%L, 'done')$$, :'a002'), 'senha finalizada não muda');
select t.fails($$select public.call_next('')$$, 'guichê obrigatório');
select t.eq((public.call_next('Guichê 2', array[:'svc_a']::uuid[])), null::jsonb, 'fila vazia');

\echo '-- isolamento entre visitantes'
select t.as_user('00000000-0000-0000-0000-00000000000b');
select t.eq((select count(*) from public.tickets)::int, 0, 'B não vê senhas de A');
select t.eq((select count(*) from public.units)::int, 0, 'B não vê unidade de A');
select t.fails($$select public.call_next('G1')$$, 'B sem unidade não chama');
select t.fails(format($$select public.recall_ticket(%L)$$, :'a002'), 'B não rechama senha de A');
select t.fails(format($$insert into public.services (unit_id, name, prefix) values (%L, 'x', 'Z')$$, :'unit_a'), 'B não cria serviço em A');
select (public.create_demo_unit()).kiosk_token as tok_b \gset
select t.eq((select count(*) from public.services)::int, 3, 'B vê só os próprios serviços');
select t.eq((public.call_next('G1', array[:'svc_a']::uuid[])), null::jsonb, 'B não pega senha de A pelo id do serviço');

\echo '-- relatórios e histórico'
select t.as_user('00000000-0000-0000-0000-00000000000a');
select public.seed_demo_history(14) as seeded \gset
select t.eq(:seeded > 300, true, 'histórico gerado');
select t.fails('select public.seed_demo_history(14)', 'histórico só uma vez');
select public.report(current_date - 30, current_date) as rep \gset
select t.eq(((:'rep'::jsonb)->'totals'->>'issued')::int, :seeded + 4, 'total no relatório');
select t.eq(jsonb_array_length((:'rep'::jsonb)->'by_service'), 3, 'por serviço');
select t.eq(((:'rep'::jsonb)->'totals'->>'avg_wait')::int between 120 and 1920, true, 'espera média plausível');
select t.eq((select bool_and((e->>'hour')::int between 8 and 16) from jsonb_array_elements((public.report(current_date - 30, current_date - 1))->'by_hour') e), true, 'horários do histórico entre 8h e 17h');
select t.fails('select public.report(current_date, current_date - 1)', 'período inválido');
select t.eq(public.reset_today(), 4, 'zerar hoje apaga só as de hoje');
select t.eq((select count(*) from public.tickets)::int, :seeded, 'histórico mantido');

\echo '-- tempo real e limite'
reset role;
select t.eq((select count(*) > 0 from realtime.log where topic = 'unit:' || :'tok_a' and not private), true, 'aviso no canal da unidade');
select t.eq((select count(*) from realtime.log where topic = 'unit:' || :'tok_b'), 1::bigint, 'B só recebeu o aviso da criação dos serviços');
set role anon;
select t.as_user('');
select public.issue_ticket(:'tok_a', :'svc_a', false) from generate_series(1, 30);
select t.fails(format($$select public.issue_ticket(%L, %L, false)$$, :'tok_a', :'svc_a'), 'limite de 30 por minuto');

\echo '-- serviço com senhas não é excluído; unidade apaga tudo'
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$delete from public.services where id = %L$$, :'svc_a'), 'serviço com senhas');
update public.services set active = false where id = :'svc_b';
select t.eq(jsonb_array_length((public.panel_state(:'tok_a'))->'services'), 2, 'inativo some do totem');
delete from public.units;
reset role;
select t.eq((select count(*) from public.tickets where unit_id not in (select id from public.units))::int, 0, 'senhas apagadas com a unidade');
select t.eq((select count(*) from public.units)::int, 1, 'só a unidade de B');

\echo '-- limpeza'
update public.units set last_activity_at = now() - interval '31 days';
select public.cleanup_demo();
select t.eq((select count(*) from public.units)::int, 0, 'unidade inativa removida');
select t.eq((select count(*) from auth.users)::int, 2, 'anônimo antigo sem unidade removido');
