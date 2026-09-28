-- ============================================================================
-- health-platform · dental charting
--
-- A dental visit is about teeth, and until now the only record of one was
-- free text: "Composite on the lower left molar, watch the upper right". That
-- cannot be drawn, searched, or picked up by the next dentist at a glance.
--
-- This migration adds the odontogram as data:
--
--   dental_chart_entries   one row per thing known about one tooth on one
--                          chart: a condition found (caries, missing, …), work
--                          already present when the patient arrived, work
--                          planned, or work done at a visit
--
-- The chart as the dentist sees it (which teeth are missing, crowned, filled
-- on which surfaces) is a projection of these rows, computed by the apps.
-- Nothing stores "the current state of tooth 36"; it is always derived from
-- what was recorded, so the history can never disagree with the picture.
--
-- Who sees what:
--
--   doctors, admins    read and write (the same people who hold the pen on
--                      clinical notes — private.is_clinician)
--   front desk         read. Which teeth were worked on is not the consultation
--                      note, and the desk needs it to bill and to book the
--                      follow-up. The per-entry note stays out of their reach
--                      only by convention in the app; it is a short technical
--                      detail ("MOD composite, A2"), not the clinical note.
--   the patient        their own chart through patient_dental_chart(), which
--                      leaves the per-entry note out. RLS cannot hide a column,
--                      so patients get no direct SELECT on the table.
--
-- Charting is a feature of the vertical, not of a clinic: clinic_types gets a
-- chart_kind, and only clinics whose type charts teeth accept entries. A new
-- dental clinic gets the odontogram with no release and no per-clinic switch.
-- ============================================================================

-- ── 1. Charting belongs to the vertical ─────────────────────────────────────

alter table public.clinic_types
  add column chart_kind text
    constraint clinic_types_chart_kind_known check (chart_kind in ('dental'));

comment on column public.clinic_types.chart_kind is
  'Which structured chart this vertical keeps, if any. The apps show the '
  'matching charting UI; null means notes only.';

update public.clinic_types set chart_kind = 'dental' where slug = 'dental';

-- ── 2. Tooth numbering ──────────────────────────────────────────────────────
-- FDI / ISO 3950, the two-digit system: quadrant then position. 11–48 are
-- permanent teeth (8 per quadrant), 51–85 primary teeth (5 per quadrant). The
-- apps can display Universal numbering instead; storage is always FDI.

create or replace function private.is_fdi_tooth(p_tooth smallint)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_tooth / 10 between 1 and 4 and p_tooth % 10 between 1 and 8)
      or (p_tooth / 10 between 5 and 8 and p_tooth % 10 between 1 and 5);
$$;

-- ── 3. Target for the entry → visit foreign key ─────────────────────────────
-- An entry recorded at a visit must be on that visit's chart, at that visit's
-- clinic. A three-column key makes that declarative, like every other
-- cross-table rule in this schema.

alter table public.appointments
  add constraint appointments_id_clinic_patient_key
    unique (id, clinic_id, patient_id);

-- ── 4. The entries ──────────────────────────────────────────────────────────

create table public.dental_chart_entries (
  id             uuid primary key default gen_random_uuid(),
  clinic_id      uuid not null,
  patient_id     uuid not null,
  -- The visit it was found, planned or done at. Null for what was recorded
  -- outside a visit (a chart transcribed from paper, say).
  appointment_id uuid,

  tooth          smallint not null
                 constraint dental_chart_entries_tooth_fdi
                 check (private.is_fdi_tooth(tooth)),
  -- M mesial, O occlusal/incisal, D distal, B buccal/facial, L lingual/palatal.
  -- Normalised by trigger to a sorted set.
  surfaces       text[] not null default '{}'
                 constraint dental_chart_entries_surfaces_known
                 check (surfaces <@ array['M','O','D','B','L']::text[]),

  code           text not null
                 constraint dental_chart_entries_code_known
                 check (code in (
                   -- conditions: what is wrong
                   'caries', 'fracture', 'missing', 'impacted', 'watch',
                   -- treatments: what is (or will be) there
                   'filling', 'sealant', 'veneer', 'crown', 'bridge',
                   'root_canal', 'implant', 'extraction')),

  -- existing  found on examination (a condition, or someone else's old work)
  -- planned   the treatment plan: what should happen at a later visit
  -- done      performed at appointment_id
  status         text not null
                 constraint dental_chart_entries_status_known
                 check (status in ('existing', 'planned', 'done')),

  note           text
                 constraint dental_chart_entries_note_length
                 check (char_length(note) <= 500),

  created_by     uuid references public.profiles (id) on delete set null,
  updated_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint dental_chart_entries_patient_matches_clinic
    foreign key (patient_id, clinic_id)
    references public.patients (id, clinic_id)
    on delete cascade,

  -- Only the visit link is cleared if the visit goes; the entry stays on the
  -- chart. (A column list on SET NULL needs Postgres 15.)
  constraint dental_chart_entries_visit_matches_chart
    foreign key (appointment_id, clinic_id, patient_id)
    references public.appointments (id, clinic_id, patient_id)
    on delete set null (appointment_id),

  -- A condition is a finding: it is never planned or done.
  constraint dental_chart_entries_condition_is_existing
    check (code not in ('caries', 'fracture', 'missing', 'impacted', 'watch')
           or status = 'existing'),

  -- A tooth found missing is `missing`, not an `existing` extraction.
  constraint dental_chart_entries_extraction_not_existing
    check (code <> 'extraction' or status <> 'existing'),

  -- Surfaces mean something only for work on part of a crown.
  constraint dental_chart_entries_surfaces_where_meaningful
    check (cardinality(surfaces) = 0
           or code in ('caries', 'fracture', 'filling', 'sealant', 'veneer')),

  -- Work done was done at a visit.
  constraint dental_chart_entries_done_has_visit
    check (status <> 'done' or appointment_id is not null)
);

create index dental_chart_entries_patient_idx
  on public.dental_chart_entries (patient_id, tooth);
create index dental_chart_entries_appointment_idx
  on public.dental_chart_entries (appointment_id)
  where appointment_id is not null;
create index dental_chart_entries_clinic_idx
  on public.dental_chart_entries (clinic_id);

comment on table public.dental_chart_entries is
  'The odontogram as a log: conditions, existing work, the treatment plan and '
  'work done, per tooth (FDI). The current chart is derived from these rows.';

-- ── 5. Triggers ─────────────────────────────────────────────────────────────

create trigger dental_chart_entries_set_updated_at
  before update on public.dental_chart_entries
  for each row execute function public.set_updated_at();

create or replace function private.prepare_dental_entry()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_kind   text;
  v_status public.appointment_status;
begin
  -- Authors come from the session; service-role and SQL-editor sessions keep
  -- whatever they supply, for backfills.
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
  end if;
  new.updated_by := coalesce(auth.uid(), new.updated_by);

  -- One spelling of each surface, once, in a fixed order.
  new.surfaces := array(
    select distinct s from unnest(new.surfaces) as s order by s);
  new.note := nullif(btrim(new.note), '');

  if tg_op = 'INSERT' or new.clinic_id is distinct from old.clinic_id then
    select t.chart_kind into v_kind
    from public.clinics c
    join public.clinic_types t on t.slug = c.type
    where c.id = new.clinic_id;
    if v_kind is distinct from 'dental' then
      raise exception 'This clinic does not keep a dental chart.';
    end if;
  end if;

  -- Work is done at a visit that actually happened.
  if new.status = 'done'
     and (tg_op = 'INSERT'
          or new.status is distinct from old.status
          or new.appointment_id is distinct from old.appointment_id) then
    select a.status into v_status
    from public.appointments a
    where a.id = new.appointment_id;
    if v_status is null
       or v_status not in ('arrived', 'in_consultation', 'completed') then
      raise exception 'Treatment can be recorded as done only at a visit the patient attended.';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.prepare_dental_entry() from public, anon, authenticated;

create trigger dental_chart_entries_prepare
  before insert or update on public.dental_chart_entries
  for each row execute function private.prepare_dental_entry();

-- ── 6. Row Level Security ───────────────────────────────────────────────────
-- Staff read; clinicians write. Deleting is allowed so a mistaken entry can be
-- taken back, but only by the people who could have written it.

alter table public.dental_chart_entries enable row level security;

create policy dental_chart_entries_select_staff on public.dental_chart_entries
  for select to authenticated using (private.is_clinic_staff(clinic_id));

create policy dental_chart_entries_insert_clinician on public.dental_chart_entries
  for insert to authenticated with check (private.is_clinician(clinic_id));

create policy dental_chart_entries_update_clinician on public.dental_chart_entries
  for update to authenticated
  using (private.is_clinician(clinic_id))
  with check (private.is_clinician(clinic_id));

create policy dental_chart_entries_delete_clinician on public.dental_chart_entries
  for delete to authenticated using (private.is_clinician(clinic_id));

-- ── 7. The patient's view ───────────────────────────────────────────────────
-- Their own chart, every column but the note. SECURITY DEFINER because
-- patients have no SELECT on the table; the WHERE is the whole access rule.

create or replace function public.patient_dental_chart(p_patient_id uuid)
returns table (
  id             uuid,
  appointment_id uuid,
  tooth          smallint,
  surfaces       text[],
  code           text,
  status         text,
  created_at     timestamptz,
  updated_at     timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.appointment_id, e.tooth, e.surfaces, e.code, e.status,
         e.created_at, e.updated_at
  from public.dental_chart_entries e
  where e.patient_id = p_patient_id
    and p_patient_id in (select private.my_patient_ids())
  order by e.created_at;
$$;

revoke all on function public.patient_dental_chart(uuid) from public, anon;
grant execute on function public.patient_dental_chart(uuid) to authenticated;
