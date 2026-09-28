-- ============================================================================
-- health-platform · patients in and out as a spreadsheet (CSV)
--
-- A clinic moving onto the platform has its patients on paper forms and in a
-- spreadsheet; a clinic already on it wants its list out again, to keep or to
-- fix in bulk. Both go through the same columns: the patient information form
-- (persons + patient_intakes), the clinic's chart note, and an optional
-- balance the patient still owed under the old system. An exported file can
-- be edited and imported back.
--
-- Who: the front desk and admins (private.can_register_patients) — the
-- people who register patients. Clinical notes stay clinician-only, as
-- everywhere else (20260915120000): an assistant's export has no notes
-- column filled, and notes in an assistant's import are left out, with a
-- warning on the row.
--
-- Importing, in the app's words:
--
--   1. a dry run: import_patients without a batch. Every row is written and
--      checked by the real constraints, then the whole call is rolled back,
--      so the preview says exactly what the import will do.
--   2. start_import, then import_patients with that batch, a chunk of rows
--      at a time. Every row succeeds or fails on its own.
--   3. undo_import, if it went wrong: removes the patients the batch added,
--      as long as nothing has happened to them since.
--
-- Matching a row to a chart already here, in order:
--   patient_id     the chart id, as exported: an exported file comes back
--                  onto the same patients
--   chart_number   the clinic's own record number (new column below)
--   otherwise      a possible duplicate — same phone and the same name or
--                  birthday — is NOT written:
--                  (or the same name, and no phone or birthday that
--                  differs) — it comes back as 'duplicate' for a person to decide
--                  (action 'create' or 'update' with match_id).
--
-- An update fills in what the file has and leaves the rest: an empty cell
-- never blanks what is on file.
-- ============================================================================

-- ── 1. The clinic's own chart number ───────────────────────────────────────
-- Paper clinics number their folders. Kept as typed ("A-0042"), unique per
-- clinic regardless of case.

alter table public.patients
  add column chart_number text
    constraint patients_chart_number_valid
      check (chart_number = btrim(chart_number)
             and char_length(chart_number) between 1 and 40);

create unique index patients_chart_number_key
  on public.patients (clinic_id, lower(chart_number))
  where chart_number is not null;

-- ── 2. A form that came from a file ────────────────────────────────────────
-- Its own source, so the patient page can say where the answers came from.
-- private.valid_intake_source still refuses it: only import_patients writes
-- one.

alter table public.patient_intakes
  drop constraint patient_intakes_source_valid,
  add constraint patient_intakes_source_valid
    check (source in ('patient_app', 'front_desk_tablet', 'staff', 'import'));

-- ── 3. Batches, and what each one wrote ────────────────────────────────────
-- Written only by the functions below (no write policies): the record of
-- what a batch created is what undo deletes, so nobody may add to it.

create table public.import_batches (
  id            uuid primary key default gen_random_uuid(),
  clinic_id     uuid not null references public.clinics (id) on delete cascade,
  kind          text not null
    constraint import_batches_kind_valid check (kind in ('patients')),
  file_name     text not null
    constraint import_batches_file_name_valid
      check (char_length(btrim(file_name)) between 1 and 200),
  created_by    uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  created_count int not null default 0,
  updated_count int not null default 0,
  skipped_count int not null default 0,
  failed_count  int not null default 0,
  undone_at     timestamptz,
  undone_by     uuid references public.profiles (id) on delete set null
);

create index import_batches_clinic_idx on public.import_batches (clinic_id, created_at desc);

create table public.import_records (
  batch_id   uuid not null references public.import_batches (id) on delete cascade,
  table_name text not null
    constraint import_records_table_valid
      check (table_name in ('persons', 'patients', 'invoices')),
  record_id  uuid not null,
  action     text not null
    constraint import_records_action_valid check (action in ('created', 'updated')),
  primary key (batch_id, table_name, record_id)
);

-- ── 4. Exports, on record ──────────────────────────────────────────────────
-- A file of every patient's details leaves the system with no further
-- control over it (RA 10173). Admins can see who took one and when.

create table public.data_exports (
  id         uuid primary key default gen_random_uuid(),
  clinic_id  uuid not null references public.clinics (id) on delete cascade,
  kind       text not null
    constraint data_exports_kind_valid check (kind in ('patients')),
  row_count  int not null,
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index data_exports_clinic_idx on public.data_exports (clinic_id, created_at desc);

alter table public.import_batches enable row level security;
alter table public.import_records enable row level security;
alter table public.data_exports   enable row level security;

create policy import_batches_select_registrar on public.import_batches
  for select to authenticated using (private.can_register_patients(clinic_id));

create policy import_records_select_registrar on public.import_records
  for select to authenticated using (
    exists (select 1 from public.import_batches b
             where b.id = batch_id and private.can_register_patients(b.clinic_id)));

create policy data_exports_select_admin on public.data_exports
  for select to authenticated using (private.is_clinic_admin(clinic_id));

-- export_patients is SECURITY INVOKER (RLS decides what it reads), so the
-- log entry is an insert by the caller: as themself, at their clinic.
create policy data_exports_insert_registrar on public.data_exports
  for insert to authenticated with check (
    created_by = auth.uid() and private.can_register_patients(clinic_id));

-- ── 5. Starting an import ──────────────────────────────────────────────────

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
    raise exception 'Only the front desk and admins can import patients.' using errcode = '42501';
  end if;
  insert into public.import_batches (clinic_id, kind, file_name, created_by)
  values (p_clinic_id, p_kind, btrim(coalesce(p_file_name, '')), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- ── 6. Importing patients ──────────────────────────────────────────────────
-- p_rows: a JSON array, one object per row of the file:
--
--   row             the row's number in the file, echoed back
--   action          'auto' (default) | 'create' | 'update' | 'skip'
--   match_id        with 'update': the chart to update
--   patient_id      an exported chart id
--   chart_number
--   person          { full_name, phone, email, date_of_birth, sex, address,
--                     occupation, emergency_contact_name,
--                     emergency_contact_phone } — keys with a value only
--   intake          the form's answers, keyed as patient_intakes, plus
--                   signed_on (a date); null or {} when the file has none
--   chart_note      text for the clinic's chart note
--   opening_balance what the patient still owed before the import
--
-- Returns one object per row:
--   { row, result: created | updated | skipped | duplicate | error,
--     patient_id, match: {…} for a duplicate, message, warnings: [...] }
--
-- p_batch_id null is a dry run: everything is written, checked and rolled
-- back. Security definer, because what a batch writes must be recorded
-- where callers cannot write; every read and write below is pinned to
-- p_clinic_id, and the caller is checked first.

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
    when p_state in ('22007', '22008')
      then 'A date could not be read.'
    when p_state = '22003'
      then 'A number is too large.'
    when p_state = '22P02'
      then 'A value could not be read: ' || p_message
    else p_message
  end;
$$;

create or replace function public.import_patients(
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
  v_dry        boolean := p_batch_id is null;
  v_clinician  boolean := private.is_clinician(p_clinic_id);
  v_tz         text;
  v_results    jsonb := '[]'::jsonb;
  v_counts     int[] := array[0, 0, 0, 0];  -- created, updated, skipped, failed
  r            jsonb;
  v_row        int;
  v_action     text;
  v_person     jsonb;
  v_intake     jsonb;
  v_note       text;
  v_balance    numeric(12, 2);
  v_target     uuid;
  v_person_id  uuid;
  v_created    boolean;
  v_match      jsonb;
  v_warnings   jsonb;
  v_state      text;
  v_msg        text;
  pe           public.persons;
  v_existing   jsonb;
  v_signed_on  date;
  v_old_note   text;
  v_invoice_id uuid;
  v_chart_no   text;
  v_digits     text;
begin
  if not private.can_register_patients(p_clinic_id) then
    raise exception 'Only the front desk and admins can import patients.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Send at most 500 rows at a time.';
  end if;
  if not v_dry and not exists (
    select 1 from public.import_batches b
     where b.id = p_batch_id and b.clinic_id = p_clinic_id
       and b.created_by = auth.uid() and b.undone_at is null) then
    raise exception 'That import is not yours to add to, or was undone.' using errcode = '42501';
  end if;

  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  begin
    for r in select * from jsonb_array_elements(p_rows) loop
      v_row      := (r ->> 'row')::int;
      v_action   := coalesce(nullif(r ->> 'action', ''), 'auto');
      v_person   := coalesce(r -> 'person', '{}'::jsonb);
      v_intake   := nullif(r -> 'intake', 'null'::jsonb);
      v_note     := nullif(btrim(r ->> 'chart_note'), '');
      v_chart_no := nullif(btrim(r ->> 'chart_number'), '');
      v_target   := null;
      v_created  := false;
      v_match    := null;
      v_warnings := '[]'::jsonb;

      if v_action = 'skip' then
        v_results := v_results || jsonb_build_object('row', v_row, 'result', 'skipped');
        v_counts[3] := v_counts[3] + 1;
        continue;
      end if;

      begin
        if v_action not in ('auto', 'create', 'update') then
          raise exception 'Unknown action %.', v_action;
        end if;
        v_balance := nullif(r ->> 'opening_balance', '')::numeric(12, 2);
        if v_balance < 0 then
          raise exception 'An opening balance cannot be negative.';
        end if;

        -- ── Which chart ──
        if v_action = 'update' then
          select pt.id into v_target from public.patients pt
           where pt.id = (r ->> 'match_id')::uuid and pt.clinic_id = p_clinic_id;
          if v_target is null then
            raise exception 'The patient to update is not at this clinic.';
          end if;
        elsif v_action = 'auto' then
          if nullif(r ->> 'patient_id', '') is not null then
            select pt.id into v_target from public.patients pt
             where pt.id = (r ->> 'patient_id')::uuid and pt.clinic_id = p_clinic_id;
            if v_target is null then
              raise exception 'Patient ID % is not a patient at this clinic. Clear it to add them as new.',
                r ->> 'patient_id';
            end if;
          elsif v_chart_no is not null then
            select pt.id into v_target from public.patients pt
             where pt.clinic_id = p_clinic_id and lower(pt.chart_number) = lower(v_chart_no);
          end if;

          if v_target is null then
            v_digits := private.local_digits(v_person ->> 'phone');
            select jsonb_build_object(
                     'id', pt.id, 'full_name', x.full_name, 'phone', x.phone,
                     'date_of_birth', x.date_of_birth, 'chart_number', pt.chart_number)
              into v_match
              from public.patients pt
              join public.persons x on x.id = pt.person_id
             where pt.clinic_id = p_clinic_id
               and (
                 -- the same phone, and the same name or birthday
                 (length(v_digits) >= 7
                  and private.local_digits(x.phone) = v_digits
                  and (lower(btrim(x.full_name)) = lower(btrim(v_person ->> 'full_name'))
                       or x.date_of_birth = (v_person ->> 'date_of_birth')::date))
                 -- or the same name, with no phone or birthday that differs
                 or (lower(btrim(x.full_name)) = lower(btrim(v_person ->> 'full_name'))
                     and (length(v_digits) < 7 or x.phone is null
                          or private.local_digits(x.phone) = v_digits)
                     and (x.date_of_birth is null
                          or (v_person ->> 'date_of_birth') is null
                          or x.date_of_birth = (v_person ->> 'date_of_birth')::date)))
             order by pt.created_at
             limit 1;
            if v_match is not null then
              v_results := v_results || jsonb_build_object(
                'row', v_row, 'result', 'duplicate', 'match', v_match,
                'message', 'Looks like a patient already here.');
              v_counts[3] := v_counts[3] + 1;
              continue;
            end if;
          end if;
        end if;

        pe := jsonb_populate_record(null::public.persons, v_person);

        -- ── A new patient ──
        if v_target is null then
          if coalesce(btrim(pe.full_name), '') = '' then
            raise exception 'The patient''s name is missing.';
          end if;
          if coalesce(btrim(pe.phone), '') = '' then
            v_warnings := v_warnings || to_jsonb('No phone number: the front desk cannot call or match this patient by phone.'::text);
          end if;
          v_person_id := gen_random_uuid();
          v_target    := gen_random_uuid();
          insert into public.persons (
            id, full_name, phone, email, date_of_birth, sex, address, occupation,
            emergency_contact_name, emergency_contact_phone)
          values (
            v_person_id, btrim(pe.full_name), nullif(btrim(pe.phone), ''),
            nullif(btrim(pe.email), ''), pe.date_of_birth, pe.sex,
            nullif(btrim(pe.address), ''), nullif(btrim(pe.occupation), ''),
            nullif(btrim(pe.emergency_contact_name), ''),
            nullif(btrim(pe.emergency_contact_phone), ''));
          insert into public.patients (id, person_id, clinic_id, created_by, chart_number)
          values (v_target, v_person_id, p_clinic_id, auth.uid(), v_chart_no);
          v_created := true;
          if not v_dry then
            insert into public.import_records values
              (p_batch_id, 'persons',  v_person_id, 'created'),
              (p_batch_id, 'patients', v_target,    'created');
          end if;

        -- ── A patient already here: fill in what the file has ──
        else
          update public.persons x set
            full_name     = coalesce(nullif(btrim(pe.full_name), ''), x.full_name),
            phone         = coalesce(nullif(btrim(pe.phone), ''), x.phone),
            email         = coalesce(nullif(btrim(pe.email), ''), x.email),
            date_of_birth = coalesce(pe.date_of_birth, x.date_of_birth),
            sex           = coalesce(pe.sex, x.sex),
            address       = coalesce(nullif(btrim(pe.address), ''), x.address),
            occupation    = coalesce(nullif(btrim(pe.occupation), ''), x.occupation),
            emergency_contact_name  = coalesce(nullif(btrim(pe.emergency_contact_name), ''),
                                               x.emergency_contact_name),
            emergency_contact_phone = coalesce(nullif(btrim(pe.emergency_contact_phone), ''),
                                               x.emergency_contact_phone)
           from public.patients pt
          where pt.id = v_target and x.id = pt.person_id;
          if v_chart_no is not null then
            update public.patients set chart_number = v_chart_no
             where id = v_target and lower(chart_number) is distinct from lower(v_chart_no);
          end if;
          if not v_dry then
            insert into public.import_records values (p_batch_id, 'patients', v_target, 'updated')
            on conflict do nothing;
          end if;
        end if;

        -- ── The form ──
        -- The file's answers over what is on file, so a sheet with only a
        -- few form columns does not wipe the rest. The paper form was signed:
        -- the name it was signed with is the consent.
        if v_intake is not null and v_intake <> '{}'::jsonb then
          select to_jsonb(i) - array['consent_at', 'source', 'updated_by', 'created_at', 'updated_at']
            into v_existing
            from public.patient_intakes i where i.patient_id = v_target;
          v_intake := coalesce(v_existing, '{}'::jsonb) || v_intake;
          v_intake := v_intake || jsonb_build_object(
            'filled_by_guardian', nullif(btrim(v_intake ->> 'guardian_name'), '') is not null,
            'consent', true);
          if nullif(btrim(v_intake ->> 'signed_name'), '') is null then
            raise exception 'The form has no "Signed by": give the name it was signed with.';
          end if;
          if v_intake ->> 'under_treatment' is null or v_intake ->> 'takes_medications' is null then
            raise exception 'The form needs yes or no for "Under treatment" and "Takes medications".';
          end if;
          v_signed_on := nullif(v_intake ->> 'signed_on', '')::date;
          perform private.write_intake(v_target, p_clinic_id, v_intake, 'import');
          -- write_intake stamps now(); the paper form's date is truer.
          if v_signed_on is not null then
            update public.patient_intakes
               set consent_at = (v_signed_on + time '12:00') at time zone v_tz
             where patient_id = v_target;
          end if;
        end if;

        -- ── The chart note ──
        -- Added to what is on file, once: importing the same file again does
        -- not repeat it.
        if v_note is not null then
          if not v_clinician then
            v_warnings := v_warnings || to_jsonb('Clinic notes were left out: only doctors and admins can add them.'::text);
          else
            select n.body into v_old_note from public.chart_notes n where n.patient_id = v_target;
            if v_old_note is null then
              insert into public.chart_notes (patient_id, clinic_id, body, updated_by)
              values (v_target, p_clinic_id, v_note, auth.uid());
            elsif strpos(v_old_note, v_note) = 0 then
              update public.chart_notes
                 set body = case when btrim(v_old_note) = '' then v_note
                                 else btrim(v_old_note) || E'\n\n' || v_note end,
                     updated_by = auth.uid()
               where patient_id = v_target;
            end if;
          end if;
        end if;

        -- ── What they still owed ──
        -- An issued bill with one line, outside any visit. Only once per
        -- patient: a second import of the same file does not bill twice.
        if coalesce(v_balance, 0) > 0 then
          if exists (select 1 from public.invoices v
                      where v.patient_id = v_target and v.clinic_id = p_clinic_id
                        and v.appointment_id is null and v.status <> 'void'
                        and v.notes = 'Opening balance (imported)') then
            v_warnings := v_warnings || to_jsonb('Already has an imported opening balance; not added again.'::text);
          else
            insert into public.invoices (clinic_id, patient_id, notes, created_by)
            values (p_clinic_id, v_target, 'Opening balance (imported)', auth.uid())
            returning id into v_invoice_id;
            insert into public.invoice_items (invoice_id, clinic_id, description, unit_price)
            values (v_invoice_id, p_clinic_id, 'Opening balance', v_balance);
            perform public.issue_invoice(v_invoice_id);
            if not v_dry then
              insert into public.import_records values (p_batch_id, 'invoices', v_invoice_id, 'created');
            end if;
          end if;
        end if;

        v_results := v_results || jsonb_build_object(
          'row', v_row,
          'result', case when v_created then 'created' else 'updated' end,
          'patient_id', v_target,
          'warnings', v_warnings);
        if v_created then v_counts[1] := v_counts[1] + 1;
        else v_counts[2] := v_counts[2] + 1; end if;

      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
        v_results := v_results || jsonb_build_object(
          'row', v_row, 'result', 'error',
          'message', private.import_error_message(v_state, v_msg));
        v_counts[4] := v_counts[4] + 1;
      end;
    end loop;

    if v_dry then
      raise exception using errcode = 'HPDRY', message = 'dry run';
    end if;
  exception when sqlstate 'HPDRY' then
    -- Everything the rows wrote is rolled back; the results are not.
    null;
  end;

  if not v_dry then
    update public.import_batches set
      created_count = created_count + v_counts[1],
      updated_count = updated_count + v_counts[2],
      skipped_count = skipped_count + v_counts[3],
      failed_count  = failed_count  + v_counts[4]
     where id = p_batch_id;
  end if;

  return v_results;
end;
$$;

-- ── 7. Undoing an import ───────────────────────────────────────────────────
-- Removes the patients the batch added — their charts, forms, notes and
-- opening balances, and the person when no other chart holds them — as long
-- as nothing has happened to any of them since: no visit, no other bill, no
-- payment, no dental chart, no app account. All or nothing.
--
-- Changes the batch made to patients already here are NOT undone; the app
-- says so before asking. The admin, or whoever ran the import, may undo it.

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
  v_kept    int;
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

  update public.import_batches
     set undone_at = now(), undone_by = auth.uid()
   where id = p_batch_id;

  return jsonb_build_object('removed', v_removed, 'kept_updates', v_kept);
end;
$$;

-- ── 8. Exporting patients ──────────────────────────────────────────────────
-- One page of the clinic's patients, by name, with the same fields an import
-- takes plus a few to read (balance, visits). SECURITY INVOKER: RLS decides,
-- so the chart note is there for doctors and admins and null for the front
-- desk, exactly as in the app. The first page puts the export on record.

create or replace function public.export_patients(
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
    raise exception 'Only the front desk and admins can export patients.' using errcode = '42501';
  end if;
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  if coalesce(p_offset, 0) = 0 then
    insert into public.data_exports (clinic_id, kind, row_count, created_by)
    select p_clinic_id, 'patients', count(*), auth.uid()
      from public.patients pt where pt.clinic_id = p_clinic_id;
  end if;

  select coalesce(jsonb_agg(page.row order by page.sort_name, page.id), '[]'::jsonb)
    into v_out
    from (
      select lower(pe.full_name) as sort_name, pt.id, jsonb_build_object(
        'patient_id', pt.id,
        'chart_number', pt.chart_number,
        'full_name', pe.full_name,
        'phone', pe.phone,
        'email', pe.email,
        'date_of_birth', pe.date_of_birth,
        'sex', pe.sex,
        'address', pe.address,
        'occupation', pe.occupation,
        'emergency_contact_name', pe.emergency_contact_name,
        'emergency_contact_phone', pe.emergency_contact_phone,
        'intake', case when i.patient_id is null then null else
          (to_jsonb(i) - array['patient_id', 'clinic_id', 'updated_by', 'created_at',
                               'updated_at', 'consent_at'])
          || jsonb_build_object('signed_on', (i.consent_at at time zone v_tz)::date) end,
        'chart_note', n.body,
        'balance', (select coalesce(sum(v.balance), 0) from public.invoices v
                     where v.patient_id = pt.id and v.status = 'issued'),
        'completed_visits', (select count(*) from public.appointments a
                              where a.patient_id = pt.id and a.status = 'completed'),
        'last_visit', (select max((a.scheduled_at at time zone v_tz)::date)
                         from public.appointments a
                        where a.patient_id = pt.id and a.status = 'completed'),
        'registered_on', (pt.created_at at time zone v_tz)::date
      ) as row
      from public.patients pt
      join public.persons pe on pe.id = pt.person_id
      left join public.patient_intakes i on i.patient_id = pt.id
      left join public.chart_notes n on n.patient_id = pt.id
     where pt.clinic_id = p_clinic_id
     order by lower(pe.full_name), pt.id
     limit least(greatest(coalesce(p_limit, 500), 1), 1000)
    offset greatest(coalesce(p_offset, 0), 0)
    ) page;

  return v_out;
end;
$$;

revoke all on function public.start_import(uuid, text, text) from public, anon;
revoke all on function public.import_patients(uuid, jsonb, uuid) from public, anon;
revoke all on function public.undo_import(uuid) from public, anon;
revoke all on function public.export_patients(uuid, int, int) from public, anon;
revoke all on function private.import_error_message(text, text) from public, anon, authenticated;
grant execute on function public.start_import(uuid, text, text) to authenticated;
grant execute on function public.import_patients(uuid, jsonb, uuid) to authenticated;
grant execute on function public.undo_import(uuid) to authenticated;
grant execute on function public.export_patients(uuid, int, int) to authenticated;
