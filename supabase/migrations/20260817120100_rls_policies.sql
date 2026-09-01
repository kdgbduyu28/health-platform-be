-- ============================================================================
-- health-platform · Row Level Security
--
-- Every table is deny-by-default. `anon` gets nothing: all four apps require a
-- signed-in user. The three clinic flavors share one database, so clinic
-- isolation is enforced here rather than by separate projects.
--
-- Helper functions live in a `private` schema and are SECURITY DEFINER so that
-- reading a user's own role/clinic does not re-trigger RLS (which would
-- recurse through public.profiles).
-- ============================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- ── Helpers ─────────────────────────────────────────────────────────────────

create or replace function private.my_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function private.my_patient_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.patients where profile_id = auth.uid();
$$;

create or replace function private.my_doctor_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.doctors where profile_id = auth.uid();
$$;

-- True when the caller is doctor / assistant / admin at this clinic.
create or replace function private.is_clinic_staff(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.clinic_memberships m
    join public.profiles p on p.id = m.profile_id
    where m.profile_id = auth.uid()
      and m.clinic_id = p_clinic
      and p.role in ('doctor', 'assistant', 'admin')
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
    select 1
    from public.clinic_memberships m
    join public.profiles p on p.id = m.profile_id
    where m.profile_id = auth.uid()
      and m.clinic_id = p_clinic
      and p.role = 'admin'
  );
$$;

-- True when the caller is staff at a clinic that legitimately holds this
-- patient's chart — either the patient is on that clinic's roster, or they have
-- an appointment there (which covers referrals from another clinic). This is
-- what lets an assistant pull up a record without exposing every patient in
-- the database.
--
-- The roster half matters for writes as much as reads: a newly registered
-- walk-in has no appointment yet, so an appointment-only rule would make the
-- record unreadable to the very person who just created it — and would fail
-- outright for `.insert().select()`, which returns the inserted row.
--
-- Both of the patient's own columns are passed IN rather than looked up here.
-- That is deliberate: this function is STABLE, so it runs against the snapshot
-- taken at statement start, and a row being inserted by the current statement
-- is not in that snapshot. A self-lookup would therefore report "no such
-- patient" and deny the RETURNING clause of the very INSERT that created it.
-- Reading the values from the candidate row sidesteps the snapshot entirely,
-- and the tables this function *does* read are never the ones being written.
create or replace function private.staff_can_access_patient(
  p_patient uuid,
  p_registered_clinic uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.clinic_memberships m
    join public.profiles pr on pr.id = m.profile_id
    where m.profile_id = auth.uid()
      and pr.role in ('doctor', 'assistant', 'admin')
      and (
        m.clinic_id = p_registered_clinic
        or exists (
          select 1 from public.appointments a
          where a.patient_id = p_patient and a.clinic_id = m.clinic_id
        )
      )
  );
$$;

grant execute on all functions in schema private to authenticated;

-- ── Enable RLS everywhere ───────────────────────────────────────────────────

alter table public.clinics            enable row level security;
alter table public.profiles           enable row level security;
alter table public.clinic_memberships enable row level security;
alter table public.services           enable row level security;
alter table public.doctors            enable row level security;
alter table public.patients           enable row level security;
alter table public.appointments       enable row level security;

-- ── clinics ─────────────────────────────────────────────────────────────────
-- Readable by any signed-in user: the patient app shows a clinic picker.
-- Created only with the service role key.

create policy clinics_select_authenticated on public.clinics
  for select to authenticated using (true);

create policy clinics_update_admin on public.clinics
  for update to authenticated
  using (private.is_clinic_admin(id))
  with check (private.is_clinic_admin(id));

-- ── profiles ────────────────────────────────────────────────────────────────

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());

-- Staff can see colleagues at clinics they share.
create policy profiles_select_colleagues on public.profiles
  for select to authenticated using (
    exists (
      select 1 from public.clinic_memberships m
      where m.profile_id = profiles.id
        and private.is_clinic_staff(m.clinic_id)
    )
  );

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- A user may edit their own name/phone but never their own role. RLS cannot
-- compare OLD to NEW, so the role is locked down by trigger instead.
create or replace function public.guard_profile_role_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- auth.uid() is null for service-role/SQL-editor calls, which are trusted.
  if new.role is distinct from old.role and auth.uid() is not null then
    raise exception 'role changes require the service role key';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_role_change
  before update on public.profiles
  for each row execute function public.guard_profile_role_change();

-- ── clinic_memberships ──────────────────────────────────────────────────────
-- Read-only from the apps; staffing changes go through the service role key.

create policy memberships_select_own on public.clinic_memberships
  for select to authenticated using (profile_id = auth.uid());

create policy memberships_select_admin on public.clinic_memberships
  for select to authenticated using (private.is_clinic_admin(clinic_id));

-- ── services ────────────────────────────────────────────────────────────────

create policy services_select_authenticated on public.services
  for select to authenticated using (true);

create policy services_write_admin on public.services
  for all to authenticated
  using (private.is_clinic_admin(clinic_id))
  with check (private.is_clinic_admin(clinic_id));

-- ── doctors ─────────────────────────────────────────────────────────────────
-- Any signed-in user can browse doctors: the patient booking flow needs the
-- roster, weekdays and time slots.

create policy doctors_select_authenticated on public.doctors
  for select to authenticated using (true);

create policy doctors_write_admin on public.doctors
  for all to authenticated
  using (private.is_clinic_admin(clinic_id))
  with check (private.is_clinic_admin(clinic_id));

-- A doctor may maintain their own availability.
create policy doctors_update_self on public.doctors
  for update to authenticated
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

-- ── patients ────────────────────────────────────────────────────────────────

create policy patients_select_own on public.patients
  for select to authenticated using (profile_id = auth.uid());

create policy patients_select_treating_staff on public.patients
  for select to authenticated using (private.staff_can_access_patient(id, registered_clinic_id));

-- A new patient claims their own record after signing up.
create policy patients_insert_self on public.patients
  for insert to authenticated with check (profile_id = auth.uid());

-- Assistants and admins register walk-ins, who have no account yet. The new
-- record must be stamped with a clinic the caller actually staffs, which both
-- prevents dumping orphan patients into the table and makes the row readable
-- back to them immediately.
create policy patients_insert_staff on public.patients
  for insert to authenticated with check (
    private.my_role() in ('assistant', 'admin')
    and registered_clinic_id is not null
    and private.is_clinic_staff(registered_clinic_id)
  );

create policy patients_update_own on public.patients
  for update to authenticated
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create policy patients_update_treating_staff on public.patients
  for update to authenticated
  using (private.staff_can_access_patient(id, registered_clinic_id))
  with check (private.staff_can_access_patient(id, registered_clinic_id));

-- ── appointments ────────────────────────────────────────────────────────────

create policy appointments_select_own_patient on public.appointments
  for select to authenticated using (patient_id = private.my_patient_id());

create policy appointments_select_own_doctor on public.appointments
  for select to authenticated using (doctor_id = private.my_doctor_id());

create policy appointments_select_clinic_staff on public.appointments
  for select to authenticated using (private.is_clinic_staff(clinic_id));

-- Patients book for themselves, and only as 'pending' — confirming is the
-- clinic's decision, not the patient's.
create policy appointments_insert_own_patient on public.appointments
  for insert to authenticated with check (
    patient_id = private.my_patient_id() and status = 'pending'
  );

create policy appointments_insert_clinic_staff on public.appointments
  for insert to authenticated with check (private.is_clinic_staff(clinic_id));

create policy appointments_update_clinic_staff on public.appointments
  for update to authenticated
  using (private.is_clinic_staff(clinic_id))
  with check (private.is_clinic_staff(clinic_id));

-- The only change a patient may make to their own booking is cancelling it.
create policy appointments_cancel_own_patient on public.appointments
  for update to authenticated
  using (patient_id = private.my_patient_id())
  with check (patient_id = private.my_patient_id() and status = 'cancelled');

create policy appointments_delete_admin on public.appointments
  for delete to authenticated using (private.is_clinic_admin(clinic_id));
