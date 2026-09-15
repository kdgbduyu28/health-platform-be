-- ============================================================================
-- health-platform · staff roles are per clinic
--
-- `profiles.role` was ONE role per account, platform-wide, and every clinic
-- check read it:
--
--   is_clinic_admin(A)  =  profile.role = 'admin'  AND  member of A
--
-- With three sibling clinics run by one operator, harmless. With independent
-- clients it is a privilege escalation: the moment any clinic's admin can make
-- someone an admin (invite_staff, 20260914120400), that person becomes an
-- admin at EVERY clinic where they already hold a membership — granted by a
-- different tenant. It also cannot represent a dentist who owns one clinic and
-- does shifts at another.
--
-- So the role moves onto `clinic_memberships`. A profile is now just an
-- account; what it may do is decided per clinic.
--
-- Same problem, smaller: `doctors.profile_id` was UNIQUE, so an account could
-- sit on only one clinic's roster. It becomes unique per clinic.
-- ============================================================================

-- ── 1. Role onto the membership ────────────────────────────────────────────

alter table public.clinic_memberships add column role public.app_role;

update public.clinic_memberships m
   set role = p.role
  from public.profiles p
 where p.id = m.profile_id;

-- A membership held by a 'patient' profile never granted anything —
-- is_clinic_staff always required a staff role — so there is no role to carry.
delete from public.clinic_memberships where role = 'patient';

alter table public.clinic_memberships
  alter column role set not null,
  add constraint clinic_memberships_staff_role check (role <> 'patient');

-- ── 2. Helpers read the membership ─────────────────────────────────────────
-- Bodies change, signatures do not, so no policy has to be recreated.

create or replace function private.is_clinic_staff(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = auth.uid()
      and m.clinic_id = p_clinic
  );
$$;

create or replace function private.is_clinic_admin(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = auth.uid()
      and m.clinic_id = p_clinic
      and m.role = 'admin'
  );
$$;

create or replace function private.can_register_patients(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = auth.uid()
      and m.clinic_id = p_clinic
      and m.role in ('assistant', 'admin')
  );
$$;

create or replace function private.is_registrar()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = auth.uid()
      and m.role in ('assistant', 'admin')
  );
$$;

-- ── 3. A doctor may be on several rosters ──────────────────────────────────

drop policy appointments_select_own_doctor on public.appointments;
drop function private.my_doctor_id();

alter table public.doctors
  drop constraint doctors_profile_id_key,
  add constraint doctors_one_roster_row_per_clinic unique (profile_id, clinic_id);

create or replace function private.my_doctor_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.doctors where profile_id = auth.uid();
$$;

grant execute on function private.my_doctor_ids() to authenticated;

create policy appointments_select_own_doctor on public.appointments
  for select to authenticated
  using (doctor_id in (select private.my_doctor_ids()));

-- ── 4. Retire the global role ──────────────────────────────────────────────
-- Nothing can escalate a role any more without the guard trigger: memberships
-- have no INSERT/UPDATE policy, so the only writers are the service role and
-- the admin-checked RPCs.

drop function private.my_role();

drop trigger profiles_guard_role_change on public.profiles;
drop function public.guard_profile_role_change();

-- A signup is an account and nothing more. Access comes only from a membership
-- (staff) or a chart (patient). Client-supplied metadata is still used for the
-- display name only; there is no longer a role in it to be tempted by.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      split_part(coalesce(new.email, 'user'), '@', 1)
    ),
    new.email
  );
  return new;
end;
$$;

alter table public.profiles drop column role;
