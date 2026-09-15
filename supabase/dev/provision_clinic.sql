-- ============================================================================
-- Provision a new clinic tenant.
--
-- NOT a migration: it lives outside supabase/migrations so `supabase db push`
-- never runs it. Run it once per new client, as the service role / SQL editor.
--
-- Before running:
--   1. The clinic's first admin signs up in any of the apps (an account must
--      exist — SQL cannot create auth users without the Auth admin API).
--   2. Edit the constants in the DECLARE block below.
--
-- Run with:
--   supabase db query --linked "$(cat supabase/dev/provision_clinic.sql)"
--
-- Safe to re-run with the same slug: the clinic is updated, services are
-- upserted, and the admin membership is kept. The join code is NOT rotated on
-- a re-run; clear it in the table first if it needs replacing.
--
-- Everything after this (more staff, doctors, catalogue changes) is the clinic
-- admin's job through invite_staff and the admin app. See docs/onboarding.md.
-- ============================================================================

create temporary table provisioned (
  clinic_id uuid,
  name      text,
  slug      text,
  join_code text,
  admin     text
);

do $$
declare
  -- ── Edit these ────────────────────────────────────────────────────────────
  c_name        constant text := 'Example Dental Clinic';
  c_slug        constant text := 'example-dental-clinic';   -- lowercase, a-z 0-9 and dashes
  c_type        constant text := 'dental';                  -- a clinic_types.slug
  c_seed_color  constant text := '#1F8A70';                 -- '#RRGGBB', or null for the platform colour
  c_timezone    constant text := 'Asia/Manila';
  c_phone       constant text := null;
  c_address     constant text := null;
  c_admin_email constant text := 'owner@example.ph';        -- must already have signed up

  -- Only needed when c_type is a vertical the platform does not have yet.
  c_type_display_name constant text := 'Dental';
  c_type_icon_name    constant text := 'medical_services';  -- a Material icon name

  c_services constant jsonb := '[
    {"name": "Consultation",   "minutes": 30},
    {"name": "Teeth Cleaning", "minutes": 45},
    {"name": "Dental Filling", "minutes": 30}
  ]';
  -- ──────────────────────────────────────────────────────────────────────────

  v_clinic_id uuid;
  v_admin_id  uuid;
begin
  select id into v_admin_id
    from public.profiles
   where lower(email) = lower(c_admin_email);

  if v_admin_id is null then
    raise exception 'no account for %: have them sign up first, then re-run', c_admin_email;
  end if;

  insert into public.clinic_types (slug, display_name, icon_name)
  values (c_type, c_type_display_name, c_type_icon_name)
  on conflict (slug) do nothing;

  insert into public.clinics
    (type, name, slug, seed_color, timezone, contact_phone, address)
  values
    (c_type, c_name, c_slug, c_seed_color, c_timezone, c_phone, c_address)
  on conflict (slug) do update set
    type          = excluded.type,
    name          = excluded.name,
    seed_color    = excluded.seed_color,
    timezone      = excluded.timezone,
    contact_phone = excluded.contact_phone,
    address       = excluded.address
  returning id into v_clinic_id;

  insert into public.services (clinic_id, name, duration_minutes)
  select v_clinic_id, s ->> 'name', (s ->> 'minutes')::int
    from jsonb_array_elements(c_services) s
  on conflict (clinic_id, name) do update
    set duration_minutes = excluded.duration_minutes,
        is_active = true;

  insert into public.clinic_memberships (profile_id, clinic_id, role)
  values (v_admin_id, v_clinic_id, 'admin')
  on conflict (profile_id, clinic_id) do update set role = 'admin';

  insert into provisioned
  select c.id, c.name, c.slug, c.join_code, c_admin_email
    from public.clinics c
   where c.id = v_clinic_id;
end;
$$;

-- Hand the join code to the clinic: patients enter it in the patient app.
select * from provisioned;
