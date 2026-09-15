-- ============================================================================
-- health-platform · clinics become real tenants
--
-- The schema was built for exactly three clinics, one per vertical:
--
--   clinics.type  public.clinic_type  NOT NULL UNIQUE
--
-- That UNIQUE made a second dental clinic unrepresentable, and the 3-value enum
-- made a fourth vertical (derma, OB-GYN, …) a migration plus a client release.
-- D-Touch is one client among many now, and two of those clients may well be
-- competing dental practices.
--
-- This migration:
--   1. replaces the enum with a `clinic_types` lookup table, so a new vertical
--      is an INSERT;
--   2. drops the one-clinic-per-type constraint;
--   3. adds the per-tenant configuration the apps need to brand themselves at
--      runtime instead of at compile time (slug, logo, colour, join code).
--
-- The column stays named `type` so the PostgREST embeds the apps already use
-- (`clinic:clinics(type)`) keep resolving.
-- ============================================================================

-- ── Verticals as data ───────────────────────────────────────────────────────

create table public.clinic_types (
  slug         text primary key
               constraint clinic_types_slug_format
               check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  display_name text not null,
  -- A Material icon name. The apps map it to an IconData and fall back to a
  -- generic icon for names they do not know, so an unfamiliar vertical still
  -- renders without a client release.
  icon_name    text not null default 'medical_services',
  created_at   timestamptz not null default now()
);

insert into public.clinic_types (slug, display_name, icon_name) values
  ('dental',    'Dental',     'medical_services'),
  ('optometry', 'Eye Care',   'remove_red_eye'),
  ('pedia',     'Pediatrics', 'child_care')
on conflict (slug) do nothing;

alter table public.clinics drop constraint clinics_type_key;

alter table public.clinics
  alter column "type" type text using "type"::text;

drop type public.clinic_type;

alter table public.clinics
  add constraint clinics_type_fkey
    foreign key ("type") references public.clinic_types (slug)
    on update cascade;

-- Reference data, not tenant data: every signed-in user may read the list of
-- verticals. Writes are service-role only.
alter table public.clinic_types enable row level security;

create policy clinic_types_select_authenticated on public.clinic_types
  for select to authenticated using (true);

-- ── Join codes ──────────────────────────────────────────────────────────────
-- A patient attaches to a clinic by entering its code (see join_clinic in
-- 20260914120400). Eight characters from a 32-symbol alphabet with the
-- look-alikes removed (no 0/O, 1/I) gives ~10^12 codes.
--
-- The randomness comes from gen_random_uuid(), which is built in and
-- cryptographically random — pgcrypto's gen_random_bytes lives in `public`
-- locally but `extensions` on Supabase, and a function pinned to
-- search_path = '' cannot portably name either. Bytes 6 and 8 of a v4 UUID
-- carry fixed version/variant bits, so they are skipped. Every byte used is
-- reduced mod 32, and 256 is a multiple of 32, so there is no modulo bias.

create or replace function private.new_join_code()
returns text
language sql
volatile
set search_path = ''
as $$
  select string_agg(
           substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                  (get_byte(r.b, i.pos) % 32) + 1, 1),
           '' order by i.ord)
  from (select uuid_send(gen_random_uuid()) as b) r,
       unnest(array[0, 1, 2, 3, 4, 5, 9, 10]) with ordinality as i(pos, ord);
$$;

-- ── Tenant configuration ────────────────────────────────────────────────────

alter table public.clinics
  add column slug          text,
  -- Null means the clinic does not accept self-service joins.
  add column join_code     text default private.new_join_code(),
  -- Public URLs (Supabase Storage), or `asset:<path>` for artwork bundled in
  -- the apps' shared package. Null falls back to the vertical's icon.
  add column logo_url      text,
  add column wordmark_url  text,
  -- Seeds the Material colour scheme. Null falls back to the platform colour.
  add column seed_color    text,
  add column contact_phone text,
  add column address       text,
  add column is_active     boolean not null default true;

update public.clinics
   set slug = trim(both '-' from regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g'))
 where slug is null;

update public.clinics
   set join_code = private.new_join_code()
 where join_code is null;

alter table public.clinics
  alter column slug set not null,
  add constraint clinics_slug_key unique (slug),
  add constraint clinics_slug_format
    check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  add constraint clinics_join_code_key unique (join_code),
  add constraint clinics_join_code_format
    check (join_code ~ '^[A-Z0-9]{6,16}$'),
  add constraint clinics_seed_color_format
    check (seed_color ~ '^#[0-9A-Fa-f]{6}$');
