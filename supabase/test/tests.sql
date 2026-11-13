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
select t.eq((select count(*) from public.counters)::int, 2, 'guichês padrão');
select t.eq((public.create_demo_unit()).kiosk_token, :'tok_a', 'segunda chamada devolve a mesma unidade');
select id as unit_a, display_token as disp_a from public.units \gset
select id as svc_a from public.services where prefix = 'A' \gset
select id as svc_b from public.services where prefix = 'B' \gset
select id as g1 from public.counters where name = 'Guichê 1' \gset
select id as g2 from public.counters where name = 'Guichê 2' \gset
select t.eq(:'tok_a' <> :'disp_a', true, 'totem e painel têm tokens diferentes');
select t.fails($$update public.units set kiosk_token = 'x'$$, 'não pode trocar o token do totem');
select t.fails($$update public.units set display_token = 'x'$$, 'não pode trocar o token do painel');
update public.units set name = 'Clínica A1', max_recalls = 3;
select t.eq((select name from public.units), 'Clínica A1', 'pode renomear');

\echo '-- totem sem login'
reset role;
set role anon;
select t.as_user('');
select (public.issue_ticket(:'tok_a', :'svc_a', 0))->>'code' as c1 \gset
select (public.issue_ticket(:'tok_a', :'svc_a', 2))->>'code' as c2 \gset
select public.issue_ticket(:'tok_a', :'svc_a', 0) as r3 \gset
select public.issue_ticket(:'tok_a', :'svc_b', 0) as r4 \gset
select t.eq(:'c1'::text, 'A001', 'primeira senha');
select t.eq(:'c2'::text, 'AP001', 'prioritária tem numeração própria');
select t.eq((:'r3'::jsonb)->>'code', 'A002', 'segunda normal');
select t.eq(((:'r3'::jsonb)->>'ahead')::int, 2, 'A002 tem duas na frente (AP001 e A001)');
select t.eq((:'r4'::jsonb)->>'code', 'B001', 'outro serviço');
select t.eq(((:'r4'::jsonb)->>'ahead')::int, 3, 'B001 conta a fila dos serviços que o mesmo guichê atende');
select t.eq(((:'r4'::jsonb)->>'eta')::int > 0, true, 'estimativa de espera em minutos');
select t.fails($$select public.issue_ticket('errado', null, 0)$$, 'token inválido');
select t.fails(format($$select public.issue_ticket(%L, %L, 9)$$, :'tok_a', :'svc_a'), 'prioridade inválida');
select t.fails(format($$select public.issue_ticket(%L, %L, 0)$$, :'disp_a', :'svc_a'), 'token do painel não emite senha');
select t.fails($$select * from public.tickets$$, 'anon não lê tabelas');
select t.fails($$select * from public.counters$$, 'anon não lê guichês');
select t.fails(format($$select public.call_next(%L)$$, :'g1'), 'anon não chama senha');
select t.eq(jsonb_array_length((public.panel_state(:'tok_a'))->'services'), 3, 'painel lista serviços');
select t.eq(((public.panel_state(:'disp_a'))->>'can_issue')::boolean, false, 'painel é só leitura');
select t.eq(((public.panel_state(:'tok_a'))->>'can_issue')::boolean, true, 'totem pode emitir');
select t.eq(((public.ticket_status((:'r3'::jsonb)->>'public_code'))->>'status'), 'waiting', 'QR mostra aguardando');
select t.eq(public.ticket_status('inexistente'), null::jsonb, 'QR inválido');

\echo '-- níveis de prioridade (Lei 14.626/2023 e Estatuto da Pessoa Idosa)'
select public.issue_ticket(:'tok_a', :'svc_a', 1) as rd \gset
select public.issue_ticket(:'tok_a', :'svc_a', 3) as re \gset
select t.eq((:'rd'::jsonb)->>'code', 'AD001', 'doador de sangue tem letra própria');
select t.eq((:'re'::jsonb)->>'code', 'AE001', 'prioridade especial 80+ tem letra própria');
select t.eq(((:'re'::jsonb)->>'ahead')::int, 0, '80+ não espera ninguém');
select t.eq(((:'rd'::jsonb)->>'ahead')::int, 1, 'doador só espera a prioritária comum');

\echo '-- guichê'
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select t.eq((public.call_next(:'g1'))->>'code', 'AE001', '80+ primeiro');
select t.eq((public.call_next(:'g1'))->>'code', 'AP001', 'depois a prioritária comum');
select t.eq((select status from public.tickets where code = 'AE001'), 'done', 'anterior finalizada ao chamar a próxima');
select t.eq((public.call_next(:'g2'))->>'code', 'AD001', 'doador vem depois dos demais prioritários');
select t.eq((public.call_next(:'g2'))->>'code', 'A001', 'depois a ordem de chegada');
select t.eq(((public.ticket_status((:'r3'::jsonb)->>'public_code'))->>'ahead')::int, 0, 'A002 é a próxima');
select t.fails($$select public.call_next('00000000-0000-0000-0000-0000000000ff')$$, 'guichê inexistente');

select id as a001 from public.tickets where code = 'A001' \gset
select t.eq(((public.recall_ticket(:'a001'))->>'call_count')::int, 2, 'rechamada conta');
select t.eq(((public.recall_ticket(:'a001'))->>'call_count')::int, 3, 'segunda rechamada');
select t.eq(((public.recall_ticket(:'a001'))->>'call_count')::int, 4, 'terceira rechamada');
select t.eq(((public.recall_ticket(:'a001'))->>'status'), 'no_show', 'passado o limite, vira ausente');
select t.fails(format($$select public.recall_ticket(%L)$$, :'a001'), 'senha ausente não rechama');
select t.eq((select count(*) from public.ticket_events where ticket_id = :'a001' and type = 'recalled')::int, 3, 'rechamadas no histórico');
select t.eq((select (data->>'auto')::boolean from public.ticket_events where ticket_id = :'a001' and type = 'no_show'), true, 'ausência automática registrada');
select t.eq(((public.panel_state(:'tok_a'))->'calls'->0->>'counter'), 'Guichê 2', 'painel mostra o guichê da chamada');

\echo '-- guichê exclusivo de prioritários e por serviço (Lei 14.626, §3º)'
update public.counters set priority_only = true where id = :'g2';
update public.counters set service_ids = array[:'svc_a']::uuid[] where id = :'g1';
select t.eq(public.call_next(:'g2'), null::jsonb, 'guichê só de prioritários não pega senha normal');
reset role;
set role anon;
select t.as_user('');
select public.issue_ticket(:'tok_a', :'svc_b', 2) as rbp \gset
select t.eq(((:'rbp'::jsonb)->>'ahead')::int, 0, 'prioritária de B não espera as normais de A');
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select t.eq((public.call_next(:'g2'))->>'code', 'BP001', 'guichê de prioritários pega a prioritária de B');
select t.eq((public.call_next(:'g1'))->>'code', 'A002', 'guichê de A não pega senha de B');
update public.counters set priority_only = false, service_ids = '{}' where unit_id = :'unit_a';

\echo '-- transferência entre serviços'
select id as b001 from public.tickets where code = 'B001' \gset
select t.eq((public.transfer_ticket(:'b001', :'svc_a'))->>'service', 'Atendimento geral', 'transfere para outro serviço');
select t.eq((select code from public.tickets where id = :'b001'), 'B001', 'o código mostrado não muda');
select t.eq((select service_id from public.tickets where id = :'b001'), :'svc_a'::uuid, 'serviço trocado');
select t.eq((select status from public.tickets where id = :'b001'), 'waiting', 'volta para a fila');
select t.fails(format($$select public.transfer_ticket(%L, %L)$$, :'b001', :'svc_a'), 'não transfere para o mesmo serviço');
select t.eq((select count(*) from public.ticket_events where ticket_id = :'b001' and type = 'transferred')::int, 1, 'transferência no histórico');
select t.eq((public.call_next(:'g1'))->>'code', 'B001', 'a senha transferida é chamada no destino');
select public.finish_ticket(:'b001', 'done');
select t.fails(format($$select public.finish_ticket(%L, 'done')$$, :'b001'), 'senha finalizada não muda');
select t.fails(format($$select public.transfer_ticket(%L, %L)$$, :'b001', :'svc_b'), 'senha finalizada não transfere');
select t.eq(public.call_next(:'g1'), null::jsonb, 'fila vazia');

\echo '-- troca dos links públicos'
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select (public.rotate_tokens()).kiosk_token as tok_a2 \gset
select t.eq(:'tok_a2' <> :'tok_a', true, 'token do totem trocado');
reset role;
set role anon;
select t.as_user('');
select t.fails(format($$select public.panel_state(%L)$$, :'tok_a'), 'token antigo não vale mais');
select t.eq(((public.panel_state(:'tok_a2'))->>'unit'), 'Clínica A1', 'token novo funciona');

\echo '-- isolamento entre visitantes'
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000b');
select t.eq((select count(*) from public.tickets)::int, 0, 'B não vê senhas de A');
select t.eq((select count(*) from public.units)::int, 0, 'B não vê unidade de A');
select t.eq((select count(*) from public.counters)::int, 0, 'B não vê guichês de A');
select t.eq((select count(*) from public.ticket_events)::int, 0, 'B não vê o histórico de A');
select t.fails(format($$select public.call_next(%L)$$, :'g1'), 'B sem unidade não chama');
select t.fails(format($$select public.recall_ticket(%L)$$, :'a001'), 'B não rechama senha de A');
select t.fails(format($$insert into public.services (unit_id, name, prefix) values (%L, 'x', 'Z')$$, :'unit_a'), 'B não cria serviço em A');
select t.fails(format($$insert into public.counters (unit_id, name) values (%L, 'Pirata')$$, :'unit_a'), 'B não cria guichê em A');
select t.fails('select public.rotate_tokens()', 'B sem unidade não troca tokens');
select (public.create_demo_unit()).kiosk_token as tok_b \gset
select id as g1b from public.counters where name = 'Guichê 1' \gset
select t.eq((select count(*) from public.services)::int, 3, 'B vê só os próprios serviços');
select t.fails(format($$select public.call_next(%L)$$, :'g1'), 'B não usa o guichê de A');
select t.eq(public.call_next(:'g1b'), null::jsonb, 'B começa com a fila vazia');

\echo '-- relatórios e histórico'
select t.as_user('00000000-0000-0000-0000-00000000000a');
select public.seed_demo_history(14) as seeded \gset
select t.eq(:seeded > 300, true, 'histórico gerado');
select t.fails('select public.seed_demo_history(14)', 'histórico só uma vez');
select t.eq((select count(distinct n) > 3 from (select count(*) n from public.tickets group by service_day) x), true, 'quantidade varia por dia');
select t.eq((select count(distinct priority) from public.tickets where service_day < current_date)::int, 4, 'histórico cobre os quatro níveis');
select t.eq((select count(*) from public.tickets where counter_name is null)::int, 0, 'histórico tem guichê');
select public.report(current_date - 30, current_date) as rep \gset
select t.eq(((:'rep'::jsonb)->'totals'->>'issued')::int, :seeded + 7, 'total no relatório');
select t.eq(jsonb_array_length((:'rep'::jsonb)->'by_service'), 3, 'por serviço');
select t.eq(jsonb_array_length((:'rep'::jsonb)->'by_counter'), 2, 'por guichê');
select t.eq(((:'rep'::jsonb)->'totals'->>'avg_wait')::int between 120 and 1920, true, 'espera média plausível');
select t.eq(((:'rep'::jsonb)->'totals'->>'p90_wait')::int >= ((:'rep'::jsonb)->'totals'->>'p50_wait')::int, true, 'p90 não é menor que a mediana');
select t.eq(((:'rep'::jsonb)->'totals'->>'within_target')::int <= ((:'rep'::jsonb)->'totals'->>'measured')::int, true, 'dentro da meta não passa do medido');
select t.eq(((:'rep'::jsonb)->>'wait_target')::int, 15, 'meta de espera padrão');
select t.eq(((:'rep'::jsonb)->'totals'->>'expired')::int, 0, 'nada expirado ainda');
select t.eq((select bool_and((e->>'hour')::int between 8 and 16) from jsonb_array_elements((public.report(current_date - 30, current_date - 1))->'by_hour') e), true, 'horários do histórico entre 8h e 17h');
select t.eq((select bool_and((e->>'avg_wait') is not null) from jsonb_array_elements((public.report(current_date - 30, current_date - 1))->'by_hour') e), true, 'espera média por hora');
select t.fails('select public.report(current_date, current_date - 1)', 'período inválido');

\echo '-- senhas de dias anteriores expiram'
reset role;
-- 20 dias atrás: fora do histórico de exemplo, para não colidir na numeração
update public.tickets set service_day = public.unit_today('America/Sao_Paulo') - 20,
       number = 900, status = 'waiting'
 where public_code = (:'r3'::jsonb)->>'public_code';
select t.eq(public.expire_stale_tickets(), 1, 'senha esquecida de ontem expira');
select t.eq((select status from public.tickets where public_code = (:'r3'::jsonb)->>'public_code'),
            'expired', 'status expirado');
select t.eq(public.expire_stale_tickets(), 0, 'nada a expirar na segunda vez');
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select t.eq(((public.report(current_date - 30, current_date))->'totals'->>'expired')::int, 1, 'expiradas contadas à parte');

\echo '-- encerrar o dia'
reset role;
set role anon;
select t.as_user('');
select public.issue_ticket(:'tok_a2', :'svc_a', 0) as rz \gset
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
-- em aberto hoje: a recém-emitida e a BP001, ainda em atendimento no Guichê 2
select t.eq(public.reset_today(), 2, 'encerrar cancela as senhas em aberto');
select t.eq((select status from public.tickets where public_code = (:'rz'::jsonb)->>'public_code'), 'cancelled', 'senha cancelada');
select t.eq((select count(*) from public.tickets where service_day = current_date)::int > 0, true, 'histórico de hoje preservado');
select t.eq(public.reset_today(true) > 0, true, 'modo demonstração apaga mesmo');
select t.eq((select count(*) from public.tickets where service_day = current_date)::int, 0, 'senhas de hoje apagadas');
-- o histórico e a senha expirada (movida para 20 dias atrás) continuam lá
select t.eq((select count(*) from public.tickets)::int, :seeded + 1, 'histórico mantido');

\echo '-- tempo real e limite'
reset role;
select t.eq((select count(*) > 0 from realtime.log where topic = 'unit:' || :'tok_a2' and not private), true, 'aviso no canal do totem');
select t.eq((select count(*) > 0 from realtime.log where topic = 'unit:' || :'disp_a'), true, 'aviso no canal do painel');
select t.eq((select count(*) > 0 from realtime.log where topic like 'ticket:%'), true, 'aviso no canal da senha');
select t.eq((select count(distinct topic) from realtime.log where topic like 'ticket:%') < 100, true,
            'carga grande do histórico não avisa senha por senha');
select t.eq((select count(*) > 0 from realtime.log where topic = 'unit:' || :'tok_b'), true, 'B recebeu os próprios avisos');
-- tira as senhas já emitidas da janela de um minuto
update public.tickets set issued_at = issued_at - interval '5 minutes';
set role anon;
select t.as_user('');
select public.issue_ticket(:'tok_a2', :'svc_a', 0) from generate_series(1, 30);
select t.fails(format($$select public.issue_ticket(%L, %L, 0)$$, :'tok_a2', :'svc_a'), 'limite de 30 por minuto');

\echo '-- Web Push'
reset role;
update public.tickets set issued_at = issued_at - interval '5 minutes';
set role anon;
select t.as_user('');
select public.issue_ticket(:'tok_a2', :'svc_b', 0) as rp \gset
select (:'rp'::jsonb)->>'public_code' as pc \gset
select public.subscribe_push(:'pc', 'https://push.example/abc', 'chave', 'segredo');
select public.subscribe_push(:'pc', 'https://push.example/abc', 'chave2', 'segredo');
select t.fails($$select public.subscribe_push('inexistente', 'https://push.example/x', 'k', 's')$$, 'senha inexistente');
select t.fails(format($$select public.subscribe_push(%L, '', 'k', 's')$$, :'pc'), 'endpoint inválido');
select t.fails($$select * from public.push_subscriptions$$, 'anon não lê inscrições');
reset role;
select t.eq((select count(*) from public.push_subscriptions)::int, 1, 'mesmo aparelho não duplica');
select t.eq((select p256dh from public.push_subscriptions), 'chave2', 'inscrição atualizada');
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
select t.fails($$select * from public.push_subscriptions$$, 'nem o dono lê inscrições');

\echo '-- serviço com senhas não é excluído; unidade apaga tudo'
select t.fails(format($$delete from public.services where id = %L$$, :'svc_a'), 'serviço com senhas');
update public.services set active = false where id = :'svc_b';
reset role;
set role anon;
select t.as_user('');
select t.eq(jsonb_array_length((public.panel_state(:'tok_a2'))->'services'), 2, 'inativo some do totem');
reset role;
set role authenticated;
select t.as_user('00000000-0000-0000-0000-00000000000a');
delete from public.units;
reset role;
select t.eq((select count(*) from public.tickets where unit_id not in (select id from public.units))::int, 0, 'senhas apagadas com a unidade');
select t.eq((select count(*) from public.ticket_events)::int, 0, 'histórico apagado com a unidade');
select t.eq((select count(*) from public.push_subscriptions)::int, 0, 'inscrições apagadas com a unidade');
select t.eq((select count(*) from public.counters)::int, 2, 'só os guichês de B');
select t.eq((select count(*) from public.units)::int, 1, 'só a unidade de B');

\echo '-- limpeza'
update public.units set last_activity_at = now() - interval '31 days';
select public.cleanup_demo();
select t.eq((select count(*) from public.units)::int, 0, 'unidade inativa removida');
select t.eq((select count(*) from auth.users)::int, 2, 'anônimo antigo sem unidade removido');
