-- Minimal stand-ins for the Supabase-managed bits, so the migrations can be
-- validated against a plain Postgres cluster. NOT part of the repo.

-- Roles are cluster-wide, so they survive a dropdb; create them only if absent.
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
end;
$$;

create schema if not exists auth;

create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb default '{}'::jsonb
);

-- Supabase derives these from request JWT claims; here they read a GUC we set
-- manually in tests.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.role', true), '');
$$;

grant usage on schema auth to authenticated, anon, service_role;
grant usage on schema public to authenticated, anon, service_role;
-- Supabase grants anon and authenticated blanket table privileges and relies
-- entirely on RLS to filter; mirror that so "anon sees nothing" is proved by
-- policy rather than by a missing GRANT.
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
