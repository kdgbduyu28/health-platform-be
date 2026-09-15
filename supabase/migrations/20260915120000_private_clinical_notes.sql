-- ============================================================================
-- health-platform · clinical notes are for clinicians only
--
-- Clinical text lived on two rows that other people legitimately read:
--
--   patients.medical_notes   readable by every staff member at the clinic,
--                            front desk included
--   appointments.notes       readable by the front desk AND by the patient
--
-- RLS decides which ROWS a caller sees, never which columns, so there was no
-- policy that could let the front desk check someone in without also reading
-- their allergies, or let a patient see their booking without also reading
-- the doctor's working notes on it.
--
-- So the clinical text moves onto rows of its own, readable and writable only
-- by the clinic's doctors and admins:
--
--   chart_notes   one per chart     — standing notes: allergies, conditions
--   visit_notes   one per appointment — the consultation note
--
-- What a patient should read is now a separate, deliberate field:
-- appointments.patient_note. Anyone who can see the appointment reads it; only
-- a clinician may write it (guard trigger — RLS cannot restrict a column).
--
-- Existing appointments.notes become visit notes, NOT patient notes: they were
-- written as clinical notes, and republishing them to patients is exactly the
-- decision this migration takes away.
-- ============================================================================

-- ── 1. Who counts as a clinician ───────────────────────────────────────────

create or replace function private.is_clinician(p_clinic uuid)
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
      and m.role in ('doctor', 'admin')
  );
$$;

grant execute on function private.is_clinician(uuid) to authenticated;

-- ── 2. Tables ──────────────────────────────────────────────────────────────
-- Both carry clinic_id and pin it with a composite FK, the same pattern
-- appointments uses: a note can only ever belong to the clinic that owns the
-- chart or appointment it is about, so a policy on clinic_id is sufficient.

-- Target for visit_notes' composite FK.
alter table public.appointments
  add constraint appointments_id_clinic_key unique (id, clinic_id);

create table public.chart_notes (
  patient_id uuid primary key,
  clinic_id  uuid not null,
  body       text not null,
  -- Set by trigger from the session, never trusted from the client.
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint chart_notes_patient_matches_clinic
    foreign key (patient_id, clinic_id)
    references public.patients (id, clinic_id)
    on delete cascade
);

create table public.visit_notes (
  appointment_id uuid primary key,
  clinic_id      uuid not null,
  body           text not null,
  updated_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint visit_notes_appointment_matches_clinic
    foreign key (appointment_id, clinic_id)
    references public.appointments (id, clinic_id)
    on delete cascade
);

create index chart_notes_clinic_idx on public.chart_notes (clinic_id);
create index visit_notes_clinic_idx on public.visit_notes (clinic_id);

create trigger chart_notes_set_updated_at
  before update on public.chart_notes
  for each row execute function public.set_updated_at();

create trigger visit_notes_set_updated_at
  before update on public.visit_notes
  for each row execute function public.set_updated_at();

-- Service-role and SQL-editor sessions have no auth.uid(); they keep whatever
-- author they supply, which is what a backfill or an operator fix needs.
create or replace function private.stamp_note_author()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end;
$$;

revoke all on function private.stamp_note_author() from public, anon, authenticated;

create trigger chart_notes_stamp_author
  before insert or update on public.chart_notes
  for each row execute function private.stamp_note_author();

create trigger visit_notes_stamp_author
  before insert or update on public.visit_notes
  for each row execute function private.stamp_note_author();

-- ── 3. Move the text ───────────────────────────────────────────────────────
-- Blank notes carry no information; they are not worth a row.

insert into public.chart_notes (patient_id, clinic_id, body, created_at, updated_at)
select id, clinic_id, medical_notes, updated_at, updated_at
from public.patients
where nullif(trim(medical_notes), '') is not null;

insert into public.visit_notes (appointment_id, clinic_id, body, created_at, updated_at)
select id, clinic_id, notes, updated_at, updated_at
from public.appointments
where nullif(trim(notes), '') is not null;

alter table public.patients     drop column medical_notes;
alter table public.appointments drop column notes;

-- ── 4. The part a patient reads ────────────────────────────────────────────

alter table public.appointments add column patient_note text;

create or replace function private.guard_patient_note()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return new;
  end if;
  if (tg_op = 'INSERT' and new.patient_note is not null)
     or (tg_op = 'UPDATE' and new.patient_note is distinct from old.patient_note) then
    if not private.is_clinician(new.clinic_id) then
      raise exception 'only a doctor or admin of this clinic can write the note to the patient';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.guard_patient_note() from public, anon, authenticated;

create trigger appointments_guard_patient_note
  before insert or update on public.appointments
  for each row execute function private.guard_patient_note();

-- ── 5. Row Level Security ──────────────────────────────────────────────────
-- No delete policies: clearing a note is an update to an empty body, so the
-- row — and who last touched it — survives.

alter table public.chart_notes enable row level security;
alter table public.visit_notes enable row level security;

create policy chart_notes_select_clinician on public.chart_notes
  for select to authenticated using (private.is_clinician(clinic_id));

create policy chart_notes_insert_clinician on public.chart_notes
  for insert to authenticated with check (private.is_clinician(clinic_id));

create policy chart_notes_update_clinician on public.chart_notes
  for update to authenticated
  using (private.is_clinician(clinic_id))
  with check (private.is_clinician(clinic_id));

create policy visit_notes_select_clinician on public.visit_notes
  for select to authenticated using (private.is_clinician(clinic_id));

create policy visit_notes_insert_clinician on public.visit_notes
  for insert to authenticated with check (private.is_clinician(clinic_id));

create policy visit_notes_update_clinician on public.visit_notes
  for update to authenticated
  using (private.is_clinician(clinic_id))
  with check (private.is_clinician(clinic_id));
