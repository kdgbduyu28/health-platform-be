-- ============================================================================
-- health-platform · split identity from the clinical chart
--
-- `patients` used to be one row per human, platform-wide (`profile_id` was
-- UNIQUE), and private.staff_can_access_patient opened that whole row —
-- medical_notes included — to staff at ANY clinic the person had ever booked
-- with. Across three sibling demo clinics that read as "referrals". Across
-- unrelated clients it means one dental practice reads a competitor's notes on
-- a patient the moment that patient books with them once.
--
-- The model after this migration:
--
--   persons   who someone is — name, phone, email, DOB, optional account link.
--             One row per human.
--   patients  a CHART: one per (person, clinic). Holds the clinical notes, and
--             belongs to exactly one clinic, forever.
--
-- Staff access to a chart is now simply "you staff the clinic it belongs to".
-- The appointment-based referral branch, and the snapshot hazard it had to work
-- around, are gone.
--
-- Trade-off, deliberate: the `persons` row is shared. Staff at every clinic
-- that holds a chart for someone can read (and correct) that person's contact
-- details. Clinical content never crosses.
-- ============================================================================

-- ── 1. Policies and helpers that depend on what is changing ────────────────

drop policy patients_select_own             on public.patients;
drop policy patients_select_treating_staff  on public.patients;
drop policy patients_insert_self            on public.patients;
drop policy patients_insert_staff           on public.patients;
drop policy patients_update_own             on public.patients;
drop policy patients_update_treating_staff  on public.patients;
drop policy appointments_select_own_patient on public.appointments;
drop policy appointments_insert_own_patient on public.appointments;
drop policy appointments_cancel_own_patient on public.appointments;

drop function private.my_patient_id();
drop function private.staff_can_access_patient(uuid, uuid);

-- ── 2. persons ──────────────────────────────────────────────────────────────

create table public.persons (
  id            uuid primary key default gen_random_uuid(),
  -- Null for walk-ins who have never signed up.
  profile_id    uuid unique references public.profiles (id) on delete set null,
  full_name     text not null,
  -- Nullable: a self-service signup may not have given one. Walk-in
  -- registration still requires it (enforced in book_walk_in).
  phone         text,
  email         text,
  date_of_birth date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger persons_set_updated_at
  before update on public.persons
  for each row execute function public.set_updated_at();

-- ── 3. Backfill identity from the old rows ─────────────────────────────────
-- A volatile column default is evaluated per row during the table rewrite, so
-- every existing patient gets its own person id without an UPDATE — and
-- without firing patients_set_updated_at, which would stamp every row with the
-- migration time.

alter table public.patients
  add column person_id uuid not null default gen_random_uuid(),
  add column clinic_id uuid;

alter table public.patients alter column person_id drop default;

insert into public.persons
  (id, profile_id, full_name, phone, email, date_of_birth, created_at, updated_at)
select person_id, profile_id, full_name, phone, email, date_of_birth,
       created_at, updated_at
from public.patients;

-- Structural moves below are not edits; keep the original timestamps.
alter table public.patients     disable trigger patients_set_updated_at;
alter table public.appointments disable trigger appointments_set_updated_at;

update public.patients set clinic_id = registered_clinic_id;

-- Self-signups never had a home clinic. Adopt the clinic of their first visit.
update public.patients pt
   set clinic_id = (
     select a.clinic_id from public.appointments a
      where a.patient_id = pt.id
      order by a.scheduled_at
      limit 1)
 where pt.clinic_id is null;

-- Still null: no home clinic and no visits, so there was never a chart — only
-- an identity, which the persons row now holds.
delete from public.patients where clinic_id is null;

-- ── 4. The chart no longer carries identity ────────────────────────────────

alter table public.patients
  drop column profile_id,
  drop column registered_clinic_id,
  drop column full_name,
  drop column phone,
  drop column email,
  drop column date_of_birth;

-- ── 5. One chart per clinic actually visited ───────────────────────────────
-- A person whose appointments span several clinics gets a chart at each. The
-- extra charts start with EMPTY medical_notes: the existing notes were written
-- by the home clinic, and copying them is exactly the leak this migration
-- exists to close.

create temporary table chart_split as
select pairs.old_chart_id, pairs.person_id, pairs.clinic_id,
       gen_random_uuid() as new_chart_id
from (
  select distinct pt.id as old_chart_id, pt.person_id, a.clinic_id
  from public.patients pt
  join public.appointments a on a.patient_id = pt.id
  where a.clinic_id <> pt.clinic_id
) pairs;

insert into public.patients
  (id, person_id, clinic_id, created_by, created_at, updated_at)
select s.new_chart_id, s.person_id, s.clinic_id,
       pt.created_by, pt.created_at, pt.updated_at
from chart_split s
join public.patients pt on pt.id = s.old_chart_id;

update public.appointments a
   set patient_id = s.new_chart_id
  from chart_split s
 where a.patient_id = s.old_chart_id
   and a.clinic_id  = s.clinic_id;

drop table chart_split;

alter table public.patients     enable trigger patients_set_updated_at;
alter table public.appointments enable trigger appointments_set_updated_at;

-- ── 6. Constraints ─────────────────────────────────────────────────────────

alter table public.patients
  alter column clinic_id set not null,
  -- RESTRICT: removing a person who has clinical history should be a
  -- deliberate act on their charts first, never a side effect.
  add constraint patients_person_id_fkey
    foreign key (person_id) references public.persons (id) on delete restrict,
  add constraint patients_clinic_id_fkey
    foreign key (clinic_id) references public.clinics (id) on delete cascade,
  add constraint patients_one_chart_per_clinic unique (person_id, clinic_id),
  -- Target for the composite FK below.
  add constraint patients_id_clinic_key unique (id, clinic_id);

create index patients_clinic_idx on public.patients (clinic_id);

-- Appointments already pinned their doctor and service to the booking's
-- clinic; the chart was never pinned, so an appointment could reference
-- another clinic's patient record. Same composite-FK pattern as
-- 20260818100000, and for the same PostgREST reason the single-column FK is
-- dropped rather than kept alongside: two relationships between the tables
-- makes `patient:patients(*)` fail with PGRST201.
alter table public.appointments
  drop constraint appointments_patient_id_fkey,
  add constraint appointments_patient_matches_clinic
    foreign key (patient_id, clinic_id)
    references public.patients (id, clinic_id)
    on delete cascade;

-- ── 7. Guards RLS cannot express ───────────────────────────────────────────
-- RLS cannot compare OLD to NEW, so these are triggers. Service-role and
-- SQL-editor sessions (auth.uid() is null) are trusted, matching
-- guard_profile_role_change: merging a duplicate walk-in into an account
-- holder's person is a legitimate operator task.

create or replace function private.guard_chart_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (new.person_id is distinct from old.person_id
          or new.clinic_id is distinct from old.clinic_id) then
    raise exception 'a chart cannot be moved to another person or clinic';
  end if;
  return new;
end;
$$;

create trigger patients_guard_identity
  before update on public.patients
  for each row execute function private.guard_chart_identity();

-- Linking a person to an account decides whose session can read the charts,
-- so neither the person nor clinic staff may set it. Unlinking (to null) is
-- allowed: that is what `on delete set null` does when a profile is removed.
create or replace function private.guard_person_account_link()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and new.profile_id is not null
     and new.profile_id is distinct from old.profile_id then
    raise exception 'linking a person to an account requires the service role';
  end if;
  return new;
end;
$$;

create trigger persons_guard_account_link
  before update on public.persons
  for each row execute function private.guard_person_account_link();

revoke all on function private.guard_chart_identity()      from public, anon, authenticated;
revoke all on function private.guard_person_account_link() from public, anon, authenticated;

-- ── 8. Helpers ─────────────────────────────────────────────────────────────
-- SECURITY DEFINER for the same reason as the originals: reading the caller's
-- own rows must not re-enter RLS on those same tables.

create or replace function private.my_person_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.persons where profile_id = auth.uid();
$$;

-- Replaces my_patient_id(): a person now holds one chart per clinic, so this
-- is a set. Use as `patient_id in (select private.my_patient_ids())`.
create or replace function private.my_patient_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select pt.id
  from public.patients pt
  join public.persons pe on pe.id = pt.person_id
  where pe.profile_id = auth.uid();
$$;

-- May register patients at this clinic. Rewritten in 20260914120200 once the
-- role moves onto the membership.
create or replace function private.can_register_patients(p_clinic uuid)
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
      and p.role in ('assistant', 'admin')
  );
$$;

-- May register patients somewhere. `persons` has no clinic of its own, so this
-- is the gate for creating one.
create or replace function private.is_registrar()
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
      and p.role in ('assistant', 'admin')
  );
$$;

-- Staff at some clinic that holds a chart for this person.
--
-- A person inserted by the current statement is not visible here yet (STABLE
-- functions read the snapshot from the start of the calling statement), and in
-- any case holds no chart. So `INSERT INTO persons … RETURNING` fails for
-- staff: RETURNING is checked against SELECT policies. Create the person
-- without RETURNING and supply the id yourself — see book_walk_in.
create or replace function private.staff_can_access_person(p_person uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.patients pt
    join public.clinic_memberships m on m.clinic_id = pt.clinic_id
    where pt.person_id = p_person
      and m.profile_id = auth.uid()
  );
$$;

-- Whether staff may open a chart for this person at their clinic.
--
-- Allowed: a brand-new walk-in (no account, no charts anywhere), or someone the
-- caller can already see. Refused: attaching a chart to a person who belongs
-- only to OTHER clinics, which would otherwise let staff pull a stranger's
-- identity row into view just by knowing its id.
--
-- Written as absence checks on purpose: inside a single statement that
-- creates the person too, the new row is not in this function's snapshot, and
-- "no account, no charts" is still the right answer for it.
--
-- Consequence worth knowing: an existing patient of another clinic who walks
-- in gets a NEW person row here rather than being matched. Linking the two is
-- the person's own call (join_clinic) or an operator merge — never a front
-- desk lookup across tenants.
create or replace function private.person_is_linkable(p_person uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (
    not exists (select 1 from public.persons pe
                where pe.id = p_person and pe.profile_id is not null)
    and not exists (select 1 from public.patients pt
                    where pt.person_id = p_person)
  ) or private.staff_can_access_person(p_person);
$$;

grant execute on function
  private.my_person_id(),
  private.my_patient_ids(),
  private.can_register_patients(uuid),
  private.is_registrar(),
  private.staff_can_access_person(uuid),
  private.person_is_linkable(uuid)
to authenticated;

-- ── 9. Row Level Security ──────────────────────────────────────────────────

alter table public.persons enable row level security;

-- persons

create policy persons_select_own on public.persons
  for select to authenticated using (profile_id = auth.uid());

create policy persons_select_treating_staff on public.persons
  for select to authenticated using (private.staff_can_access_person(id));

-- Walk-ins only: staff never create a person bound to an account.
create policy persons_insert_staff on public.persons
  for insert to authenticated with check (
    profile_id is null and private.is_registrar()
  );

create policy persons_update_own on public.persons
  for update to authenticated
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create policy persons_update_treating_staff on public.persons
  for update to authenticated
  using (private.staff_can_access_person(id))
  with check (private.staff_can_access_person(id));

-- patients (charts)
--
-- No self-insert and no self-update. A patient gets a chart by joining a clinic
-- (join_clinic), never by inserting one — otherwise anyone could attach
-- themselves to any clinic and read its roster. And the only content left on a
-- chart is clinical, which is the clinic's to write.

create policy patients_select_own on public.patients
  for select to authenticated using (person_id = private.my_person_id());

create policy patients_select_treating_staff on public.patients
  for select to authenticated using (private.is_clinic_staff(clinic_id));

create policy patients_insert_staff on public.patients
  for insert to authenticated with check (
    private.can_register_patients(clinic_id)
    and private.person_is_linkable(person_id)
  );

create policy patients_update_treating_staff on public.patients
  for update to authenticated
  using (private.is_clinic_staff(clinic_id))
  with check (private.is_clinic_staff(clinic_id));

-- appointments (the patient-side policies; staff policies are unchanged)
--
-- The composite FK does the cross-clinic work: a chart at clinic A can only
-- book at clinic A, so "one of my charts" is sufficient here.

create policy appointments_select_own_patient on public.appointments
  for select to authenticated
  using (patient_id in (select private.my_patient_ids()));

create policy appointments_insert_own_patient on public.appointments
  for insert to authenticated with check (
    patient_id in (select private.my_patient_ids()) and status = 'pending'
  );

create policy appointments_cancel_own_patient on public.appointments
  for update to authenticated
  using (patient_id in (select private.my_patient_ids()))
  with check (
    patient_id in (select private.my_patient_ids()) and status = 'cancelled'
  );

-- ── 10. book_walk_in, rewritten for the split ──────────────────────────────
-- Same signature, same SECURITY INVOKER reasoning as 20260901120000 — the
-- caller's RLS must still decide. Three inserts now instead of two, still one
-- transaction.
--
-- Ids are generated up front instead of read back with RETURNING, because a
-- person who holds no chart yet is not readable by the staff member creating
-- them (see private.staff_can_access_person).

create or replace function public.book_walk_in(
  p_clinic_id    uuid,
  p_full_name    text,
  p_phone        text,
  p_doctor_id    uuid,
  p_service_name text,
  p_scheduled_at timestamptz,
  p_service_id   uuid default null,
  p_email        text default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_person_id      uuid := gen_random_uuid();
  v_patient_id     uuid := gen_random_uuid();
  v_appointment_id uuid := gen_random_uuid();
begin
  if coalesce(trim(p_full_name), '') = '' then
    raise exception 'patient name is required';
  end if;
  if coalesce(trim(p_phone), '') = '' then
    raise exception 'patient phone is required';
  end if;

  insert into public.persons (id, full_name, phone, email)
  values (v_person_id, trim(p_full_name), trim(p_phone),
          nullif(trim(coalesce(p_email, '')), ''));

  -- RLS requires a clinic the caller registers patients at.
  insert into public.patients (id, person_id, clinic_id, created_by)
  values (v_patient_id, v_person_id, p_clinic_id, auth.uid());

  -- Staff may book straight to confirmed; RLS only pins patients to 'pending'.
  insert into public.appointments
    (id, clinic_id, patient_id, doctor_id, service_id, service_name,
     scheduled_at, status, created_by)
  values
    (v_appointment_id, p_clinic_id, v_patient_id, p_doctor_id, p_service_id,
     p_service_name, p_scheduled_at, 'confirmed', auth.uid());

  return v_appointment_id;
end;
$$;
