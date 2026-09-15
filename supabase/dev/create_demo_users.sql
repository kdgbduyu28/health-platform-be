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
-- This script creates five accounts and wires them to the seeded records. It
-- writes to auth.users directly rather than going through the Admin API, which
-- keeps the service_role secret out of this repo entirely.
--
-- All five share the password:  demo1234
--
--   juan@email.com        patient    → Juan dela Cruz (charts at 3 clinics)
--   santos@clinic.ph      doctor     → Dr Maria Santos, D-Touch
--   frontdesk@clinic.ph   assistant  → D-Touch
--   admin@clinic.ph       admin      → D-Touch, ClearVision, Little Stars
--   admin@brightsmile.ph  admin      → BrightSmile only (the isolation demo:
--                                      sign in as this and D-Touch is invisible)
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
  v_juan   uuid;
  v_doc    uuid;
  v_asst   uuid;
  v_admin  uuid;
  v_bright uuid;
  c_dental constant uuid := '10000000-0000-0000-0000-000000000001';
  c_opto   constant uuid := '10000000-0000-0000-0000-000000000002';
  c_pedia  constant uuid := '10000000-0000-0000-0000-000000000003';
  c_bright constant uuid := '10000000-0000-0000-0000-000000000004';
begin
  -- Creating the auth user fires handle_new_user, which inserts the profile.
  v_juan   := pg_temp.ensure_user('juan@email.com',       'demo1234', 'Juan dela Cruz');
  v_doc    := pg_temp.ensure_user('santos@clinic.ph',     'demo1234', 'Maria Santos');
  v_asst   := pg_temp.ensure_user('frontdesk@clinic.ph',  'demo1234', 'Front Desk');
  v_admin  := pg_temp.ensure_user('admin@clinic.ph',      'demo1234', 'Clinic Admin');
  v_bright := pg_temp.ensure_user('admin@brightsmile.ph', 'demo1234', 'BrightSmile Admin');

  -- A signup grants nothing. Patients get access through a chart (their person
  -- record, linked below); staff through a membership, which carries the role
  -- for that one clinic. Linking a person to an account is a service-role
  -- action, which is what this connection is.
  update public.persons set profile_id = v_juan
   where id = '50000000-0000-0000-0000-000000000001';   -- Juan dela Cruz
  update public.doctors set profile_id = v_doc
   where id = '20000000-0000-0000-0000-000000000001';   -- Dr Maria Santos

  insert into public.clinic_memberships (profile_id, clinic_id, role) values
    (v_doc,    c_dental, 'doctor'),
    (v_asst,   c_dental, 'assistant'),
    (v_admin,  c_dental, 'admin'),
    (v_admin,  c_opto,   'admin'),
    (v_admin,  c_pedia,  'admin'),
    (v_bright, c_bright, 'admin')
  on conflict (profile_id, clinic_id) do update set role = excluded.role;
end;
$$;

select u.email,
       p.full_name,
       coalesce(
         (select string_agg(c.name || ' (' || m.role || ')', ', ' order by c.name)
            from public.clinic_memberships m
            join public.clinics c on c.id = m.clinic_id
           where m.profile_id = p.id),
         '—') as staff_at,
       (select count(*) from public.patients pt
          join public.persons pe on pe.id = pt.person_id
         where pe.profile_id = p.id) as charts,
       (select count(*) from public.doctors d
         where d.profile_id = p.id) as roster_rows
  from public.profiles p
  join auth.users u on u.id = p.id
 order by u.email;
