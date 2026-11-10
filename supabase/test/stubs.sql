-- Imitações mínimas do Supabase para testes locais.
do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema auth;
create table auth.users (
    id uuid primary key,
    is_anonymous boolean not null default true,
    created_at timestamptz not null default now()
);
create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;

create schema realtime;
create table realtime.log (topic text, event text, private boolean);
create function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void language sql as $$ insert into realtime.log values (topic, event, private) $$;

-- Como no Supabase: anon/authenticated recebem tudo por padrão em public
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

insert into auth.users (id, created_at) values
    ('00000000-0000-0000-0000-00000000000a', now()),
    ('00000000-0000-0000-0000-00000000000b', now()),
    ('00000000-0000-0000-0000-00000000000c', now() - interval '40 days');
