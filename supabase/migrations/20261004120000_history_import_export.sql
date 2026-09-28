-- ============================================================================
-- health-platform · visit history and dental charts in and out as CSV
--
-- Step two and three after 20261003120000 (patients). A clinic moving onto the
-- platform brings its visit log and its charts; one already on it can take
-- them out again. Same rules as the patients file:
--
--   · the front desk and admins import and export visits; clinical notes
--     only for doctors and admins, as everywhere
--   · the dental chart is clinical, so only doctors and admins import it
--     (the front desk reads it, 20260925120000, and so may export it)
--   · no batch = a dry run, rolled back; undo_import takes a batch back
--
-- What a row points at is found here, not trusted from the file:
--   the patient   by chart id (as exported), chart number, or name plus
--                 phone or birthday — one patient, or the row is refused
--   the doctor    by id: the app matches the file's doctor names to the
--                 roster with the person importing, before the check
--   the service   by name among the clinic's services; any other name is
--                 kept as typed, like a service since retired
--
-- Past visits are HISTORY. They arrive already completed, cancelled or
-- no-show, which the status flow never allows a new visit to be, and they
-- do not take part in the double-booking rules: paper records put two
-- patients at "9:00", and a record of what happened is not a booking.
-- `appointments.imported` marks them, and only import_visits sets it.
-- Upcoming visits in a file are ordinary bookings, held to every rule.
--
-- Also: the patient search finds a chart by its number.
-- ============================================================================

-- ── 1. Imported history ────────────────────────────────────────────────────

alter table public.appointments
  add column imported boolean not null default false;

create or replace function private.guard_imported_visit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- import_visits runs as its owner; a signed-in client never does.
  if current_user = 'authenticated'
     and ((tg_op = 'INSERT' and new.imported)
          or (tg_op = 'UPDATE' and new.imported is distinct from old.imported)) then
    raise exception 'Only an import marks a visit as imported history.';
  end if;
  if tg_op = 'INSERT' and new.imported and new.scheduled_at > now() then
    raise exception 'Only a past visit is imported as history.';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_imported_visit() from public, anon, authenticated;

create trigger appointments_guard_imported
  before insert or update on public.appointments
  for each row execute function private.guard_imported_visit();

-- Same as 20260930120000, except that imported history starts over.
create or replace function private.guard_appointment_status()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_from text := case when tg_op = 'INSERT' then null else old.status::text end;
  v_to   text := new.status::text;
begin
  if tg_op = 'INSERT' then
    -- An imported past visit arrives already over (import_visits alone may
    -- set `imported`: see guard_imported_visit).
    if auth.uid() is not null and not new.imported
       and v_to not in ('pending', 'confirmed', 'arrived') then
      raise exception 'a new visit starts as pending, confirmed or arrived, not %', v_to;
    end if;
    if v_to = 'arrived' then new.arrived_at := coalesce(new.arrived_at, now()); end if;
    return new;
  end if;

  if v_from = v_to then
    return new;
  end if;

  if auth.uid() is not null and not private.is_clinic_admin(new.clinic_id) then
    if not private.is_clinic_staff(new.clinic_id) then
      -- A patient: the RLS policy has already pinned this to cancelling.
      if v_from not in ('pending', 'confirmed') then
        raise exception 'This visit can no longer be cancelled here. Please call the clinic.';
      end if;
    elsif not (
         (v_from = 'pending'   and v_to in ('confirmed', 'cancelled'))
      or (v_from = 'confirmed' and v_to in ('arrived', 'in_consultation', 'no_show', 'cancelled'))
      or (v_from = 'arrived'   and v_to in ('in_consultation', 'completed', 'cancelled'))
      or (v_from = 'in_consultation' and v_to = 'completed')
    ) then
      raise exception 'A % visit cannot become %.', replace(v_from, '_', ' '), replace(v_to, '_', ' ');
    elsif v_to = 'in_consultation' and not private.is_clinician(new.clinic_id) then
      raise exception 'Only a doctor or admin can start a consultation.';
    end if;
  end if;

  if v_to = 'no_show' and new.scheduled_at > now() then
    raise exception 'A visit can be marked as a no-show only once its time has come.';
  end if;

  case v_to
    when 'arrived' then
      new.arrived_at := now();
    when 'in_consultation' then
      new.arrived_at := coalesce(new.arrived_at, now());
      new.started_at := now();
    when 'completed' then
      new.arrived_at := coalesce(new.arrived_at, now());
      new.completed_at := now();
    else null;
  end case;
  return new;
end;
$$;

-- Same as 20260929120000, except that history is not a booking.
create or replace function private.set_appointment_times()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_moved boolean;
begin
  if new.service_id is not null
     and (tg_op = 'INSERT' or new.service_id is distinct from old.service_id) then
    select s.duration_minutes into new.duration_minutes
      from public.services s where s.id = new.service_id;
  end if;
  new.ends_at := new.scheduled_at + make_interval(mins => new.duration_minutes);

  -- History from a file: over before it arrived here, and a record of what
  -- happened, not a booking. Paper records put two patients at "9:00".
  if new.imported then
    return new;
  end if;

  if new.status in ('cancelled', 'no_show') then
    return new;
  end if;

  v_moved := tg_op = 'INSERT'
          or new.scheduled_at is distinct from old.scheduled_at
          or new.ends_at      is distinct from old.ends_at
          or old.status in ('cancelled', 'no_show');

  -- A readable refusal for the common case. The exclusion constraints
  -- still decide a race between two bookings in flight.
  if (v_moved or new.doctor_id is distinct from old.doctor_id)
     and exists (
       select 1 from public.appointments a
        where a.doctor_id = new.doctor_id
          and a.id <> new.id
          and a.status not in ('cancelled', 'no_show')
          and tstzrange(a.scheduled_at, a.ends_at) && tstzrange(new.scheduled_at, new.ends_at))
  then
    raise exception 'This doctor already has a visit at that time. Pick another time.'
      using errcode = '23P01';
  end if;

  if (v_moved or new.patient_id is distinct from old.patient_id)
     and exists (
       select 1 from public.appointments a
        where a.patient_id = new.patient_id
          and a.id <> new.id
          and a.status not in ('cancelled', 'no_show')
          and tstzrange(a.scheduled_at, a.ends_at) && tstzrange(new.scheduled_at, new.ends_at))
  then
    if new.patient_id in (select private.my_patient_ids()) then
      raise exception 'You already have a visit at that time. Pick another time.'
        using errcode = '23P01';
    end if;
    raise exception 'This patient already has a visit at that time. Pick another time.'
      using errcode = '23P01';
  end if;
  return new;
end;
$$;

alter table public.appointments
  drop constraint appointments_no_overlap,
  drop constraint appointments_no_patient_overlap;

alter table public.appointments
  add constraint appointments_no_overlap
    exclude using gist (doctor_id with =, tstzrange(scheduled_at, ends_at) with &&)
    where (status not in ('cancelled', 'no_show') and not imported),
  add constraint appointments_no_patient_overlap
    exclude using gist (patient_id with =, tstzrange(scheduled_at, ends_at) with &&)
    where (status not in ('cancelled', 'no_show') and not imported);

-- ── 2. Batches of every kind ───────────────────────────────────────────────

alter table public.import_batches
  drop constraint import_batches_kind_valid,
  add constraint import_batches_kind_valid check (kind in ('patients', 'visits', 'dental'));

alter table public.import_records
  drop constraint import_records_table_valid,
  add constraint import_records_table_valid
    check (table_name in ('persons', 'patients', 'invoices', 'appointments',
                          'dental_chart_entries'));

alter table public.data_exports
  drop constraint data_exports_kind_valid,
  add constraint data_exports_kind_valid check (kind in ('patients', 'visits', 'dental'));

create or replace function public.start_import(
  p_clinic_id uuid,
  p_kind      text,
  p_file_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not private.can_register_patients(p_clinic_id) then
    raise exception 'Only the front desk and admins can import.' using errcode = '42501';
  end if;
  if p_kind = 'dental' and not private.is_clinician(p_clinic_id) then
    raise exception 'Only doctors and admins can import dental charts.' using errcode = '42501';
  end if;
  insert into public.import_batches (clinic_id, kind, file_name, created_by)
  values (p_clinic_id, p_kind, btrim(coalesce(p_file_name, '')), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- The batch a chunk of rows is added to: this clinic's, this kind, started
-- by the caller, not undone.
create or replace function private.check_import_batch(p_batch_id uuid, p_clinic_id uuid, p_kind text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_batch_id is not null and not exists (
    select 1 from public.import_batches b
     where b.id = p_batch_id and b.clinic_id = p_clinic_id and b.kind = p_kind
       and b.created_by = auth.uid() and b.undone_at is null) then
    raise exception 'That import is not yours to add to, or was undone.' using errcode = '42501';
  end if;
end;
$$;

revoke all on function private.check_import_batch(uuid, uuid, text) from public, anon, authenticated;

-- ── 3. Which patient a row means ───────────────────────────────────────────
-- p_row's patient_id, chart_number, or patient_name with patient_phone and
-- patient_birthday. Exactly one chart at p_clinic_id, or a reason why not.

create or replace function private.import_find_patient(p_clinic_id uuid, p_row jsonb)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id     uuid;
  v_n      int;
  v_name   text := lower(btrim(p_row ->> 'patient_name'));
  v_digits text := private.local_digits(p_row ->> 'patient_phone');
  v_dob    date := nullif(p_row ->> 'patient_birthday', '')::date;
begin
  if nullif(p_row ->> 'patient_id', '') is not null then
    select pt.id into v_id from public.patients pt
     where pt.id = (p_row ->> 'patient_id')::uuid and pt.clinic_id = p_clinic_id;
    if v_id is null then
      raise exception 'Patient ID % is not a patient at this clinic.', p_row ->> 'patient_id';
    end if;
    return v_id;
  end if;

  if nullif(btrim(p_row ->> 'chart_number'), '') is not null then
    select pt.id into v_id from public.patients pt
     where pt.clinic_id = p_clinic_id
       and lower(pt.chart_number) = lower(btrim(p_row ->> 'chart_number'));
    if v_id is null then
      raise exception 'No patient here has chart number %.', btrim(p_row ->> 'chart_number');
    end if;
    return v_id;
  end if;

  if coalesce(v_name, '') = '' then
    raise exception 'The row does not say which patient: give a chart number or a name.';
  end if;

  select count(*), min(pt.id::text)::uuid into v_n, v_id
    from public.patients pt
    join public.persons pe on pe.id = pt.person_id
   where pt.clinic_id = p_clinic_id
     and lower(btrim(pe.full_name)) = v_name
     and (length(v_digits) < 7 or pe.phone is null or private.local_digits(pe.phone) = v_digits)
     and (v_dob is null or pe.date_of_birth is null or pe.date_of_birth = v_dob);
  if v_n = 0 then
    raise exception 'No patient here matches %. Import the patients first.', btrim(p_row ->> 'patient_name');
  elsif v_n > 1 then
    raise exception 'More than one patient here is called %. Add a chart number, phone or birthday to the row.',
      btrim(p_row ->> 'patient_name');
  end if;
  return v_id;
end;
$$;

revoke all on function private.import_find_patient(uuid, jsonb) from public, anon, authenticated;

-- ── 4. Importing visits ────────────────────────────────────────────────────
-- p_rows: one object per row of the file —
--   row, the patient (see 3), doctor_id, date (YYYY-MM-DD, the clinic's
--   day), time (HH:MM; 09:00 for a past visit without one), service,
--   duration_minutes (when the service is not one of the clinic's), status
--   (completed | cancelled | no_show for a past visit, the first by default;
--   pending | confirmed for an upcoming one, confirmed by default),
--   visit_note (clinicians), patient_note (the note to the patient;
--   clinicians).
-- Returns { row, result: created | skipped | error, appointment_id,
-- message, warnings } per row. A visit already on file (same patient, same
-- day, same service — and same time, when the file gives one) is skipped.

create or replace function public.import_visits(
  p_clinic_id uuid,
  p_rows      jsonb,
  p_batch_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dry       boolean := p_batch_id is null;
  v_clinician boolean := private.is_clinician(p_clinic_id);
  v_tz        text;
  v_results   jsonb := '[]'::jsonb;
  v_counts    int[] := array[0, 0, 0];  -- created, skipped, failed
  r           jsonb;
  v_row       int;
  v_patient   uuid;
  v_doctor    uuid;
  v_date      date;
  v_time      time;
  v_at        timestamptz;
  v_future    boolean;
  v_status    text;
  v_service   public.services;
  v_name      text;
  v_minutes   int;
  v_id        uuid;
  v_visit     text;
  v_pnote     text;
  v_warnings  jsonb;
  v_state     text;
  v_msg       text;
begin
  if not private.can_register_patients(p_clinic_id) then
    raise exception 'Only the front desk and admins can import.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Send at most 500 rows at a time.';
  end if;
  perform private.check_import_batch(p_batch_id, p_clinic_id, 'visits');
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  begin
    for r in select * from jsonb_array_elements(p_rows) loop
      v_row      := (r ->> 'row')::int;
      v_warnings := '[]'::jsonb;
      v_service  := null;

      if r ->> 'action' = 'skip' then
        v_results := v_results || jsonb_build_object('row', v_row, 'result', 'skipped');
        v_counts[2] := v_counts[2] + 1;
        continue;
      end if;

      begin
        v_patient := private.import_find_patient(p_clinic_id, r);

        select d.id into v_doctor from public.doctors d
         where d.id = nullif(r ->> 'doctor_id', '')::uuid and d.clinic_id = p_clinic_id;
        if v_doctor is null then
          raise exception 'Match this row''s doctor to one on the roster.';
        end if;

        v_date := nullif(r ->> 'date', '')::date;
        if v_date is null then
          raise exception 'The visit has no date.';
        end if;
        v_time   := nullif(r ->> 'time', '')::time;
        v_at     := (v_date + coalesce(v_time, time '09:00')) at time zone v_tz;
        v_future := v_at > now();
        if v_future and v_time is null then
          raise exception 'An upcoming visit needs a time.';
        end if;

        v_name := nullif(btrim(r ->> 'service'), '');
        if v_name is not null then
          select * into v_service from public.services s
           where s.clinic_id = p_clinic_id and lower(s.name) = lower(v_name)
           order by s.is_active desc
           limit 1;
        end if;
        if v_service.id is not null then
          v_name    := v_service.name;
          v_minutes := v_service.duration_minutes;
        else
          if v_name is null then
            v_name := 'Visit';
            v_warnings := v_warnings || to_jsonb('No service given: recorded as "Visit".'::text);
          end if;
          v_minutes := coalesce(nullif(r ->> 'duration_minutes', '')::int, 30);
          if v_minutes not between 5 and 480 then
            raise exception 'A visit lasts between 5 and 480 minutes.';
          end if;
        end if;

        -- Already on file: importing the same file twice adds nothing.
        if exists (
          select 1 from public.appointments a
           where a.patient_id = v_patient
             and (a.scheduled_at at time zone v_tz)::date = v_date
             and lower(a.service_name) = lower(v_name)
             and (v_time is null or a.scheduled_at = v_at)) then
          v_results := v_results || jsonb_build_object(
            'row', v_row, 'result', 'skipped', 'message', 'Already on file.');
          v_counts[2] := v_counts[2] + 1;
          continue;
        end if;

        v_status := nullif(r ->> 'status', '');
        if v_future then
          v_status := coalesce(v_status, 'confirmed');
          if v_status not in ('pending', 'confirmed') then
            raise exception 'An upcoming visit is Pending or Confirmed, not %.', replace(v_status, '_', ' ');
          end if;
        else
          v_status := coalesce(v_status, 'completed');
          if v_status not in ('completed', 'cancelled', 'no_show') then
            raise exception 'A past visit is Completed, Cancelled or No-show, not %.', replace(v_status, '_', ' ');
          end if;
        end if;

        v_visit := nullif(btrim(r ->> 'visit_note'), '');
        v_pnote := nullif(btrim(r ->> 'patient_note'), '');
        if not v_clinician and (v_visit is not null or v_pnote is not null) then
          v_warnings := v_warnings || to_jsonb('Visit notes were left out: only doctors and admins can add them.'::text);
          v_visit := null;
          v_pnote := null;
        end if;

        v_id := gen_random_uuid();
        insert into public.appointments (
          id, clinic_id, patient_id, doctor_id, service_id, service_name,
          scheduled_at, duration_minutes, status, patient_note, created_by, imported,
          arrived_at, started_at, completed_at)
        values (
          v_id, p_clinic_id, v_patient, v_doctor, v_service.id, v_name,
          v_at, v_minutes, v_status::public.appointment_status, v_pnote, auth.uid(),
          not v_future,
          case when v_status = 'completed' then v_at end,
          case when v_status = 'completed' then v_at end,
          case when v_status = 'completed' then v_at + make_interval(mins => v_minutes) end);

        if v_visit is not null then
          insert into public.visit_notes (appointment_id, clinic_id, body, updated_by)
          values (v_id, p_clinic_id, v_visit, auth.uid());
        end if;

        if not v_dry then
          insert into public.import_records values (p_batch_id, 'appointments', v_id, 'created');
        end if;
        v_results := v_results || jsonb_build_object(
          'row', v_row, 'result', 'created', 'appointment_id', v_id, 'warnings', v_warnings);
        v_counts[1] := v_counts[1] + 1;

      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
        v_results := v_results || jsonb_build_object(
          'row', v_row, 'result', 'error',
          'message', private.import_error_message(v_state, v_msg));
        v_counts[3] := v_counts[3] + 1;
      end;
    end loop;

    if v_dry then
      raise exception using errcode = 'HPDRY', message = 'dry run';
    end if;
  exception when sqlstate 'HPDRY' then
    null;
  end;

  if not v_dry then
    update public.import_batches set
      created_count = created_count + v_counts[1],
      skipped_count = skipped_count + v_counts[2],
      failed_count  = failed_count  + v_counts[3]
     where id = p_batch_id;
  end if;
  return v_results;
end;
$$;

-- ── 5. Importing dental charts ─────────────────────────────────────────────
-- p_rows: row, the patient (see 3), tooth (FDI), surfaces (['M','O',…]),
-- code, status (existing | planned | done), date (the visit it was found,
-- planned or done at), note.
--
-- Work done belongs to a visit the patient attended; the row's date finds
-- it. Without one — the visits were never logged — the work is recorded as
-- already there (an extraction as a missing tooth), with a warning, rather
-- than refused: it is on the chart either way. Conditions are always
-- findings. An entry already on the chart is skipped.

create or replace function public.import_dental(
  p_clinic_id uuid,
  p_rows      jsonb,
  p_batch_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dry       boolean := p_batch_id is null;
  v_tz        text;
  v_results   jsonb := '[]'::jsonb;
  v_counts    int[] := array[0, 0, 0];
  r           jsonb;
  v_row       int;
  v_patient   uuid;
  v_tooth     smallint;
  v_surfaces  text[];
  v_code      text;
  v_status    text;
  v_date      date;
  v_visit     uuid;
  v_at        timestamptz;
  v_id        uuid;
  v_warnings  jsonb;
  v_state     text;
  v_msg       text;
begin
  if not private.is_clinician(p_clinic_id) then
    raise exception 'Only doctors and admins can import dental charts.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Send at most 500 rows at a time.';
  end if;
  perform private.check_import_batch(p_batch_id, p_clinic_id, 'dental');
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  begin
    for r in select * from jsonb_array_elements(p_rows) loop
      v_row      := (r ->> 'row')::int;
      v_warnings := '[]'::jsonb;
      v_visit    := null;

      begin
        v_patient := private.import_find_patient(p_clinic_id, r);
        v_tooth   := (r ->> 'tooth')::smallint;
        if v_tooth is null or not private.is_fdi_tooth(v_tooth) then
          raise exception 'Tooth % is not a tooth number.', coalesce(r ->> 'tooth', '(blank)');
        end if;
        v_code := r ->> 'code';
        if v_code is null then
          raise exception 'The row does not say what was found or done.';
        end if;
        v_surfaces := coalesce(array(select jsonb_array_elements_text(r -> 'surfaces')), '{}');
        if v_code not in ('caries', 'fracture', 'filling', 'sealant', 'veneer') then
          v_surfaces := '{}';
        end if;
        v_date := nullif(r ->> 'date', '')::date;

        if v_date is not null then
          select a.id into v_visit from public.appointments a
           where a.patient_id = v_patient
             and (a.scheduled_at at time zone v_tz)::date = v_date
             and a.status in ('arrived', 'in_consultation', 'completed')
           order by a.scheduled_at
           limit 1;
        end if;

        v_status := nullif(r ->> 'status', '');
        if v_code in ('caries', 'fracture', 'missing', 'impacted', 'watch') then
          v_status := 'existing';
        elsif v_status is null then
          v_status := case when v_visit is not null then 'done' else 'existing' end;
        end if;
        if v_status = 'done' and v_visit is null then
          v_warnings := v_warnings || to_jsonb(case
            when v_date is null then 'No date, so no visit to record it at: recorded as work already there.'
            else 'No visit on ' || to_char(v_date, 'YYYY-MM-DD') || ', so it is recorded as work already there.'
          end);
          v_status := 'existing';
        end if;
        if v_code = 'extraction' and v_status = 'existing' then
          v_code := 'missing';
        end if;
        -- A plan belongs to the visit it was made at, when there was one.
        if v_status = 'existing' then
          v_visit := case when v_code in ('caries', 'fracture', 'missing', 'impacted', 'watch')
                          then v_visit end;
        end if;

        if exists (
          select 1 from public.dental_chart_entries e
           where e.patient_id = v_patient and e.tooth = v_tooth and e.code = v_code
             and e.status = v_status
             and e.surfaces = array(select distinct s from unnest(v_surfaces) s order by s)
             and e.appointment_id is not distinct from v_visit) then
          v_results := v_results || jsonb_build_object(
            'row', v_row, 'result', 'skipped', 'message', 'Already on the chart.');
          v_counts[2] := v_counts[2] + 1;
          continue;
        end if;

        -- Dated as found, so the chart's history reads in order.
        v_at := coalesce((v_date + time '12:00') at time zone v_tz, now());
        v_id := gen_random_uuid();
        insert into public.dental_chart_entries (
          id, clinic_id, patient_id, appointment_id, tooth, surfaces, code, status,
          note, created_at, updated_at)
        values (
          v_id, p_clinic_id, v_patient, v_visit, v_tooth, v_surfaces, v_code, v_status,
          r ->> 'note', v_at, v_at);

        if not v_dry then
          insert into public.import_records values (p_batch_id, 'dental_chart_entries', v_id, 'created');
        end if;
        v_results := v_results || jsonb_build_object(
          'row', v_row, 'result', 'created', 'warnings', v_warnings);
        v_counts[1] := v_counts[1] + 1;

      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
        v_results := v_results || jsonb_build_object(
          'row', v_row, 'result', 'error',
          'message', private.import_error_message(v_state, v_msg));
        v_counts[3] := v_counts[3] + 1;
      end;
    end loop;

    if v_dry then
      raise exception using errcode = 'HPDRY', message = 'dry run';
    end if;
  exception when sqlstate 'HPDRY' then
    null;
  end;

  if not v_dry then
    update public.import_batches set
      created_count = created_count + v_counts[1],
      skipped_count = skipped_count + v_counts[2],
      failed_count  = failed_count  + v_counts[3]
     where id = p_batch_id;
  end if;
  return v_results;
end;
$$;

-- More readable refusals for the new rows.
create or replace function private.import_error_message(p_state text, p_message text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_state = '23505' and p_message like '%patients_chart_number_key%'
      then 'That chart number is already used by another patient here.'
    when p_message like '%persons_sex_valid%'
      then 'Sex must be Female or Male.'
    when p_message like '%patients_chart_number_valid%'
      then 'A chart number is at most 40 characters.'
    when p_message like '%patient_intakes_guardian_relationship_valid%'
      then 'The guardian''s relationship must be Parent or Guardian.'
    when p_message like '%patient_intakes_allergies_known%'
      or p_message like '%patient_intakes_conditions_known%'
      then 'An allergy or condition is not one the form lists.'
    when p_message like '%dental_chart_entries_code_known%'
      then 'That is not something the dental chart records.'
    when p_message like '%dental_chart_entries_note_length%'
      then 'A chart note is at most 500 characters.'
    when p_message like '%dental_chart_entries_status_known%'
      then 'The status must be Existing, Planned or Done.'
    when p_message like '%dental_chart_entries_surfaces_known%'
      then 'Surfaces are M, O, D, B and L.'
    when p_state = '23P01' and p_message like '%exclusion constraint%'
      then 'The doctor or the patient already has a visit at that time.'
    when p_state in ('22007', '22008')
      then 'A date or time could not be read.'
    when p_state = '22003'
      then 'A number is too large.'
    when p_state = '22P02'
      then 'A value could not be read: ' || p_message
    else p_message
  end;
$$;

revoke all on function private.import_error_message(text, text) from public, anon, authenticated;

-- ── 6. Undo, for every kind ────────────────────────────────────────────────
-- All or nothing, and only while nothing has happened to what the batch
-- added:
--   patients   no visit, other bill, payment, dental chart or app account
--   visits     not changed since (status, time, reminder sent), no bill, no
--              dental chart entry
--   dental     not changed since

create or replace function public.undo_import(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch   public.import_batches;
  v_busy    int;
  v_removed int;
  v_kept    int := 0;
begin
  select * into v_batch from public.import_batches where id = p_batch_id for update;
  if not found or not private.can_register_patients(v_batch.clinic_id) then
    raise exception 'Import not found.' using errcode = 'P0002';
  end if;
  if not private.is_clinic_admin(v_batch.clinic_id)
     and v_batch.created_by is distinct from auth.uid() then
    raise exception 'Only an admin or whoever ran this import can undo it.' using errcode = '42501';
  end if;
  if v_batch.undone_at is not null then
    raise exception 'This import was already undone.';
  end if;

  if v_batch.kind = 'patients' then
    select count(*) into v_busy
      from public.import_records ir
      join public.patients pt on pt.id = ir.record_id
      join public.persons pe on pe.id = pt.person_id
     where ir.batch_id = p_batch_id and ir.table_name = 'patients' and ir.action = 'created'
       and (pe.profile_id is not null
            or exists (select 1 from public.appointments a where a.patient_id = pt.id)
            or exists (select 1 from public.dental_chart_entries d where d.patient_id = pt.id)
            or exists (select 1 from public.invoices v
                        where v.patient_id = pt.id
                          and not exists (select 1 from public.import_records r2
                                           where r2.batch_id = p_batch_id
                                             and r2.table_name = 'invoices'
                                             and r2.record_id = v.id))
            or exists (select 1 from public.payments p
                         join public.invoices v on v.id = p.invoice_id
                        where v.patient_id = pt.id));
    if v_busy > 0 then
      raise exception '% of the patients this import added have had visits, bills, payments or an app account since. Undo is only possible before that.',
        v_busy;
    end if;

    delete from public.invoices v
     using public.import_records ir
     where ir.batch_id = p_batch_id and ir.table_name = 'invoices' and v.id = ir.record_id;

    delete from public.patients pt
     using public.import_records ir
     where ir.batch_id = p_batch_id and ir.table_name = 'patients' and ir.action = 'created'
       and pt.id = ir.record_id;
    get diagnostics v_removed = row_count;

    delete from public.persons pe
     using public.import_records ir
     where ir.batch_id = p_batch_id and ir.table_name = 'persons' and ir.action = 'created'
       and pe.id = ir.record_id
       and pe.profile_id is null
       and not exists (select 1 from public.patients pt where pt.person_id = pe.id);

    select count(*) into v_kept from public.import_records ir
     where ir.batch_id = p_batch_id and ir.table_name = 'patients' and ir.action = 'updated';

  elsif v_batch.kind = 'visits' then
    select count(*) into v_busy
      from public.import_records ir
      join public.appointments a on a.id = ir.record_id
     where ir.batch_id = p_batch_id and ir.table_name = 'appointments'
       and (a.updated_at <> a.created_at
            or exists (select 1 from public.invoices v where v.appointment_id = a.id)
            or exists (select 1 from public.dental_chart_entries d where d.appointment_id = a.id));
    if v_busy > 0 then
      raise exception '% of the visits this import added have been changed, billed or charted since. Undo is only possible before that.',
        v_busy;
    end if;

    delete from public.appointments a
     using public.import_records ir
     where ir.batch_id = p_batch_id and ir.table_name = 'appointments' and a.id = ir.record_id;
    get diagnostics v_removed = row_count;

  else
    select count(*) into v_busy
      from public.import_records ir
      join public.dental_chart_entries d on d.id = ir.record_id
     where ir.batch_id = p_batch_id and ir.table_name = 'dental_chart_entries'
       and d.updated_at <> d.created_at;
    if v_busy > 0 then
      raise exception '% of the chart entries this import added have been changed since. Undo is only possible before that.',
        v_busy;
    end if;

    delete from public.dental_chart_entries d
     using public.import_records ir
     where ir.batch_id = p_batch_id and ir.table_name = 'dental_chart_entries'
       and d.id = ir.record_id;
    get diagnostics v_removed = row_count;
  end if;

  update public.import_batches
     set undone_at = now(), undone_by = auth.uid()
   where id = p_batch_id;

  return jsonb_build_object('removed', v_removed, 'kept_updates', v_kept);
end;
$$;

-- ── 7. Exporting visits and charts ─────────────────────────────────────────
-- The same columns an import takes, oldest first, a page at a time; SECURITY
-- INVOKER, so notes come back only for clinicians. The first page is logged.

create or replace function public.export_visits(
  p_clinic_id uuid,
  p_limit     int default 500,
  p_offset    int default 0
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tz  text;
  v_out jsonb;
begin
  if not private.can_register_patients(p_clinic_id) then
    raise exception 'Only the front desk and admins can export.' using errcode = '42501';
  end if;
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  if coalesce(p_offset, 0) = 0 then
    insert into public.data_exports (clinic_id, kind, row_count, created_by)
    select p_clinic_id, 'visits', count(*), auth.uid()
      from public.appointments a where a.clinic_id = p_clinic_id;
  end if;

  select coalesce(jsonb_agg(page.row order by page.scheduled_at, page.id), '[]'::jsonb)
    into v_out
    from (
      select a.scheduled_at, a.id, jsonb_build_object(
        'patient_id', pt.id,
        'chart_number', pt.chart_number,
        'patient_name', pe.full_name,
        'date', (a.scheduled_at at time zone v_tz)::date,
        'time', to_char(a.scheduled_at at time zone v_tz, 'HH24:MI'),
        'doctor', d.full_name,
        'service', a.service_name,
        'duration_minutes', a.duration_minutes,
        'status', a.status,
        'visit_note', n.body,
        'patient_note', a.patient_note
      ) as row
      from public.appointments a
      join public.patients pt on pt.id = a.patient_id
      join public.persons pe on pe.id = pt.person_id
      join public.doctors d on d.id = a.doctor_id
      left join public.visit_notes n on n.appointment_id = a.id
     where a.clinic_id = p_clinic_id
     order by a.scheduled_at, a.id
     limit least(greatest(coalesce(p_limit, 500), 1), 1000)
    offset greatest(coalesce(p_offset, 0), 0)
    ) page;
  return v_out;
end;
$$;

create or replace function public.export_dental(
  p_clinic_id uuid,
  p_limit     int default 500,
  p_offset    int default 0
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tz  text;
  v_out jsonb;
begin
  if not private.can_register_patients(p_clinic_id) then
    raise exception 'Only the front desk and admins can export.' using errcode = '42501';
  end if;
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  if coalesce(p_offset, 0) = 0 then
    insert into public.data_exports (clinic_id, kind, row_count, created_by)
    select p_clinic_id, 'dental', count(*), auth.uid()
      from public.dental_chart_entries e where e.clinic_id = p_clinic_id;
  end if;

  select coalesce(jsonb_agg(page.row order by page.sort_name, page.patient_id, page.tooth, page.created_at), '[]'::jsonb)
    into v_out
    from (
      select lower(pe.full_name) as sort_name, pt.id as patient_id, e.tooth, e.created_at,
        jsonb_build_object(
          'patient_id', pt.id,
          'chart_number', pt.chart_number,
          'patient_name', pe.full_name,
          'tooth', e.tooth,
          'surfaces', array_to_string(e.surfaces, ''),
          'code', e.code,
          'status', e.status,
          'date', (coalesce(a.scheduled_at, e.created_at) at time zone v_tz)::date,
          'note', e.note
        ) as row
      from public.dental_chart_entries e
      join public.patients pt on pt.id = e.patient_id
      join public.persons pe on pe.id = pt.person_id
      left join public.appointments a on a.id = e.appointment_id
     where e.clinic_id = p_clinic_id
     order by lower(pe.full_name), pt.id, e.tooth, e.created_at
     limit least(greatest(coalesce(p_limit, 500), 1), 1000)
    offset greatest(coalesce(p_offset, 0), 0)
    ) page;
  return v_out;
end;
$$;

-- ── 8. Finding a chart by its number ───────────────────────────────────────
-- Same as 20261002120000, plus the chart number.
create or replace function public.search_patients(
  p_clinic_id uuid,
  p_query     text    default null,
  p_limit     int     default 30,
  p_offset    int     default 0,
  p_filters   text[]  default null,
  p_sort      text    default 'name',
  p_desc      boolean default false
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (
    select
      -- LIKE wildcards in what someone typed are literal characters.
      replace(replace(replace(nullif(btrim(p_query), ''),
        '\', '\\'), '%', '\%'), '_', '\_')    as pattern,
      private.local_digits(p_query)            as digits,
      coalesce((select c.recall_months from public.clinics c
                 where c.id = p_clinic_id), 6) as recall_months
  ),
  matches as (
    select pt.id, pt, pe
    from public.patients pt
    join public.persons pe on pe.id = pt.person_id
    cross join q
    where pt.clinic_id = p_clinic_id
      and (q.pattern is null
           or pe.full_name ilike '%' || q.pattern || '%'
           or pe.email     ilike '%' || q.pattern || '%'
           or pt.chart_number ilike '%' || q.pattern || '%'
           -- Three digits before a number search kicks in: "1" matches
           -- everyone.
           or (length(q.digits) >= 3
               and private.local_digits(pe.phone) like '%' || q.digits || '%'))
  ),
  stats as (
    select
      m.id, m.pt, m.pe,
      v.completed_visits, v.first_visit_at, v.last_visit_at, v.next_visit_at,
      l.last_status, l.last_service, l.last_doctor,
      b.balance, b.oldest_unpaid_at,
      d.planned_count,
      case when (m.pe).date_of_birth is null then null
           else extract(year from age(current_date, (m.pe).date_of_birth))::int
      end as age
    from matches m
    cross join lateral (
      select
        count(*) filter (where a.status = 'completed')            as completed_visits,
        min(a.scheduled_at) filter (where a.status = 'completed')  as first_visit_at,
        max(a.scheduled_at) filter (where a.status = 'completed')  as last_visit_at,
        min(a.scheduled_at) filter (
          where a.scheduled_at > now()
            and a.status not in ('cancelled', 'no_show'))         as next_visit_at
      from public.appointments a
      where a.patient_id = m.id
    ) v
    -- How the most recent visit that is over turned out.
    left join lateral (
      select a.status, a.service_name, dr.full_name
      from public.appointments a
      join public.doctors dr on dr.id = a.doctor_id
      where a.patient_id = m.id
        and a.scheduled_at <= now()
        and a.status in ('completed', 'no_show')
      order by a.scheduled_at desc
      limit 1
    ) l (last_status, last_service, last_doctor) on true
    cross join lateral (
      select
        coalesce(sum(i.balance), 0)                                 as balance,
        min(coalesce(i.issued_at, i.created_at)) filter (where i.balance > 0)
                                                                    as oldest_unpaid_at
      from public.invoices i
      where i.patient_id = m.id and i.status = 'issued'
    ) b
    cross join lateral (
      select count(*) as planned_count
      from public.dental_chart_entries e
      where e.patient_id = m.id and e.status = 'planned'
    ) d
  ),
  attention as (
    select s.*,
      array_remove(array[
        case when s.planned_count > 0 and s.next_visit_at is null
             then 'unbooked_plan' end,
        case when s.last_status = 'no_show' then 'no_show' end,
        case when s.oldest_unpaid_at < now() - interval '30 days'
             then 'overdue_balance' end
      ], null) as reasons
    from stats s
  ),
  flagged as (
    select a.*,
      array_remove(array[
        case when a.last_visit_at < now() - make_interval(months => q.recall_months)
              and a.next_visit_at is null then 'recall' end,
        case when a.balance > 0 then 'balance' end,
        case when coalesce(btrim((a.pe).phone), '') = ''
              and coalesce(btrim((a.pe).email), '') = '' then 'no_contact' end,
        case when cardinality(a.reasons) > 0 then 'attention' end,
        case when a.age < 18 then 'pedia' when a.age >= 18 then 'adult' end
      ], null) as flags
    from attention a
    cross join q
  ),
  filtered as (
    select f.*,
      case coalesce(p_sort, 'name')
        when 'last_visit'  then extract(epoch from f.last_visit_at)
        when 'first_visit' then extract(epoch from f.first_visit_at)
        when 'next_visit'  then extract(epoch from f.next_visit_at)
        when 'balance'     then f.balance
        when 'visits'      then f.completed_visits::numeric
        when 'age'         then f.age::numeric
      end as sort_key
    from flagged f
    where p_filters is null or f.flags @> p_filters
  ),
  ordered as (
    select f.*,
      row_number() over (
        order by
          case when not coalesce(p_desc, false) then f.sort_key end asc nulls last,
          case when coalesce(p_desc, false)     then f.sort_key end desc nulls last,
          case when coalesce(p_desc, false) and coalesce(p_sort, 'name') = 'name'
               then lower((f.pe).full_name) end desc,
          lower((f.pe).full_name), f.id
      ) as rn
    from filtered f
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'counts', (
      select jsonb_build_object(
        'all',        count(*),
        'recall',     count(*) filter (where 'recall'     = any(flags)),
        'balance',    count(*) filter (where 'balance'    = any(flags)),
        'no_contact', count(*) filter (where 'no_contact' = any(flags)),
        'attention',  count(*) filter (where 'attention'  = any(flags)),
        'pedia',      count(*) filter (where 'pedia'      = any(flags)),
        'adult',      count(*) filter (where 'adult'      = any(flags)))
      from flagged),
    'patients', coalesce((
      select jsonb_agg(
        to_jsonb(o.pt)
          || jsonb_build_object(
               'person',             to_jsonb(o.pe),
               'completed_visits',   o.completed_visits,
               'first_visit_at',     o.first_visit_at,
               'last_visit_at',      o.last_visit_at,
               'next_visit_at',      o.next_visit_at,
               'last_visit_status',  o.last_status,
               'last_visit_service', o.last_service,
               'last_visit_doctor',  o.last_doctor,
               'balance',            o.balance,
               'planned_count',      o.planned_count,
               'age',                o.age,
               'flags',              to_jsonb(o.flags),
               'attention',          to_jsonb(o.reasons))
        order by o.rn)
      from ordered o
      where o.rn >  greatest(coalesce(p_offset, 0), 0)
        and o.rn <= greatest(coalesce(p_offset, 0), 0)
                    + greatest(1, least(coalesce(p_limit, 30), 100))), '[]'::jsonb));
$$;

revoke all on function public.import_visits(uuid, jsonb, uuid) from public, anon;
revoke all on function public.import_dental(uuid, jsonb, uuid) from public, anon;
revoke all on function public.export_visits(uuid, int, int) from public, anon;
revoke all on function public.export_dental(uuid, int, int) from public, anon;
grant execute on function public.import_visits(uuid, jsonb, uuid) to authenticated;
grant execute on function public.import_dental(uuid, jsonb, uuid) to authenticated;
grant execute on function public.export_visits(uuid, int, int) to authenticated;
grant execute on function public.export_dental(uuid, int, int) to authenticated;
