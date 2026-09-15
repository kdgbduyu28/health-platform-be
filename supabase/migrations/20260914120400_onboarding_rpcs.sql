-- ============================================================================
-- health-platform · onboarding without the service role key
--
-- Until now, attaching anyone to a clinic meant hand-written SQL run with the
-- service_role secret (README, "Wire up a test user"). That does not survive a
-- second client. These functions are the two doors in:
--
--   join_clinic   a patient enters a clinic's code and gets a chart there
--   invite_staff  a clinic's admin grants a role at THAT clinic
--   remove_staff  …and takes it away
--
-- All three are SECURITY DEFINER, unlike book_walk_in. They have to be: the
-- rows they write (a chart for yourself, a membership) have no RLS write path
-- by design, because a policy loose enough to allow them would let anyone
-- attach themselves anywhere. Each function is therefore its own policy, and
-- does every check explicitly before touching a row.
-- ============================================================================

-- ── join_clinic ─────────────────────────────────────────────────────────────
-- Idempotent: joining a clinic you already belong to returns its id and
-- changes nothing. The same error covers a wrong code and an inactive clinic,
-- so the function does not confirm which codes exist.
--
-- The code is the only thing standing between a signed-in stranger and a
-- clinic's roster. At ~10^12 possibilities it is not brute-forceable through
-- the API in practice, but it is shareable by design: a clinic that wants to
-- stop self-service joins sets join_code to null.

create or replace function public.join_clinic(p_join_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_clinic_id uuid;
  v_person_id uuid;
begin
  if v_uid is null then
    raise exception 'sign in before joining a clinic';
  end if;

  select c.id into v_clinic_id
    from public.clinics c
   where c.join_code = upper(trim(p_join_code))
     and c.is_active;

  if v_clinic_id is null then
    raise exception 'that clinic code is not valid';
  end if;

  -- ON CONFLICT covers two first-time joins racing each other.
  insert into public.persons (profile_id, full_name, email, phone)
  select pr.id, pr.full_name, pr.email, pr.phone
    from public.profiles pr
   where pr.id = v_uid
  on conflict (profile_id) do nothing;

  select pe.id into v_person_id
    from public.persons pe
   where pe.profile_id = v_uid;

  insert into public.patients (person_id, clinic_id, created_by)
  values (v_person_id, v_clinic_id, v_uid)
  on conflict (person_id, clinic_id) do nothing;

  return v_clinic_id;
end;
$$;

-- ── invite_staff ────────────────────────────────────────────────────────────
-- Grants (or changes) a role at one clinic. Because the role lives on the
-- membership (20260914120200), this cannot affect the person's standing at any
-- other clinic.
--
-- The invitee must already have an account. Creating auth users needs the Auth
-- admin API, which is not reachable from SQL without the service role — so the
-- flow is: they sign up in any app, then an admin invites their email.
--
-- An admin can learn whether an email has an account by trying it. That is
-- limited to clinic admins and accepted.

create or replace function public.invite_staff(
  p_clinic_id uuid,
  p_email     text,
  p_role      public.app_role
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid;
begin
  if not private.is_clinic_admin(p_clinic_id) then
    raise exception 'only an admin of this clinic can invite staff';
  end if;

  if p_role not in ('doctor', 'assistant', 'admin') then
    raise exception 'staff role must be doctor, assistant or admin';
  end if;

  select pr.id into v_profile_id
    from public.profiles pr
   where lower(pr.email) = lower(trim(p_email));

  if v_profile_id is null then
    raise exception 'no account uses that email yet; ask them to sign up first';
  end if;

  if p_role <> 'admin' and private.is_last_admin(p_clinic_id, v_profile_id) then
    raise exception 'a clinic must keep at least one admin';
  end if;

  insert into public.clinic_memberships (profile_id, clinic_id, role)
  values (v_profile_id, p_clinic_id, p_role)
  on conflict (profile_id, clinic_id) do update set role = excluded.role;

  return v_profile_id;
end;
$$;

-- ── remove_staff ────────────────────────────────────────────────────────────
-- Also unlinks the person from this clinic's roster, so a departed doctor stops
-- seeing their old appointments through appointments_select_own_doctor. The
-- roster row itself stays: it is what past appointments point at.

create or replace function public.remove_staff(
  p_clinic_id  uuid,
  p_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_clinic_admin(p_clinic_id) then
    raise exception 'only an admin of this clinic can remove staff';
  end if;

  if private.is_last_admin(p_clinic_id, p_profile_id) then
    raise exception 'a clinic must keep at least one admin';
  end if;

  delete from public.clinic_memberships
   where clinic_id = p_clinic_id and profile_id = p_profile_id;

  update public.doctors
     set profile_id = null
   where clinic_id = p_clinic_id and profile_id = p_profile_id;
end;
$$;

-- ── rotate_join_code ────────────────────────────────────────────────────────
-- For when a code has been shared further than the clinic wanted. The old code
-- stops working immediately; existing patients are unaffected, since joining
-- is a one-time act. To switch self-service joins off entirely, an admin sets
-- join_code to null directly (allowed by the column grant below).

create or replace function public.rotate_join_code(p_clinic_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if not private.is_clinic_admin(p_clinic_id) then
    raise exception 'only an admin of this clinic can change its join code';
  end if;

  -- A collision among ~10^12 codes is not a realistic event, but if one
  -- happens the unique constraint would surface as a baffling error. Retry.
  for attempt in 1..5 loop
    v_code := private.new_join_code();
    begin
      update public.clinics set join_code = v_code where id = p_clinic_id;
      return v_code;
    exception when unique_violation then
      null;
    end;
  end loop;

  raise exception 'could not generate a unique join code; try again';
end;
$$;

-- ── What a clinic admin may edit ────────────────────────────────────────────
-- clinics_update_admin decides WHICH rows an admin may update (their own
-- clinics). RLS cannot restrict columns, so without this an admin could also
-- flip `is_active` — a platform decision (suspension, offboarding) — or re-type
-- their clinic or rename its slug. Column privileges close that: presentation
-- and contact details are the clinic's; identity and status are the operator's.

revoke update on public.clinics from anon, authenticated;
grant update (name, logo_url, wordmark_url, seed_color, contact_phone, address,
              timezone, join_code)
  on public.clinics to authenticated;

-- True when this profile is currently the clinic's only admin.
create or replace function private.is_last_admin(p_clinic uuid, p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
           select 1 from public.clinic_memberships m
           where m.clinic_id = p_clinic and m.profile_id = p_profile
             and m.role = 'admin')
     and not exists (
           select 1 from public.clinic_memberships m
           where m.clinic_id = p_clinic and m.profile_id <> p_profile
             and m.role = 'admin');
$$;

revoke all on function private.is_last_admin(uuid, uuid) from public, anon, authenticated;

-- ── Grants ──────────────────────────────────────────────────────────────────
-- PostgREST publishes every public function; only signed-in callers get these.

revoke all on function public.join_clinic(text)                             from public, anon;
revoke all on function public.invite_staff(uuid, text, public.app_role)     from public, anon;
revoke all on function public.remove_staff(uuid, uuid)                      from public, anon;
revoke all on function public.rotate_join_code(uuid)                        from public, anon;

grant execute on function public.join_clinic(text)                          to authenticated;
grant execute on function public.invite_staff(uuid, text, public.app_role)  to authenticated;
grant execute on function public.remove_staff(uuid, uuid)                   to authenticated;
grant execute on function public.rotate_join_code(uuid)                     to authenticated;
