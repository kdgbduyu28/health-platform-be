-- ============================================================================
-- health-platform · audit log: who changed what, and when
--
-- Every insert, update and delete on a clinic's records leaves a row in
-- `audit_log`: which record, what it was before and after, who did it (and
-- in what role), and when. Written by triggers, so it covers every path in —
-- the apps, the RPCs, CSV imports and their undo, the cron jobs — and no
-- client can skip it.
--
-- What is logged:
--
--   patients & charts   patients, persons (identity/contact), patient_intakes,
--                       chart_notes, visit_notes, dental_chart_entries
--   visits              appointments
--   money               invoices, invoice_items, payments, expenses
--   the clinic          clinics, services, doctors, doctor_time_off,
--                       clinic_memberships, staff_invites
--
-- Not logged: notifications, push subscriptions, calendar tokens, staff PINs,
-- the import bookkeeping tables and the invoice counter — plumbing, not
-- records, and some of it secret.
--
-- An update stores only the fields that changed. A change that touches
-- nothing but bookkeeping (updated_at, the reminder stamp) is not logged at
-- all, so the nightly reminder job does not bury the real changes.
--
-- Who reads it: the clinic's admins (branch admins included, for their
-- branch). It holds old values of clinical notes and billing, so the front
-- desk and doctors do not; patients never. Nobody writes it but the triggers:
-- there is no INSERT/UPDATE/DELETE policy, and the privileges are revoked
-- too, so not even an admin can tidy up after themselves.
--
-- Persons are shared between clinics (20260914120100), so a change to one is
-- logged once per clinic that holds a chart for them — but only the clinics
-- the change is any of their business to: the one whose staff made it, or all
-- of them when the patient made it themself. Clinic A never learns the name
-- of the clinic B receptionist who fixed a phone number.
-- ============================================================================

create table public.audit_log (
  id          bigint generated always as identity primary key,
  -- No foreign keys: the log outlives what it describes. A deleted chart's
  -- history is exactly what someone will come looking for.
  clinic_id   uuid not null,
  -- The chart the change is about, when it is about one; the patient page
  -- reads its history by this.
  patient_id  uuid,
  table_name  text not null,
  row_id      text not null,
  action      text not null
    constraint audit_log_action_valid check (action in ('insert', 'update', 'delete')),
  -- insert: new only, the whole row. delete: old only, the whole row.
  -- update: both, with only the fields that changed.
  old_values  jsonb,
  new_values  jsonb,
  -- Null when no one was signed in: cron jobs, the service role, migrations.
  actor_id    uuid,
  -- As they were at the time; a later rename or removal does not rewrite it.
  actor_name  text,
  actor_role  text,
  -- Changes made in one go (a form, a completed visit and its bill, an
  -- import) share this, so they can be shown together.
  tx_id       bigint not null default txid_current(),
  created_at  timestamptz not null default now()
);

create index audit_log_clinic_idx  on public.audit_log (clinic_id, id desc);
create index audit_log_patient_idx on public.audit_log (patient_id, id desc)
  where patient_id is not null;
create index audit_log_row_idx     on public.audit_log (table_name, row_id);

alter table public.audit_log enable row level security;

create policy audit_log_select_admin on public.audit_log
  for select to authenticated
  using (private.is_clinic_admin(clinic_id));

revoke insert, update, delete, truncate on public.audit_log from public, anon, authenticated;

-- What the apps read: the log with the patient's name beside it. A chart
-- deleted since keeps the name its insert or delete recorded.
-- security_invoker, so the policy above still decides whose rows come back.
create view public.audit_entries
with (security_invoker = true) as
  select a.*,
         coalesce(pe.full_name,
                  a.old_values -> 'person' ->> 'full_name',
                  a.new_values -> 'person' ->> 'full_name') as patient_name
    from public.audit_log a
    left join public.patients pt on pt.id = a.patient_id
    left join public.persons pe on pe.id = pt.person_id;

revoke insert, update, delete, truncate on public.audit_entries from public, anon, authenticated;

-- ── Writing a row ───────────────────────────────────────────────────────────

-- Columns never worth a log line: bookkeeping, and the one secret.
create or replace function private.audit_skip_keys()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['created_at', 'updated_at', 'reminded_at',
               -- staff_invites.code: a live single-use code
               'code'];
$$;

create or replace function private.audit_write(
  p_clinic  uuid,
  p_patient uuid,
  p_table   text,
  p_row_id  text,
  p_action  text,
  p_old     jsonb,
  p_new     jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if p_clinic is null then
    return;
  end if;

  insert into public.audit_log (
    clinic_id, patient_id, table_name, row_id, action,
    old_values, new_values, actor_id, actor_name, actor_role)
  values (
    p_clinic, p_patient, p_table, p_row_id, p_action,
    p_old, p_new, v_actor,
    (select pr.full_name from public.profiles pr where pr.id = v_actor),
    coalesce(
      (select m.role::text from public.clinic_memberships m
        where m.profile_id = v_actor and m.clinic_id = p_clinic),
      (select 'patient' from public.patients pt
         join public.persons pe on pe.id = pt.person_id
        where pt.clinic_id = p_clinic and pe.profile_id = v_actor
        limit 1)));
end;
$$;

revoke all on function private.audit_write(uuid, uuid, text, text, text, jsonb, jsonb)
  from public, anon, authenticated;

-- The fields of an update that changed, as {"old": {...}, "new": {...}}, or
-- null when nothing did (once the skipped keys are left out).
create or replace function private.audit_diff(p_old jsonb, p_new jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when count(*) = 0 then null else jsonb_build_object(
           'old', jsonb_object_agg(k, p_old -> k),
           'new', jsonb_object_agg(k, p_new -> k)) end
    from jsonb_object_keys(p_new) as keys (k)
   where not k = any (private.audit_skip_keys())
     and (p_old -> k) is distinct from (p_new -> k);
$$;

-- A person's identity, to go with a chart's insert or delete: a chart row is
-- only ids, and "a patient was added" with no name says nothing.
create or replace function private.audit_person_snapshot(p_person uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(pe) - array['id', 'profile_id', 'created_at', 'updated_at']
    from public.persons pe where pe.id = p_person;
$$;

-- ── The trigger for clinic records ──────────────────────────────────────────
-- TG_ARGV[0] names the row's key column; almost always `id`.

create or replace function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_diff    jsonb;
  v_patient uuid;
begin
  if tg_op = 'UPDATE' then
    v_diff := private.audit_diff(v_old, v_new);
    if v_diff is null then
      return null;
    end if;
    v_old := v_diff -> 'old';
    v_new := v_diff -> 'new';
  else
    v_old := v_old - private.audit_skip_keys();
    v_new := v_new - private.audit_skip_keys();
  end if;

  v_patient := case
    when tg_table_name = 'patients' then (v_row ->> 'id')::uuid
    when v_row ? 'patient_id' then (v_row ->> 'patient_id')::uuid
    when tg_table_name = 'visit_notes' then
      (select a.patient_id from public.appointments a
        where a.id = (v_row ->> 'appointment_id')::uuid)
    when v_row ? 'invoice_id' then
      (select i.patient_id from public.invoices i
        where i.id = (v_row ->> 'invoice_id')::uuid)
  end;

  if tg_table_name = 'patients' and tg_op = 'INSERT' then
    v_new := v_new || jsonb_build_object('person',
      private.audit_person_snapshot((v_row ->> 'person_id')::uuid));
  elsif tg_table_name = 'patients' and tg_op = 'DELETE' then
    v_old := v_old || jsonb_build_object('person',
      private.audit_person_snapshot((v_row ->> 'person_id')::uuid));
  end if;

  perform private.audit_write(
    case when tg_table_name = 'clinics' then (v_row ->> 'id')::uuid
         else (v_row ->> 'clinic_id')::uuid end,
    v_patient,
    tg_table_name,
    v_row ->> tg_argv[0],
    lower(tg_op),
    v_old,
    v_new);
  return null;
end;
$$;

-- ── Persons: shared, so logged per clinic ──────────────────────────────────
-- Updates only. A person is created together with their first chart, and
-- that chart's insert carries who they are; staff cannot delete a person.

create or replace function private.audit_person()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_diff  jsonb := private.audit_diff(to_jsonb(old), to_jsonb(new));
  pt      record;
begin
  if v_diff is null then
    return null;
  end if;

  for pt in
    select p.id, p.clinic_id from public.patients p where p.person_id = new.id
  loop
    if v_actor is null
       or v_actor = new.profile_id
       or exists (select 1 from public.clinic_memberships m
                   where m.profile_id = v_actor and m.clinic_id = pt.clinic_id)
    then
      perform private.audit_write(pt.clinic_id, pt.id, 'persons', new.id::text,
                                  'update', v_diff -> 'old', v_diff -> 'new');
    end if;
  end loop;
  return null;
end;
$$;

-- Trigger functions: nobody calls these directly.
revoke all on function private.audit_row()    from public, anon, authenticated;
revoke all on function private.audit_person() from public, anon, authenticated;
revoke all on function private.audit_person_snapshot(uuid) from public, anon, authenticated;

-- ── Attach ──────────────────────────────────────────────────────────────────
-- AFTER triggers: they see the row as it was finally written, after every
-- BEFORE trigger (guards, stamps, totals) has had its say.

create trigger audit_patients after insert or update or delete on public.patients
  for each row execute function private.audit_row('id');
create trigger audit_persons after update on public.persons
  for each row execute function private.audit_person();
create trigger audit_patient_intakes after insert or update or delete on public.patient_intakes
  for each row execute function private.audit_row('patient_id');
create trigger audit_chart_notes after insert or update or delete on public.chart_notes
  for each row execute function private.audit_row('patient_id');
create trigger audit_visit_notes after insert or update or delete on public.visit_notes
  for each row execute function private.audit_row('appointment_id');
create trigger audit_dental_chart_entries after insert or update or delete on public.dental_chart_entries
  for each row execute function private.audit_row('id');
create trigger audit_appointments after insert or update or delete on public.appointments
  for each row execute function private.audit_row('id');
create trigger audit_invoices after insert or update or delete on public.invoices
  for each row execute function private.audit_row('id');
create trigger audit_invoice_items after insert or update or delete on public.invoice_items
  for each row execute function private.audit_row('id');
create trigger audit_payments after insert or update or delete on public.payments
  for each row execute function private.audit_row('id');
create trigger audit_expenses after insert or update or delete on public.expenses
  for each row execute function private.audit_row('id');
create trigger audit_clinics after update on public.clinics
  for each row execute function private.audit_row('id');
create trigger audit_services after insert or update or delete on public.services
  for each row execute function private.audit_row('id');
create trigger audit_doctors after insert or update or delete on public.doctors
  for each row execute function private.audit_row('id');
create trigger audit_doctor_time_off after insert or update or delete on public.doctor_time_off
  for each row execute function private.audit_row('id');
create trigger audit_clinic_memberships after insert or update or delete on public.clinic_memberships
  for each row execute function private.audit_row('profile_id');
create trigger audit_staff_invites after insert or update or delete on public.staff_invites
  for each row execute function private.audit_row('id');
