-- =====================================================================
-- Senhas de Atendimento — banco de dados (Supabase)
--
-- Como aplicar: Supabase → SQL Editor → cole este arquivo → Run.
-- Pode ser executado mais de uma vez; também atualiza um banco da v1.
--
-- Modelo de demonstração: cada visitante entra com login anônimo do
-- Supabase e ganha a própria unidade (serviços, guichês, senhas e
-- relatórios), isolada das demais por RLS. Totem, painel e acompanhamento
-- por QR code funcionam sem login, por funções que recebem um token.
-- =====================================================================

-- ---------- Tabelas ----------
create table if not exists public.units (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null unique default auth.uid() references auth.users (id) on delete cascade,
    name text not null default 'Unidade de demonstração'
        check (char_length(btrim(name)) between 1 and 60),
    timezone text not null default 'America/Sao_Paulo',
    -- Token do totem: quem tem o link pode emitir senhas, como no balcão físico.
    kiosk_token text not null unique default replace(gen_random_uuid()::text, '-', ''),
    -- Token do painel: só leitura. A TV fica exposta, então não emite senhas.
    display_token text not null unique default replace(gen_random_uuid()::text, '-', ''),
    -- Rechamadas antes de a senha virar "ausente" automaticamente.
    max_recalls smallint not null default 3 check (max_recalls between 1 and 10),
    -- Meta de espera usada nos relatórios (minutos).
    wait_target_minutes smallint not null default 15 check (wait_target_minutes between 1 and 240),
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

-- Guichês da unidade. service_ids vazio = atende todos os serviços.
-- priority_only atende ao §3º da Lei 14.626/2023 (guichê exclusivo).
create table if not exists public.counters (
    id uuid primary key default gen_random_uuid(),
    unit_id uuid not null references public.units (id) on delete cascade,
    name text not null check (char_length(btrim(name)) between 1 and 30),
    service_ids uuid[] not null default '{}',
    priority_only boolean not null default false,
    active boolean not null default true,
    sort_order int not null default 0,
    created_at timestamptz not null default now(),
    unique (unit_id, name)
);
create index if not exists counters_unit_idx on public.counters (unit_id);

-- priority: 0 normal · 1 doador de sangue · 2 prioritário (Lei 10.048/2000,
-- redação da Lei 14.626/2023) · 3 prioridade especial 80+ (Lei 10.741/2003).
-- O doador vem depois dos demais prioritários (Lei 10.048, art. 1º, §2º).
create table if not exists public.tickets (
    id uuid primary key default gen_random_uuid(),
    unit_id uuid not null references public.units (id) on delete cascade,
    -- sem cascade: serviço com senhas é desativado, não excluído
    service_id uuid not null references public.services (id),
    service_day date not null,
    number int not null check (number between 1 and 999),
    priority smallint not null default 0 check (priority between 0 and 3),
    code text not null,
    status text not null default 'waiting'
        constraint tickets_status_check
        check (status in ('waiting', 'called', 'done', 'no_show', 'cancelled', 'expired')),
    counter_id uuid references public.counters (id) on delete set null,
    -- nome do guichê no momento da chamada (o cadastro pode mudar depois)
    counter_name text check (char_length(counter_name) <= 30),
    call_count int not null default 0,
    -- Código do QR code: dá acesso só ao andamento desta senha
    public_code text not null unique default replace(gen_random_uuid()::text, '-', ''),
    issued_at timestamptz not null default now(),
    called_at timestamptz,
    last_call_at timestamptz,
    finished_at timestamptz,
    constraint tickets_number_key unique (service_id, service_day, priority, number)
);

create table if not exists public.ticket_events (
    id bigint generated always as identity primary key,
    ticket_id uuid not null references public.tickets (id) on delete cascade,
    unit_id uuid not null references public.units (id) on delete cascade,
    type text not null check (type in
        ('issued', 'called', 'recalled', 'transferred', 'done', 'no_show', 'cancelled', 'expired')),
    counter_id uuid references public.counters (id) on delete set null,
    at timestamptz not null default now(),
    data jsonb not null default '{}'::jsonb
);

-- Inscrições de Web Push de quem acompanha a senha pelo celular.
create table if not exists public.push_subscriptions (
    id uuid primary key default gen_random_uuid(),
    ticket_id uuid not null references public.tickets (id) on delete cascade,
    endpoint text not null unique,
    p256dh text not null,
    auth text not null,
    created_at timestamptz not null default now()
);

-- Configuração do envio de push (opcional). Preenchida uma vez, à mão:
--   insert into public.app_config (notify_url, notify_secret) values ('https://<ref>.supabase.co/functions/v1/notify', '<segredo>')
--   on conflict (id) do update set notify_url = excluded.notify_url, notify_secret = excluded.notify_secret;
create table if not exists public.app_config (
    id boolean primary key default true check (id),
    notify_url text,
    notify_secret text
);

-- ---------- Migração da versão 1 ----------
do $$
begin
    -- novas colunas da unidade
    alter table public.units add column if not exists display_token text
        not null default replace(gen_random_uuid()::text, '-', '');
    alter table public.units add column if not exists max_recalls smallint not null default 3;
    alter table public.units add column if not exists wait_target_minutes smallint not null default 15;
    if not exists (select 1 from pg_constraint where conname = 'units_display_token_key') then
        alter table public.units add constraint units_display_token_key unique (display_token);
    end if;

    -- preferential boolean → priority smallint
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'tickets' and column_name = 'preferential') then
        alter table public.tickets add column if not exists priority smallint not null default 0;
        update public.tickets set priority = 2 where preferential;
        alter table public.tickets drop constraint if exists tickets_service_id_service_day_preferential_number_key;
        alter table public.tickets drop column preferential;
        alter table public.tickets add constraint tickets_number_key
            unique (service_id, service_day, priority, number);
        alter table public.tickets add constraint tickets_priority_check check (priority between 0 and 3);
        drop index if exists public.tickets_queue_idx;
    end if;

    -- counter text → counter_id/counter_name (os guichês viram cadastro)
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'tickets' and column_name = 'counter') then
        alter table public.tickets add column if not exists counter_id uuid references public.counters (id) on delete set null;
        alter table public.tickets add column if not exists counter_name text;
        update public.tickets set counter_name = counter where counter is not null;
        insert into public.counters (unit_id, name)
            select distinct unit_id, counter from public.tickets where counter is not null
            on conflict (unit_id, name) do nothing;
        update public.tickets t set counter_id = c.id
          from public.counters c
         where c.unit_id = t.unit_id and c.name = t.counter_name and t.counter_id is null;
        alter table public.tickets drop column counter;
    end if;

    -- status "expired"
    alter table public.tickets drop constraint if exists tickets_status_check;
    alter table public.tickets add constraint tickets_status_check
        check (status in ('waiting', 'called', 'done', 'no_show', 'cancelled', 'expired'));

    -- unidades da v1 sem guichês cadastrados ganham dois padrão
    insert into public.counters (unit_id, name, sort_order)
    select u.id, v.name, v.ord
      from public.units u
      cross join (values ('Guichê 1', 1), ('Guichê 2', 2)) as v(name, ord)
     where not exists (select 1 from public.counters c where c.unit_id = u.id)
    on conflict (unit_id, name) do nothing;
end $$;

create index if not exists tickets_queue_idx
    on public.tickets (unit_id, service_day, status, priority desc, issued_at);
create index if not exists tickets_calls_idx on public.tickets (unit_id, last_call_at desc);
create index if not exists ticket_events_ticket_idx on public.ticket_events (ticket_id, at);
create index if not exists push_ticket_idx on public.push_subscriptions (ticket_id);

-- ---------- Segurança (RLS) ----------
alter table public.units enable row level security;
alter table public.services enable row level security;
alter table public.counters enable row level security;
alter table public.tickets enable row level security;
alter table public.ticket_events enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.app_config enable row level security;

revoke all on public.units, public.services, public.counters, public.tickets,
    public.ticket_events, public.push_subscriptions, public.app_config from anon;
revoke all on public.push_subscriptions, public.app_config from authenticated;
revoke insert, update, delete on public.units, public.tickets, public.ticket_events from authenticated;
grant select, delete on public.units to authenticated;
grant update (name, max_recalls, wait_target_minutes) on public.units to authenticated;
grant select on public.tickets, public.ticket_events to authenticated;
grant select, insert, update, delete on public.services, public.counters to authenticated;

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

drop policy if exists counters_owner_all on public.counters;
create policy counters_owner_all on public.counters for all to authenticated
    using (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())))
    with check (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())));

drop policy if exists tickets_owner_select on public.tickets;
create policy tickets_owner_select on public.tickets for select to authenticated
    using (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())));

drop policy if exists events_owner_select on public.ticket_events;
create policy events_owner_select on public.ticket_events for select to authenticated
    using (exists (select 1 from public.units u where u.id = unit_id and u.owner_id = (select auth.uid())));

-- ---------- Funções da versão 1 com outra assinatura ----------
drop function if exists public.issue_ticket(text, uuid, boolean);
drop function if exists public.call_next(text, uuid[]);
drop function if exists public.recall_ticket(uuid);
drop function if exists public.reset_today();

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

-- Letra extra do código por nível de prioridade: AP001, AE001, AD001.
create or replace function public.priority_suffix(p int)
returns text
language sql immutable set search_path = ''
as $$
    select case p when 3 then 'E' when 2 then 'P' when 1 then 'D' else '' end;
$$;

create or replace function public.log_event(p_ticket uuid, p_unit uuid, p_type text,
                                            p_counter uuid default null, p_data jsonb default '{}'::jsonb)
returns void
language sql security definer set search_path = ''
as $$
    insert into public.ticket_events (ticket_id, unit_id, type, counter_id, data)
    values (p_ticket, p_unit, p_type, p_counter, coalesce(p_data, '{}'::jsonb));
$$;

-- Quantas senhas serão chamadas antes desta. Segue a mesma ordem de
-- call_next: prioridade primeiro, depois a emissão — e considera os outros
-- serviços que os guichês desta senha também atendem.
create or replace function public.tickets_ahead(p_ticket uuid)
returns int
language sql stable security definer set search_path = ''
as $$
    with me as (
        select * from public.tickets where id = p_ticket
    ), mine as (
        select c.* from public.counters c, me
         where c.unit_id = me.unit_id and c.active
           and (cardinality(c.service_ids) = 0 or me.service_id = any (c.service_ids))
           and (not c.priority_only or me.priority > 0)
    )
    select count(*)::int
      from public.tickets t, me
     where me.status = 'waiting'
       and t.status = 'waiting'
       and t.unit_id = me.unit_id
       and t.service_day = me.service_day
       and t.id <> me.id
       and (t.priority > me.priority
            or (t.priority = me.priority and (t.issued_at, t.id) < (me.issued_at, me.id)))
       and (t.service_id = me.service_id
            or exists (select 1 from mine c
                        where (cardinality(c.service_ids) = 0 or t.service_id = any (c.service_ids))
                          and (not c.priority_only or t.priority > 0)));
$$;

-- Tempo médio de atendimento recente (segundos): últimas 20 senhas do
-- serviço, depois as da unidade, depois 5 minutos. Limitado para não
-- distorcer a estimativa com um atendimento esquecido aberto.
create or replace function public.recent_service_seconds(p_unit uuid, p_service uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
    select least(greatest(coalesce(
        (select avg(extract(epoch from finished_at - called_at))
           from (select called_at, finished_at from public.tickets
                  where unit_id = p_unit and service_id = p_service and status = 'done'
                    and called_at is not null and finished_at is not null
                  order by finished_at desc limit 20) a),
        (select avg(extract(epoch from finished_at - called_at))
           from (select called_at, finished_at from public.tickets
                  where unit_id = p_unit and status = 'done'
                    and called_at is not null and finished_at is not null
                  order by finished_at desc limit 20) b),
        300), 60), 3600);
$$;

-- Guichês que chamaram alguém nos últimos 15 minutos (mínimo de 1).
create or replace function public.active_counter_count(p_unit uuid)
returns int
language sql stable security definer set search_path = ''
as $$
    select greatest(1, (
        select count(distinct counter_id)::int from public.tickets
         where unit_id = p_unit and counter_id is not null
           and last_call_at > now() - interval '15 minutes'));
$$;

-- Espera estimada em minutos: pessoas na frente × tempo médio ÷ guichês ativos.
create or replace function public.wait_estimate(p_unit uuid, p_service uuid, p_ahead int)
returns int
language sql stable security definer set search_path = ''
as $$
    select ceil(greatest(p_ahead, 0) * public.recent_service_seconds(p_unit, p_service)
                / public.active_counter_count(p_unit) / 60)::int;
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
    insert into public.counters (unit_id, name, sort_order) values
        (u.id, 'Guichê 1', 1),
        (u.id, 'Guichê 2', 2);
    return u;
end;
$$;

-- Troca os links públicos (totem e painel) por outros.
create or replace function public.rotate_tokens()
returns public.units
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units;
begin
    update public.units
       set kiosk_token = replace(gen_random_uuid()::text, '-', ''),
           display_token = replace(gen_random_uuid()::text, '-', '')
     where owner_id = auth.uid()
    returning * into u;
    if not found then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    return u;
end;
$$;

-- ---------- Totem: emitir senha (sem login, com o token do totem) ----------
create or replace function public.issue_ticket(p_token text, p_service uuid, p_priority int default 0)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units;
    s public.services;
    d date;
    n int;
    prio int := coalesce(p_priority, 0);
    t public.tickets;
    ahead int;
begin
    if prio not between 0 and 3 then
        raise exception 'Prioridade inválida' using errcode = '22023';
    end if;
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
     where service_id = s.id and service_day = d and priority = prio;
    if n > 999 then
        raise exception 'Limite diário de senhas deste serviço atingido' using errcode = 'P0001';
    end if;

    insert into public.tickets (unit_id, service_id, service_day, number, priority, code)
    values (u.id, s.id, d, n, prio, s.prefix || public.priority_suffix(prio) || lpad(n::text, 3, '0'))
    returning * into t;
    perform public.log_event(t.id, u.id, 'issued');
    update public.units set last_activity_at = now() where id = u.id;

    ahead := public.tickets_ahead(t.id);
    return jsonb_build_object(
        'code', t.code,
        'public_code', t.public_code,
        'priority', t.priority,
        'service', s.name,
        'unit', u.name,
        'issued_at', t.issued_at,
        'ahead', ahead,
        'eta', public.wait_estimate(u.id, s.id, ahead)
    );
end;
$$;

-- ---------- Painel e totem: estado público da unidade ----------
-- Aceita o token do totem ou o do painel (este último só lê).
create or replace function public.panel_state(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
    u public.units;
    d date;
begin
    select * into u from public.units where kiosk_token = p_token or display_token = p_token;
    if not found then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    d := public.unit_today(u.timezone);
    return jsonb_build_object(
        'unit', u.name,
        'server_time', now(),
        'can_issue', u.kiosk_token = p_token,
        'services', (
            select coalesce(jsonb_agg(x order by x.sort_order, x.prefix), '[]'::jsonb)
              from (
                select s.id, s.name, s.prefix, s.sort_order,
                       w.waiting,
                       public.wait_estimate(u.id, s.id, w.waiting) as eta
                  from public.services s
                  cross join lateral (
                      select count(*)::int as waiting from public.tickets t
                       where t.service_id = s.id and t.service_day = d and t.status = 'waiting'
                  ) w
                 where s.unit_id = u.id and s.active
              ) x
        ),
        'calls', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.last_call_at desc), '[]'::jsonb)
              from (
                select t.id, t.code, t.counter_name as counter, t.call_count, t.last_call_at,
                       t.priority, s.name as service
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
        'counter', t.counter_name,
        'priority', t.priority,
        'issued_at', t.issued_at,
        'last_call_at', t.last_call_at,
        'call_count', t.call_count,
        'ahead', public.tickets_ahead(t.id),
        'eta', public.wait_estimate(t.unit_id, t.service_id, public.tickets_ahead(t.id)),
        'server_time', now()
    )
      from public.tickets t
      join public.services s on s.id = t.service_id
      join public.units u on u.id = t.unit_id
     where t.public_code = p_code;
$$;

-- Inscrição de Web Push do celular que acompanha a senha.
create or replace function public.subscribe_push(p_code text, p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
    tk public.tickets;
begin
    select * into tk from public.tickets where public_code = p_code;
    if not found then
        raise exception 'Senha não encontrada' using errcode = 'P0002';
    end if;
    if tk.status not in ('waiting', 'called') then
        raise exception 'Senha encerrada' using errcode = 'P0001';
    end if;
    if p_endpoint is null or char_length(p_endpoint) not between 10 and 1000
       or p_p256dh is null or p_auth is null then
        raise exception 'Inscrição inválida' using errcode = '22023';
    end if;
    if (select count(*) from public.push_subscriptions where ticket_id = tk.id) >= 3 then
        raise exception 'Muitas inscrições para esta senha' using errcode = 'P0001';
    end if;
    insert into public.push_subscriptions (ticket_id, endpoint, p256dh, auth)
    values (tk.id, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint) do update
        set ticket_id = excluded.ticket_id, p256dh = excluded.p256dh,
            auth = excluded.auth, created_at = now();
end;
$$;

-- ---------- Guichê (dono da unidade) ----------
-- Finaliza a senha em atendimento neste guichê e chama a próxima.
-- Prioridade primeiro; "skip locked" evita dois guichês com a mesma senha.
create or replace function public.call_next(p_counter uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    c public.counters;
    t public.tickets;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    select * into c from public.counters where id = p_counter and unit_id = u.id and active;
    if not found then
        raise exception 'Guichê não encontrado' using errcode = 'P0002';
    end if;

    update public.tickets
       set status = 'done', finished_at = now()
     where unit_id = u.id and counter_id = c.id and status = 'called';

    select * into t
      from public.tickets
     where unit_id = u.id
       and service_day = public.unit_today(u.timezone)
       and status = 'waiting'
       and (cardinality(c.service_ids) = 0 or service_id = any (c.service_ids))
       and (not c.priority_only or priority > 0)
     order by priority desc, issued_at, id
     limit 1
       for update skip locked;
    if not found then
        return null;
    end if;

    update public.tickets
       set status = 'called', counter_id = c.id, counter_name = c.name,
           called_at = now(), last_call_at = now(), call_count = 1
     where id = t.id
    returning * into t;
    perform public.log_event(t.id, u.id, 'called', c.id);
    update public.units set last_activity_at = now() where id = u.id;
    return to_jsonb(t) || jsonb_build_object(
        'service', (select name from public.services where id = t.service_id));
end;
$$;

-- Rechama. Passado o limite de rechamadas da unidade, encerra como ausente.
create or replace function public.recall_ticket(p_ticket uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    t public.tickets;
begin
    select * into t from public.tickets
     where id = p_ticket and unit_id = u.id and status = 'called' for update;
    if not found then
        raise exception 'Senha não está em chamada' using errcode = 'P0002';
    end if;

    if t.call_count > u.max_recalls then
        update public.tickets set status = 'no_show', finished_at = now()
         where id = t.id returning * into t;
        perform public.log_event(t.id, u.id, 'no_show', t.counter_id, jsonb_build_object('auto', true));
        return jsonb_build_object('status', t.status, 'code', t.code, 'call_count', t.call_count);
    end if;

    update public.tickets set call_count = call_count + 1, last_call_at = now()
     where id = t.id returning * into t;
    perform public.log_event(t.id, u.id, 'recalled', t.counter_id,
                             jsonb_build_object('call_count', t.call_count));
    return jsonb_build_object('status', t.status, 'code', t.code, 'call_count', t.call_count);
end;
$$;

-- done/no_show: senha chamada; cancelled: senha aguardando ou chamada
create or replace function public.finish_ticket(p_ticket uuid, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    tk public.tickets;
begin
    if p_status not in ('done', 'no_show', 'cancelled') then
        raise exception 'Status inválido' using errcode = '22023';
    end if;
    update public.tickets
       set status = p_status, finished_at = now()
     where id = p_ticket
       and unit_id = u.id
       and (status = 'called' or (p_status = 'cancelled' and status = 'waiting'))
    returning * into tk;
    if not found then
        raise exception 'Senha não pode ser alterada' using errcode = 'P0002';
    end if;
    perform public.log_event(tk.id, u.id, p_status, tk.counter_id);
end;
$$;

-- Manda a senha para outro serviço. O código mostrado continua o mesmo;
-- só o número interno muda, para não colidir com a numeração do destino.
create or replace function public.transfer_ticket(p_ticket uuid, p_service uuid,
                                                  p_keep_position boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    t public.tickets;
    s public.services;
    n int;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    select * into s from public.services where id = p_service and unit_id = u.id and active for update;
    if not found then
        raise exception 'Serviço indisponível' using errcode = 'P0002';
    end if;
    select * into t from public.tickets
     where id = p_ticket and unit_id = u.id and status in ('waiting', 'called') for update;
    if not found then
        raise exception 'Senha não pode ser transferida' using errcode = 'P0002';
    end if;
    if t.service_id = s.id then
        raise exception 'A senha já está neste serviço' using errcode = '22023';
    end if;

    select coalesce(max(number), 0) + 1 into n
      from public.tickets
     where service_id = s.id and service_day = t.service_day and priority = t.priority;
    if n > 999 then
        raise exception 'Limite diário de senhas deste serviço atingido' using errcode = 'P0001';
    end if;

    update public.tickets
       set service_id = s.id,
           number = n,
           status = 'waiting',
           counter_id = null,
           called_at = null,
           call_count = 0,
           issued_at = case when coalesce(p_keep_position, true) then issued_at else now() end
     where id = t.id
    returning * into t;
    perform public.log_event(t.id, u.id, 'transferred', null,
        jsonb_build_object('to', s.name, 'keep_position', coalesce(p_keep_position, true)));
    update public.units set last_activity_at = now() where id = u.id;
    return jsonb_build_object('code', t.code, 'service', s.name, 'ahead', public.tickets_ahead(t.id));
end;
$$;

-- Encerra as senhas de hoje. Por padrão cancela (preserva o histórico);
-- com p_delete apaga mesmo, recomeçando a numeração (modo demonstração).
create or replace function public.reset_today(p_delete boolean default false)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
    u public.units := public.my_unit();
    d date;
    n int;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    d := public.unit_today(u.timezone);
    if coalesce(p_delete, false) then
        delete from public.tickets where unit_id = u.id and service_day = d;
        get diagnostics n = row_count;
        return n;
    end if;
    with x as (
        update public.tickets set status = 'cancelled', finished_at = now()
         where unit_id = u.id and service_day = d and status in ('waiting', 'called')
        returning id
    )
    insert into public.ticket_events (ticket_id, unit_id, type, data)
    select id, u.id, 'cancelled', jsonb_build_object('reset', true) from x;
    get diagnostics n = row_count;
    return n;
end;
$$;

-- Senhas de dias anteriores que ficaram abertas (rodado pelo pg_cron).
create or replace function public.expire_stale_tickets()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
    n int;
begin
    with x as (
        update public.tickets t set status = 'expired', finished_at = now()
          from public.units u
         where u.id = t.unit_id
           and t.status in ('waiting', 'called')
           and t.service_day < public.unit_today(u.timezone)
        returning t.id, t.unit_id
    )
    insert into public.ticket_events (ticket_id, unit_id, type)
    select id, unit_id, 'expired' from x;
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
    ), cnt as (
        select id, name, row_number() over (order by sort_order, name) as rn, count(*) over () as num
          from public.counters
         where unit_id = u.id and active
    ), raw as (
        select days.day,
               random() as r_svc,
               random() as r_cnt,
               -- 25% prioritários: a maioria pela Lei 10.048, alguns 80+ e doadores
               case when random() < 0.25
                    then (case when random() < 0.15 then 3 when random() < 0.1 then 1 else 2 end)
                    else 0 end as prio,
               random() < 0.06 as no_show,
               least(539, greatest(0,
                   (case when random() < 0.55 then 120 else 390 end)
                   + (random() + random() + random() - 1.5) * 120))::int as mins,
               (2 + power(random(), 2) * 30) * interval '1 minute' as wait,
               (3 + random() * 12) * interval '1 minute' as dur
          from days
         -- quantidade sorteada por dia (a referência a days.day obriga o
         -- sorteio a cada linha); segunda mais cheia, sábado mais vazio
         cross join lateral generate_series(1, ((45 + random() * 35)
             * case extract(isodow from days.day) when 1 then 1.3 when 5 then 0.9 when 6 then 0.5 else 1 end)::int) gs
    ), j as (
        select raw.*, svc.id as service_id, svc.prefix, cnt.id as counter_id, cnt.name as counter_name,
               ((raw.day + time '08:00') + raw.mins * interval '1 minute'
                 + floor(random() * 60) * interval '1 second') at time zone u.timezone as issued_at
          from raw
          join svc on svc.rn = 1 + floor(raw.r_svc * svc.cnt)::int
          left join cnt on cnt.rn = 1 + floor(raw.r_cnt * cnt.num)::int
    ), numbered as (
        select j.*, row_number() over (partition by service_id, day, prio order by issued_at)::int as num
          from j
    )
    insert into public.tickets (unit_id, service_id, service_day, number, priority, code, status,
                                counter_id, counter_name, call_count, issued_at, called_at, last_call_at, finished_at)
    select u.id, service_id, day, num, prio,
           prefix || public.priority_suffix(prio) || lpad(num::text, 3, '0'),
           case when no_show then 'no_show' else 'done' end,
           counter_id, coalesce(counter_name, 'Guichê 1'), 1,
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
    target int;
    result jsonb;
begin
    if u.id is null then
        raise exception 'Unidade não encontrada' using errcode = 'P0002';
    end if;
    if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
        raise exception 'Período inválido (máximo de 92 dias)' using errcode = '22023';
    end if;
    target := u.wait_target_minutes * 60;

    with t as (
        select t.*, s.name as service_name, s.prefix,
               extract(epoch from t.called_at - t.issued_at) as wait_s,
               case when t.status = 'done' then extract(epoch from t.finished_at - t.called_at) end as service_s
          from public.tickets t
          join public.services s on s.id = t.service_id
         where t.unit_id = u.id and t.service_day between p_from and p_to
    )
    select jsonb_build_object(
        'wait_target', u.wait_target_minutes,
        'totals', (
            select jsonb_build_object(
                'issued', count(*),
                'done', count(*) filter (where status = 'done'),
                'no_show', count(*) filter (where status = 'no_show'),
                'cancelled', count(*) filter (where status = 'cancelled'),
                'expired', count(*) filter (where status = 'expired'),
                'open', count(*) filter (where status in ('waiting', 'called')),
                'priority', count(*) filter (where priority > 0),
                'avg_wait', round(avg(wait_s)),
                'p50_wait', round(percentile_cont(0.5) within group (order by wait_s)),
                'p90_wait', round(percentile_cont(0.9) within group (order by wait_s)),
                'avg_service', round(avg(service_s)),
                'within_target', count(*) filter (where wait_s is not null and wait_s <= target),
                'measured', count(*) filter (where wait_s is not null)
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
                       count(*) filter (where priority > 0) as priority,
                       round(avg(wait_s)) as avg_wait,
                       round(percentile_cont(0.9) within group (order by wait_s)) as p90_wait,
                       round(avg(service_s)) as avg_service
                  from t group by service_name, prefix
            ) x
        ),
        'by_counter', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) from (
                select counter_name as name,
                       count(*) filter (where status in ('done', 'no_show')) as served,
                       count(*) filter (where status = 'no_show') as no_show,
                       round(avg(service_s)) as avg_service
                  from t where counter_name is not null group by counter_name
            ) x
        ),
        'by_hour', (
            select coalesce(jsonb_agg(to_jsonb(x) order by x.hour), '[]'::jsonb) from (
                select extract(hour from issued_at at time zone u.timezone)::int as hour,
                       count(*) as issued, round(avg(wait_s)) as avg_wait
                  from t group by 1
            ) x
        )
    ) into result;
    return result;
end;
$$;

-- ---------- Tempo real ----------
-- Avisa os dispositivos da unidade (canais "unit:<token do totem>" e
-- "unit:<token do painel>") que algo mudou; eles buscam o estado de novo
-- pelas funções acima. A mensagem não carrega dados. Para poucas senhas
-- de cada vez, avisa também o canal de cada senha ("ticket:<código>"),
-- usado pelo acompanhamento no celular. Falha no aviso nunca impede a operação.
create or replace function public.broadcast_unit_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
    tok text;
begin
    for tok in
        select t from public.units u, lateral (values (u.kiosk_token), (u.display_token)) v(t)
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

create or replace function public.broadcast_ticket_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
    tok text;
begin
    -- cargas grandes (histórico de exemplo) só usam o aviso da unidade
    if (select count(*) from changed_rows) > 20 then
        return null;
    end if;
    for tok in select r.public_code from changed_rows r loop
        begin
            perform realtime.send(jsonb_build_object('at', now()), 'changed', 'ticket:' || tok, false);
        exception when others then
            raise warning 'broadcast_ticket_change: %', sqlerrm;
        end;
    end loop;
    return null;
end;
$$;

-- Dispara o envio de Web Push quando a senha é chamada ou rechamada.
-- Só funciona depois de preencher public.app_config (veja o README).
create or replace function public.notify_ticket_called()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
    cfg public.app_config;
    ids uuid[];
begin
    select * into cfg from public.app_config where id;
    if not found or cfg.notify_url is null then
        return null;
    end if;
    select array_agg(r.id) into ids
      from changed_rows r
     where r.status = 'called'
       and exists (select 1 from public.push_subscriptions p where p.ticket_id = r.id);
    if ids is null then
        return null;
    end if;
    begin
        perform net.http_post(
            url := cfg.notify_url,
            headers := jsonb_build_object('Content-Type', 'application/json',
                                          'Authorization', 'Bearer ' || coalesce(cfg.notify_secret, '')),
            body := jsonb_build_object('tickets', to_jsonb(ids)));
    exception when others then
        raise warning 'notify_ticket_called: %', sqlerrm;
    end;
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

drop trigger if exists tickets_tc_ins on public.tickets;
drop trigger if exists tickets_tc_upd on public.tickets;
create trigger tickets_tc_ins after insert on public.tickets
    referencing new table as changed_rows for each statement execute function public.broadcast_ticket_change();
create trigger tickets_tc_upd after update on public.tickets
    referencing new table as changed_rows for each statement execute function public.broadcast_ticket_change();

drop trigger if exists tickets_push on public.tickets;
create trigger tickets_push after update on public.tickets
    referencing new table as changed_rows for each statement execute function public.notify_ticket_called();

drop trigger if exists services_bc_ins on public.services;
drop trigger if exists services_bc_upd on public.services;
drop trigger if exists services_bc_del on public.services;
create trigger services_bc_ins after insert on public.services
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger services_bc_upd after update on public.services
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger services_bc_del after delete on public.services
    referencing old table as changed_rows for each statement execute function public.broadcast_unit_change();

drop trigger if exists counters_bc_ins on public.counters;
drop trigger if exists counters_bc_upd on public.counters;
drop trigger if exists counters_bc_del on public.counters;
create trigger counters_bc_ins after insert on public.counters
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger counters_bc_upd after update on public.counters
    referencing new table as changed_rows for each statement execute function public.broadcast_unit_change();
create trigger counters_bc_del after delete on public.counters
    referencing old table as changed_rows for each statement execute function public.broadcast_unit_change();

-- ---------- Limpeza das demonstrações ----------
create or replace function public.cleanup_demo()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
    delete from public.units where last_activity_at < now() - interval '30 days';
    delete from public.push_subscriptions p
     where p.created_at < now() - interval '1 day'
        or not exists (select 1 from public.tickets t
                        where t.id = p.ticket_id and t.status in ('waiting', 'called'));
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
revoke all on function public.issue_ticket(text, uuid, int) from public;
revoke all on function public.panel_state(text) from public;
revoke all on function public.ticket_status(text) from public;
revoke all on function public.subscribe_push(text, text, text, text) from public;
grant execute on function public.issue_ticket(text, uuid, int) to anon, authenticated;
grant execute on function public.panel_state(text) to anon, authenticated;
grant execute on function public.ticket_status(text) to anon, authenticated;
grant execute on function public.subscribe_push(text, text, text, text) to anon, authenticated;

-- Só o dono da unidade (logado):
revoke all on function public.create_demo_unit(text) from public, anon;
revoke all on function public.rotate_tokens() from public, anon;
revoke all on function public.call_next(uuid) from public, anon;
revoke all on function public.recall_ticket(uuid) from public, anon;
revoke all on function public.finish_ticket(uuid, text) from public, anon;
revoke all on function public.transfer_ticket(uuid, uuid, boolean) from public, anon;
revoke all on function public.reset_today(boolean) from public, anon;
revoke all on function public.seed_demo_history(int) from public, anon;
revoke all on function public.report(date, date) from public, anon;
grant execute on function public.create_demo_unit(text) to authenticated;
grant execute on function public.rotate_tokens() to authenticated;
grant execute on function public.call_next(uuid) to authenticated;
grant execute on function public.recall_ticket(uuid) to authenticated;
grant execute on function public.finish_ticket(uuid, text) to authenticated;
grant execute on function public.transfer_ticket(uuid, uuid, boolean) to authenticated;
grant execute on function public.reset_today(boolean) to authenticated;
grant execute on function public.seed_demo_history(int) to authenticated;
grant execute on function public.report(date, date) to authenticated;

-- Internas:
revoke all on function public.my_unit() from public, anon, authenticated;
revoke all on function public.log_event(uuid, uuid, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.tickets_ahead(uuid) from public, anon, authenticated;
revoke all on function public.recent_service_seconds(uuid, uuid) from public, anon, authenticated;
revoke all on function public.active_counter_count(uuid) from public, anon, authenticated;
revoke all on function public.wait_estimate(uuid, uuid, int) from public, anon, authenticated;
revoke all on function public.expire_stale_tickets() from public, anon, authenticated;
revoke all on function public.broadcast_unit_change() from public, anon, authenticated;
revoke all on function public.broadcast_ticket_change() from public, anon, authenticated;
revoke all on function public.notify_ticket_called() from public, anon, authenticated;
revoke all on function public.cleanup_demo() from public, anon, authenticated;

-- @cron (tudo abaixo depende de extensões do Supabase)
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
do $$
begin
    perform cron.unschedule(jobid) from cron.job where jobname in ('senhas-cleanup', 'senhas-expire');
end;
$$;
select cron.schedule('senhas-cleanup', '30 6 * * *', 'select public.cleanup_demo()');
-- de hora em hora: cada unidade tem o próprio fuso
select cron.schedule('senhas-expire', '7 * * * *', 'select public.expire_stale_tickets()');
