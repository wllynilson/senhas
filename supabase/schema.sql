-- =====================================================================
-- Senhas de Atendimento — banco de dados (Supabase)
--
-- Como aplicar: Supabase → SQL Editor → cole este arquivo → Run.
-- Pode ser executado mais de uma vez.
--
-- Modelo de demonstração: cada visitante entra com login anônimo do
-- Supabase e ganha a própria unidade (serviços, senhas e relatórios),
-- isolada das demais por RLS. Totem, painel e acompanhamento por QR code
-- funcionam sem login, por funções que recebem um token secreto.
-- =====================================================================

-- ---------- Tabelas ----------
create table if not exists public.units (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null unique default auth.uid() references auth.users (id) on delete cascade,
    name text not null default 'Unidade de demonstração'
        check (char_length(btrim(name)) between 1 and 60),
    timezone text not null default 'America/Sao_Paulo',
    -- Token dos dispositivos públicos (totem e painel). Quem tem o link pode
    -- emitir senhas e ver o painel, como no balcão físico.
    kiosk_token text not null unique default replace(gen_random_uuid()::text, '-', ''),
    created_at timestamptz not null default now(),
    last_activity_at timestamptz not null default now()
);

create table if not exists public.services (
    id uuid primary key default gen_random_uuid(),
    unit_id uuid not null references public.units (id) on delete cascade,
    name text not null check (char_length(btrim(name)) between 1 and 40),
    prefix text not null check (prefix ~ '^[A-Z]$'),
    active boolean not null default true,
    sort_order int not null default 0,
    created_at timestamptz not null default now(),
    unique (unit_id, prefix)
);
create index if not exists services_unit_idx on public.services (unit_id);

create table if not exists public.tickets (
    id uuid primary key default gen_random_uuid(),
    unit_id uuid not null references public.units (id) on delete cascade,
    -- sem cascade: serviço com senhas é desativado, não excluído
    service_id uuid not null references public.services (id),
    service_day date not null,
    number int not null check (number between 1 and 999),
    preferential boolean not null default false,
    code text not null,
    status text not null default 'waiting'
        check (status in ('waiting', 'called', 'done', 'no_show', 'cancelled')),
    counter text check (char_length(counter) <= 30),
    call_count int not null default 0,
    -- Código do QR code: dá acesso só ao andamento desta senha
    public_code text not null unique default replace(gen_random_uuid()::text, '-', ''),
    issued_at timestamptz not null default now(),
    called_at timestamptz,
    last_call_at timestamptz,
    finished_at timestamptz,
    unique (service_id, service_day, preferential, number)
);
create index if not exists tickets_queue_idx on public.tickets (unit_id, service_day, status, preferential desc, issued_at);
create index if not exists tickets_calls_idx on public.tickets (unit_id, last_call_at desc);

-- ---------- Segurança (RLS) ----------
alter table public.units enable row level security;
alter table public.services enable row level security;
alter table public.tickets enable row level security;

revoke all on public.units, public.services, public.tickets from anon;
revoke insert, update, delete on public.units, public.tickets from authenticated;
grant select, delete on public.units to authenticated;
grant update (name) on public.units to authenticated;
grant select on public.tickets to authenticated;
grant select, insert, update, delete on public.services to authenticated;

drop policy if exists units_owner_select on public.units;
create policy units_owner_select on public.units for select to authenticated
    using (owner_id = (select auth.uid()));
drop policy if exists units_owner_update on public.units;
create policy units_owner_update on public.units for update to authenticated
    using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
drop policy if exists units_owner_delete on public.units;
create policy units_owner_delete on public.units for delete to authenticated
    using (owner_id = (select auth.uid()));

drop policy if exists services_owner_all on public.services;
create policy services_owner_all on public.services for all to authenticated
    using (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())))
    with check (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())));

drop policy if exists tickets_owner_select on public.tickets;
create policy tickets_owner_select on public.tickets for select to authenticated
    using (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())));

-- ---------- Funções auxiliares ----------
create or replace function public.my_unit()
returns public.units
language sql stable security definer set search_path = ''
as $$
    select * from public.units where owner_id = auth.uid();
$$;

create or replace function public.unit_today(tz text)
returns date
language sql stable set search_path = ''
as $$
    select (now() at time zone tz)::date;
$$;

-- Quantas senhas do mesmo serviço serão chamadas antes desta
-- (preferenciais primeiro, depois ordem de emissão).
create or replace function public.tickets_ahead(p_ticket uuid)
returns int
language sql stable security definer set search_path = ''
as $$
    select count(*)::int
      from public.tickets t
      join public.tickets me on me.id = p_ticket
     where me.status = 'waiting'
       and t.status = 'waiting'
       and t.service_id = me.service_id
       and t.service_day = me.service_day
       and t.id <> me.id
       and (t.preferential and not me.preferential
            or (t.preferential = me.preferential and (t.issued_at, t.id) < (me.issued_at, me.id)));
$$;

-- ---------- Unidade de demonstração ----------
create or replace function public.create_demo_unit(p_name text default null)
returns public.units
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units;
begin
    if auth.uid() is null then
        raise exception 'Faça login primeiro' using errcode = '28000';
    end if;
    select * into u from public.units where owner_id = auth.uid();
    if found then
        return u;
    end if;
    insert into public.units (owner_id, name)
    values (auth.uid(), coalesce(nullif(btrim(p_name), ''), 'Unidade de demonstração'))
    returning * into u;
    insert into public.services (unit_id, name, prefix, sort_order) values
        (u.id, 'Atendimento geral', 'A', 1),
        (u.id, 'Protocolo', 'B', 2),
        (u.id, 'Financeiro', 'C', 3);
    return u;
end;
$$;

-- ---------- Totem: emitir senha (sem login, com token) ----------
create or replace function public.issue_ticket(p_token text, p_service uuid, p_preferential boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units;
    s public.services;
    d date;
    n int;
    pref boolean := coalesce(p_preferential, false);
    t public.tickets;
begin
    select * into u from public.units where kiosk_token = p_token;
    if not found then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    -- trava o serviço: numeração sem duplicar entre totens simultâneos
    select * into s from public.services where id = p_service and unit_id = u.id and active for update;
    if not found then
        raise exception 'Serviço indisponível' using errcode = 'P0002';
    end if;
    if (select count(*) from public.tickets where unit_id = u.id and issued_at > now() - interval '1 minute') >= 30 then
        raise exception 'Muitas senhas em pouco tempo. Aguarde um instante.' using errcode = 'P0001';
    end if;

    d := public.unit_today(u.timezone);
    select coalesce(max(number), 0) + 1 into n
      from public.tickets
     where service_id = s.id and service_day = d and preferential = pref;
    if n > 999 then
        raise exception 'Limite diário de senhas deste serviço atingido' using errcode = 'P0001';
    end if;

    insert into public.tickets (unit_id, service_id, service_day, number, preferential, code)
    values (u.id, s.id, d, n, pref, s.prefix || case when pref then 'P' else '' end || lpad(n::text, 3, '0'))
    returning * into t;
    update public.units set last_activity_at = now() where id = u.id;

    return jsonb_build_object(
        'code', t.code,
        'public_code', t.public_code,
        'preferential', t.preferential,
        'service', s.name,
        'unit', u.name,
        'issued_at', t.issued_at,
        'ahead', public.tickets_ahead(t.id)
    );
end;
$$;

-- ---------- Painel e totem: estado público da unidade ----------
create or replace function public.panel_state(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
    u public.units;
    d date;
begin
    select * into u from public.units where kiosk_token = p_token;
    if not found then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    d := public.unit_today(u.timezone);
    return jsonb_build_object(
        'unit', u.name,
        'server_time', now(),
        'services', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'id', s.id, 'name', s.name, 'prefix', s.prefix,
                       'waiting', (select count(*) from public.tickets t
                                    where t.service_id = s.id and t.service_day = d and t.status = 'waiting')
                   ) order by s.sort_order, s.prefix), '[]'::jsonb)
              from public.services s
             where s.unit_id = u.id and s.active
        ),
        'calls', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.last_call_at desc), '[]'::jsonb)
              from (
                select t.id, t.code, t.counter, t.call_count, t.last_call_at, t.preferential, s.name as service
                  from public.tickets t
                  join public.services s on s.id = t.service_id
                 where t.unit_id = u.id and t.service_day = d and t.last_call_at is not null
                 order by t.last_call_at desc
                 limit 6
              ) x
        )
    );
end;
$$;

-- ---------- QR code: andamento de uma senha ----------
create or replace function public.ticket_status(p_code text)
returns jsonb
language sql stable security definer set search_path = ''
as $$
    select jsonb_build_object(
        'code', t.code,
        'service', s.name,
        'unit', u.name,
        'status', t.status,
        'counter', t.counter,
        'preferential', t.preferential,
        'issued_at', t.issued_at,
        'last_call_at', t.last_call_at,
        'call_count', t.call_count,
        'ahead', public.tickets_ahead(t.id),
        'server_time', now()
    )
      from public.tickets t
      join public.services s on s.id = t.service_id
      join public.units u on u.id = t.unit_id
     where t.public_code = p_code;
$$;

-- ---------- Guichê (dono da unidade) ----------
-- Finaliza a senha em atendimento neste guichê e chama a próxima.
-- Preferenciais primeiro; "skip locked" evita dois guichês com a mesma senha.
create or replace function public.call_next(p_counter text, p_services uuid[] default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    c text := btrim(coalesce(p_counter, ''));
    t public.tickets;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    if c = '' or char_length(c) > 30 then
        raise exception 'Informe o nome do guichê' using errcode = '22023';
    end if;

    update public.tickets
       set status = 'done', finished_at = now()
     where unit_id = u.id and counter = c and status = 'called';

    select * into t
      from public.tickets
     where unit_id = u.id
       and service_day = public.unit_today(u.timezone)
       and status = 'waiting'
       and (p_services is null or cardinality(p_services) = 0 or service_id = any (p_services))
     order by preferential desc, issued_at, id
     limit 1
       for update skip locked;
    if not found then
        return null;
    end if;

    update public.tickets
       set status = 'called', counter = c, called_at = now(), last_call_at = now(), call_count = 1
     where id = t.id
    returning * into t;
    update public.units set last_activity_at = now() where id = u.id;
    return to_jsonb(t) || jsonb_build_object('service', (select name from public.services where id = t.service_id));
end;
$$;

create or replace function public.recall_ticket(p_ticket uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
    update public.tickets t
       set call_count = t.call_count + 1, last_call_at = now()
     where t.id = p_ticket and t.status = 'called'
       and t.unit_id = (select id from public.my_unit());
    if not found then
        raise exception 'Senha não está em chamada' using errcode = 'P0002';
    end if;
end;
$$;

-- done/no_show: senha chamada; cancelled: senha aguardando ou chamada
create or replace function public.finish_ticket(p_ticket uuid, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
    if p_status not in ('done', 'no_show', 'cancelled') then
        raise exception 'Status inválido' using errcode = '22023';
    end if;
    update public.tickets t
       set status = p_status, finished_at = now()
     where t.id = p_ticket
       and t.unit_id = (select id from public.my_unit())
       and (t.status = 'called' or (p_status = 'cancelled' and t.status = 'waiting'));
    if not found then
        raise exception 'Senha não pode ser alterada' using errcode = 'P0002';
    end if;
end;
$$;

-- Apaga as senhas de hoje (recomeça a numeração)
create or replace function public.reset_today()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    n int;
begin
    delete from public.tickets where unit_id = u.id and service_day = public.unit_today(u.timezone);
    get diagnostics n = row_count;
    return n;
end;
$$;

-- ---------- Histórico de exemplo para os relatórios ----------
-- Gera movimento fictício nos dias anteriores (segunda a sábado),
-- com picos às 10h e às 14h30.
create or replace function public.seed_demo_history(p_days int default 14)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    today date;
    n int;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    today := public.unit_today(u.timezone);
    if exists (select 1 from public.tickets where unit_id = u.id and service_day < today) then
        raise exception 'A unidade já tem histórico' using errcode = 'P0001';
    end if;
    p_days := least(greatest(coalesce(p_days, 14), 1), 30);

    with days as (
        select g::date as day
          from generate_series(today - p_days, today - 1, interval '1 day') g
         where extract(isodow from g) < 7
    ), svc as (
        select id, prefix, row_number() over (order by sort_order, prefix) as rn, count(*) over () as cnt
          from public.services
         where unit_id = u.id and active
    ), raw as (
        select days.day,
               random() as r_svc,
               random() < 0.25 as pref,
               random() < 0.06 as no_show,
               least(539, greatest(0,
                   (case when random() < 0.55 then 120 else 390 end)
                   + (random() + random() + random() - 1.5) * 120))::int as mins,
               (2 + power(random(), 2) * 30) * interval '1 minute' as wait,
               (3 + random() * 12) * interval '1 minute' as dur,
               1 + floor(random() * 3)::int as counter_no
          from days
         cross join lateral generate_series(1, 40 + floor(random() * 50)::int) gs
    ), j as (
        select raw.*, svc.id as service_id, svc.prefix,
               ((raw.day + time '08:00') + raw.mins * interval '1 minute'
                 + floor(random() * 60) * interval '1 second') at time zone u.timezone as issued_at
          from raw
          join svc on svc.rn = 1 + floor(raw.r_svc * svc.cnt)::int
    ), numbered as (
        select j.*, row_number() over (partition by service_id, day, pref order by issued_at)::int as num
          from j
    )
    insert into public.tickets (unit_id, service_id, service_day, number, preferential, code, status,
                                counter, call_count, issued_at, called_at, last_call_at, finished_at)
    select u.id, service_id, day, num, pref,
           prefix || case when pref then 'P' else '' end || lpad(num::text, 3, '0'),
           case when no_show then 'no_show' else 'done' end,
           'Guichê ' || counter_no, 1,
           issued_at, issued_at + wait, issued_at + wait,
           issued_at + wait + case when no_show then interval '3 minutes' else dur end
      from numbered
     where num <= 999;
    get diagnostics n = row_count;
    return n;
end;
$$;

-- ---------- Relatórios ----------
create or replace function public.report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    result jsonb;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
        raise exception 'Período inválido (máximo de 92 dias)' using errcode = '22023';
    end if;

    with t as (
        select t.*, s.name as service_name, s.prefix,
               extract(epoch from t.called_at - t.issued_at) as wait_s,
               case when t.status = 'done' then extract(epoch from t.finished_at - t.called_at) end as service_s
          from public.tickets t
          join public.services s on s.id = t.service_id
         where t.unit_id = u.id and t.service_day between p_from and p_to
    )
    select jsonb_build_object(
        'totals', (
            select jsonb_build_object(
                'issued', count(*),
                'done', count(*) filter (where status = 'done'),
                'no_show', count(*) filter (where status = 'no_show'),
                'cancelled', count(*) filter (where status = 'cancelled'),
                'open', count(*) filter (where status in ('waiting', 'called')),
                'preferential', count(*) filter (where preferential),
                'avg_wait', round(avg(wait_s)),
                'avg_service', round(avg(service_s))
            ) from t
        ),
        'by_day', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.day), '[]'::jsonb) from (
                select service_day as day, count(*) as issued,
                       count(*) filter (where status = 'done') as done,
                       round(avg(wait_s)) as avg_wait
                  from t group by service_day
            ) x
        ),
        'by_service', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.prefix), '[]'::jsonb) from (
                select service_name as name, prefix, count(*) as issued,
                       count(*) filter (where status = 'done') as done,
                       count(*) filter (where status = 'no_show') as no_show,
                       count(*) filter (where preferential) as preferential,
                       round(avg(wait_s)) as avg_wait,
                       round(avg(service_s)) as avg_service
                  from t group by service_name, prefix
            ) x
        ),
        'by_hour', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.hour), '[]'::jsonb) from (
                select extract(hour from issued_at at time zone u.timezone)::int as hour, count(*) as issued
                  from t group by 1
            ) x
        )
    ) into result;
    return result;
end;
$$;

-- ---------- Tempo real ----------
-- Avisa os dispositivos da unidade (canal "unit:<kiosk_token>") que algo
-- mudou; eles buscam o estado de novo pelas funções acima. A mensagem não
-- carrega dados. Falha no aviso nunca impede a operação.
create or replace function public.broadcast_unit_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
    tok text;
begin
    for tok in
        select u.kiosk_token from public.units u
         where u.id in (select r.unit_id from changed_rows r)
    loop
        begin
            perform realtime.send(jsonb_build_object('at', now()), 'changed', 'unit:' || tok, false);
        exception when others then
            raise warning 'broadcast_unit_change: %', sqlerrm;
        end;
    end loop;
    return null;
end;
$$;

drop trigger if exists tickets_bc_ins on public.tickets;
drop trigger if exists tickets_bc_upd on public.tickets;
drop trigger if exists tickets_bc_del on public.tickets;
create trigger tickets_bc_ins after insert on public.tickets
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger tickets_bc_upd after update on public.tickets
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger tickets_bc_del after delete on public.tickets
    referencing old table as changed_rows for each statement execute function public.broadcast_unit_change();

drop trigger if exists services_bc_ins on public.services;
drop trigger if exists services_bc_upd on public.services;
drop trigger if exists services_bc_del on public.services;
create trigger services_bc_ins after insert on public.services
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger services_bc_upd after update on public.services
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger services_bc_del after delete on public.services
    referencing old table as changed_rows for each statement execute function public.broadcast_unit_change();

-- ---------- Limpeza das demonstrações ----------
create or replace function public.cleanup_demo()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
    delete from public.units where last_activity_at < now() - interval '30 days';
    begin
        delete from auth.users au
         where au.is_anonymous
           and au.created_at < now() - interval '30 days'
           and not exists (select 1 from public.units x where x.owner_id = au.id);
    exception when others then
        raise warning 'cleanup_demo: %', sqlerrm;
    end;
end;
$$;

-- ---------- Permissões das funções ----------
-- Sem login (totem, painel, QR code):
revoke all on function public.issue_ticket(text, uuid, boolean) from public;
revoke all on function public.panel_state(text) from public;
revoke all on function public.ticket_status(text) from public;
grant execute on function public.issue_ticket(text, uuid, boolean) to anon, authenticated;
grant execute on function public.panel_state(text) to anon, authenticated;
grant execute on function public.ticket_status(text) to anon, authenticated;

-- Só o dono da unidade (logado):
revoke all on function public.create_demo_unit(text) from public, anon;
revoke all on function public.call_next(text, uuid[]) from public, anon;
revoke all on function public.recall_ticket(uuid) from public, anon;
revoke all on function public.finish_ticket(uuid, text) from public, anon;
revoke all on function public.reset_today() from public, anon;
revoke all on function public.seed_demo_history(int) from public, anon;
revoke all on function public.report(date, date) from public, anon;
grant execute on function public.create_demo_unit(text) to authenticated;
grant execute on function public.call_next(text, uuid[]) to authenticated;
grant execute on function public.recall_ticket(uuid) to authenticated;
grant execute on function public.finish_ticket(uuid, text) to authenticated;
grant execute on function public.reset_today() to authenticated;
grant execute on function public.seed_demo_history(int) to authenticated;
grant execute on function public.report(date, date) to authenticated;

-- Internas:
revoke all on function public.my_unit() from public, anon, authenticated;
revoke all on function public.tickets_ahead(uuid) from public, anon, authenticated;
revoke all on function public.broadcast_unit_change() from public, anon, authenticated;
revoke all on function public.cleanup_demo() from public, anon, authenticated;

-- @cron (tudo abaixo depende do pg_cron do Supabase)
create extension if not exists pg_cron with schema pg_catalog;
do $$
begin
    perform cron.unschedule(jobid) from cron.job where jobname = 'senhas-cleanup';
end;
$$;
select cron.schedule('senhas-cleanup', '30 6 * * *', 'select public.cleanup_demo()');
