-- ============================================================================
-- DEV / DEMO ONLY — do not run against anything holding real data.
--
-- This is NOT a migration. It lives outside supabase/migrations on purpose, so
-- `supabase db push` never picks it up.
--
-- The seed creates clinical records, not accounts: patients and doctors are
-- charts and roster rows with no `auth.users` behind them. That is correct for
-- real life — a clinic registers a walk-in long before that person ever signs
-- up — but it means a freshly seeded project has nobody who can sign in, and
-- every app opens onto an empty list.
--
-- This script creates four accounts, one per app, and wires them to the seeded
-- records. It writes to auth.users directly rather than going through the
-- Admin API, which keeps the service_role secret out of this repo entirely.
--
-- All four share the password:  demo1234
--
--   juan@email.com       patient    → linked to Juan dela Cruz's chart
--   santos@clinic.ph     doctor     → linked to Dr Maria Santos (dental)
--   frontdesk@clinic.ph  assistant  → dental
--   admin@clinic.ph      admin      → all three clinics
--
-- Safe to re-run: existing accounts have their password reset to the one
-- above rather than being duplicated.
--
-- Run with:
--   supabase db query --linked "$(cat supabase/dev/create_demo_users.sql)"
-- ============================================================================

-- pgcrypto lives in the `extensions` schema on Supabase, not public.
create or replace function pg_temp.ensure_user(
  p_email text,
  p_password text,
  p_full_name text
)
returns uuid
language plpgsql
as $$
declare
  v_uid uuid;
begin
  select id into v_uid from auth.users where email = p_email;

  if v_uid is not null then
    update auth.users
       set encrypted_password =
             extensions.crypt(p_password, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           -- Repair path: see the note on the INSERT below.
           confirmation_token     = coalesce(confirmation_token, ''),
           recovery_token         = coalesce(recovery_token, ''),
           email_change_token_new = coalesce(email_change_token_new, ''),
           email_change           = coalesce(email_change, ''),
           updated_at = now()
     where id = v_uid;
    return v_uid;
  end if;

  v_uid := gen_random_uuid();

  -- confirmation_token, recovery_token, email_change_token_new and
  -- email_change have no column default, and GoTrue scans them into
  -- non-nullable Go strings. Leaving them NULL makes every sign-in fail with
  -- the famously unhelpful "Database error querying schema" — the row looks
  -- perfect in SQL and the auth service still refuses it. They must be ''.
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    raw_app_meta_data, raw_user_meta_data
  ) values (
    v_uid,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    p_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    '', '', '', '',
    jsonb_build_object('provider', 'email',
                       'providers', jsonb_build_array('email')),
    jsonb_build_object('full_name', p_full_name)
  );

  -- GoTrue will not authenticate an email user without a matching identity
  -- row; for the email provider, provider_id is the user's own id.
  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(),
    v_uid,
    v_uid::text,
    jsonb_build_object('sub', v_uid::text,
                       'email', p_email,
                       'email_verified', true),
    'email',
    now(), now(), now()
  );

  return v_uid;
end;
$$;

do $$
declare
  v_juan  uuid;
  v_doc   uuid;
  v_asst  uuid;
  v_admin uuid;
  c_dental constant uuid := '10000000-0000-0000-0000-000000000001';
  c_opto   constant uuid := '10000000-0000-0000-0000-000000000002';
  c_pedia  constant uuid := '10000000-0000-0000-0000-000000000003';
begin
  -- Creating the auth user fires handle_new_user, which inserts the profile.
  v_juan  := pg_temp.ensure_user('juan@email.com',      'demo1234', 'Juan dela Cruz');
  v_doc   := pg_temp.ensure_user('santos@clinic.ph',    'demo1234', 'Maria Santos');
  v_asst  := pg_temp.ensure_user('frontdesk@clinic.ph', 'demo1234', 'Front Desk');
  v_admin := pg_temp.ensure_user('admin@clinic.ph',     'demo1234', 'Clinic Admin');

  -- Every signup lands as 'patient'; promoting is a service-role action, which
  -- is what this connection is. Juan stays a patient.
  update public.profiles set role = 'doctor'    where id = v_doc;
  update public.profiles set role = 'assistant' where id = v_asst;
  update public.profiles set role = 'admin'     where id = v_admin;

  -- Link the accounts to their clinical records.
  update public.patients set profile_id = v_juan
   where id = '30000000-0000-0000-0000-000000000001';   -- Juan dela Cruz
  update public.doctors  set profile_id = v_doc
   where id = '20000000-0000-0000-0000-000000000001';   -- Dr Maria Santos

  -- Staff need a membership row; without one is_clinic_staff() is false and
  -- they see nothing at all.
  insert into public.clinic_memberships (profile_id, clinic_id) values
    (v_doc,   c_dental),
    (v_asst,  c_dental),
    (v_admin, c_dental),
    (v_admin, c_opto),
    (v_admin, c_pedia)
  on conflict do nothing;
end;
$$;

select p.role,
       u.email,
       p.full_name,
       (select count(*) from public.clinic_memberships m
         where m.profile_id = p.id) as clinics,
       (select count(*) from public.patients pt
         where pt.profile_id = p.id) as patient_chart,
       (select count(*) from public.doctors d
         where d.profile_id = p.id) as doctor_row
  from public.profiles p
  join auth.users u on u.id = p.id
 order by p.role;
