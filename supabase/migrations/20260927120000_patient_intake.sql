-- ============================================================================
-- health-platform · the patient information form, and the front desk tablet
--
-- A clinic's first visit starts with a form: who you are, who to call in an
-- emergency, and the medical history every treatment has to know about. Until
-- now a patient could only be created as a side effect of booking (walk-in,
-- record missed visit), with a name and a phone number, and there was nowhere
-- to put medications or allergies except the clinicians' free-text chart note.
--
-- The form is filled in one of three ways, all ending in the same rows:
--
--   · the front desk types it in                 (source 'staff')
--   · the front desk hands the tablet over, and  (source 'front_desk_tablet')
--     the patient types it in themselves
--   · the patient fills it in on the patient     (source 'patient_app')
--     app, right after joining the clinic
--
-- Where the answers live:
--
--   persons           identity + contact, shared by every clinic that treats
--                     the person (the columns added below)
--   patient_intakes   the medical history and consent, one per CHART — so a
--                     person with charts at two clinics has told each clinic
--                     separately, and neither can read the other's answers
--
-- Who may read an intake: the patient, and every staff member of the chart's
-- clinic. Unlike chart_notes (clinicians only, 20260915120000) the front desk
-- sees it too, by the clinic's decision: they are the ones taking the form
-- back from the patient and flagging "has allergies" at the desk.
--
-- The tablet hand-off needs a way back that the patient does not have: a
-- 4-digit staff PIN, per account, checked here (staff_pins).
-- ============================================================================

-- ── 1. More about the person ────────────────────────────────────────────────
-- All nullable: walk-ins and self-signups created before this form existed
-- have none of it, and the form, not the table, is where they get asked.

alter table public.persons
  add column sex                     text
    constraint persons_sex_valid check (sex in ('female', 'male')),
  add column address                 text,
  add column occupation              text,
  add column emergency_contact_name  text,
  add column emergency_contact_phone text;

-- ── 2. The intake ───────────────────────────────────────────────────────────

-- The allergy and condition checklists the form offers. Kept here as the one
-- list the table accepts; the apps' `IntakeAllergy` / `IntakeCondition` enums
-- mirror them. Anything else goes in the *_other free text.
create or replace function private.intake_allergies()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['local_anesthetic', 'penicillin', 'other_antibiotics',
               'sulfa', 'aspirin', 'latex'];
$$;

create or replace function private.intake_conditions()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['high_blood_pressure', 'low_blood_pressure', 'heart_disease',
               'diabetes', 'asthma', 'bleeding_disorder', 'anemia',
               'hepatitis', 'kidney_disease', 'thyroid_problem', 'epilepsy',
               'stroke', 'cancer', 'tuberculosis'];
$$;

create table public.patient_intakes (
  patient_id         uuid primary key,
  clinic_id          uuid not null,

  reason_for_visit   text,
  -- Free text on purpose: "about two years ago" is the usual answer.
  last_dental_visit  text,
  physician_name     text,

  under_treatment    boolean not null,
  treatment_details  text,
  takes_medications  boolean not null,
  medications        text,

  allergies          text[] not null default '{}'
    constraint patient_intakes_allergies_known
      check (allergies <@ private.intake_allergies()),
  allergies_other    text,
  conditions         text[] not null default '{}'
    constraint patient_intakes_conditions_known
      check (conditions <@ private.intake_conditions()),
  conditions_other   text,

  -- Asked only of women; null means not asked.
  pregnant           boolean,
  nursing            boolean,
  birth_control      boolean,

  -- Consent to processing health data (RA 10173). Stamped by the functions
  -- below on every save: whoever changes the answers re-confirms it.
  consent_at         timestamptz not null,
  signed_name        text not null
    constraint patient_intakes_signed check (btrim(signed_name) <> ''),

  source             text not null
    constraint patient_intakes_source_valid
      check (source in ('patient_app', 'front_desk_tablet', 'staff')),
  updated_by         uuid references public.profiles (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  -- Same pinning as chart_notes: an intake cannot sit on another clinic's
  -- chart. This is the only FK to patients, so `intake:patient_intakes(*)`
  -- embeds without PGRST201.
  constraint patient_intakes_chart_matches_clinic
    foreign key (patient_id, clinic_id)
    references public.patients (id, clinic_id)
    on delete cascade
);

create index patient_intakes_clinic_idx on public.patient_intakes (clinic_id);

create trigger patient_intakes_set_updated_at
  before update on public.patient_intakes
  for each row execute function public.set_updated_at();

alter table public.patient_intakes enable row level security;

create policy patient_intakes_select_own on public.patient_intakes
  for select to authenticated
  using (patient_id in (select private.my_patient_ids()));

create policy patient_intakes_select_staff on public.patient_intakes
  for select to authenticated
  using (private.is_clinic_staff(clinic_id));

create policy patient_intakes_insert_own on public.patient_intakes
  for insert to authenticated
  with check (patient_id in (select private.my_patient_ids()));

create policy patient_intakes_insert_staff on public.patient_intakes
  for insert to authenticated
  with check (private.is_clinic_staff(clinic_id));

create policy patient_intakes_update_own on public.patient_intakes
  for update to authenticated
  using (patient_id in (select private.my_patient_ids()))
  with check (patient_id in (select private.my_patient_ids()));

create policy patient_intakes_update_staff on public.patient_intakes
  for update to authenticated
  using (private.is_clinic_staff(clinic_id))
  with check (private.is_clinic_staff(clinic_id));

-- No delete: a form is corrected, not withdrawn. Deleting the chart removes it.

-- ── 3. Writing the form ─────────────────────────────────────────────────────
-- Both functions are SECURITY INVOKER, like book_walk_in: the policies above
-- and on persons/patients decide who may do what, and the functions only make
-- it one transaction and one shape.
--
-- The answers arrive as JSON objects keyed by column name. Unknown keys are
-- ignored, and the columns the caller must not choose (clinic, who, when) are
-- never read from them.

-- Writes the intake for a chart the caller can already see.
create or replace function private.write_intake(
  p_patient_id uuid,
  p_clinic_id  uuid,
  p_intake     jsonb,
  p_source     text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r public.patient_intakes;
begin
  if coalesce((p_intake ->> 'consent')::boolean, false) is not true then
    raise exception 'the patient must agree to the privacy consent';
  end if;

  r := jsonb_populate_record(null::public.patient_intakes, p_intake);

  if r.under_treatment is null or r.takes_medications is null then
    raise exception 'answer whether the patient is under treatment and takes medications';
  end if;

  insert into public.patient_intakes as i (
    patient_id, clinic_id, reason_for_visit, last_dental_visit, physician_name,
    under_treatment, treatment_details, takes_medications, medications,
    allergies, allergies_other, conditions, conditions_other,
    pregnant, nursing, birth_control,
    consent_at, signed_name, source, updated_by)
  values (
    p_patient_id, p_clinic_id,
    nullif(btrim(r.reason_for_visit), ''),
    nullif(btrim(r.last_dental_visit), ''),
    nullif(btrim(r.physician_name), ''),
    r.under_treatment,
    case when r.under_treatment then nullif(btrim(r.treatment_details), '') end,
    r.takes_medications,
    case when r.takes_medications then nullif(btrim(r.medications), '') end,
    coalesce(r.allergies, '{}'),
    nullif(btrim(r.allergies_other), ''),
    coalesce(r.conditions, '{}'),
    nullif(btrim(r.conditions_other), ''),
    r.pregnant, r.nursing, r.birth_control,
    now(), btrim(coalesce(r.signed_name, '')), p_source, auth.uid())
  on conflict (patient_id) do update set
    reason_for_visit  = excluded.reason_for_visit,
    last_dental_visit = excluded.last_dental_visit,
    physician_name    = excluded.physician_name,
    under_treatment   = excluded.under_treatment,
    treatment_details = excluded.treatment_details,
    takes_medications = excluded.takes_medications,
    medications       = excluded.medications,
    allergies         = excluded.allergies,
    allergies_other   = excluded.allergies_other,
    conditions        = excluded.conditions,
    conditions_other  = excluded.conditions_other,
    pregnant          = excluded.pregnant,
    nursing           = excluded.nursing,
    birth_control     = excluded.birth_control,
    consent_at        = excluded.consent_at,
    signed_name       = excluded.signed_name,
    source            = excluded.source,
    updated_by        = excluded.updated_by;
end;
$$;

revoke all on function private.write_intake(uuid, uuid, jsonb, text) from public, anon;
grant execute on function private.write_intake(uuid, uuid, jsonb, text) to authenticated;

create or replace function private.valid_intake_source(p_source text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_source is null
     or p_source not in ('patient_app', 'front_desk_tablet', 'staff') then
    raise exception 'unknown form source %', coalesce(p_source, 'null');
  end if;
  return p_source;
end;
$$;

grant execute on function private.valid_intake_source(text) to authenticated;

-- A new patient, from the front desk: the person, their chart here, and —
-- when given — the intake, in one go. Returns the chart id.
--
-- The phone is required, as for walk-ins: it is how the desk finds a patient
-- again and spots a duplicate. Everything else about the person is optional
-- here; the form asks for more.
create or replace function public.register_patient(
  p_clinic_id uuid,
  p_person    jsonb,
  p_intake    jsonb default null,
  p_source    text  default 'staff'
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_person_id  uuid := gen_random_uuid();
  v_patient_id uuid := gen_random_uuid();
  v_source     text := private.valid_intake_source(p_source);
  pe           public.persons;
begin
  if v_source = 'patient_app' then
    raise exception 'patients join a clinic with its code, not by registering';
  end if;

  pe := jsonb_populate_record(null::public.persons, p_person);
  if coalesce(btrim(pe.full_name), '') = '' then
    raise exception 'patient name is required';
  end if;
  if coalesce(btrim(pe.phone), '') = '' then
    raise exception 'patient phone is required';
  end if;

  -- No RETURNING: a person with no chart yet is not readable by the staff
  -- member creating them (see private.staff_can_access_person).
  insert into public.persons (
    id, full_name, phone, email, date_of_birth, sex, address, occupation,
    emergency_contact_name, emergency_contact_phone)
  values (
    v_person_id, btrim(pe.full_name), btrim(pe.phone),
    nullif(btrim(pe.email), ''), pe.date_of_birth, pe.sex,
    nullif(btrim(pe.address), ''), nullif(btrim(pe.occupation), ''),
    nullif(btrim(pe.emergency_contact_name), ''),
    nullif(btrim(pe.emergency_contact_phone), ''));

  -- RLS requires a clinic the caller registers patients at.
  insert into public.patients (id, person_id, clinic_id, created_by)
  values (v_patient_id, v_person_id, p_clinic_id, auth.uid());

  if p_intake is not null then
    perform private.write_intake(v_patient_id, p_clinic_id, p_intake, v_source);
  end if;

  return v_patient_id;
end;
$$;

-- The form for an existing chart: the patient's own (patient app), or one at
-- the caller's clinic (front desk, typed or on the tablet). Updates the
-- person and writes the intake together.
--
-- Only keys present in p_person are changed, so a form that does not ask for
-- something cannot blank it. The name cannot be blanked at all.
create or replace function public.save_patient_intake(
  p_patient_id uuid,
  p_person     jsonb,
  p_intake     jsonb,
  p_source     text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_source    text := private.valid_intake_source(p_source);
  v_clinic_id uuid;
  v_person_id uuid;
  pe          public.persons;
  v_updated   int;
begin
  select pt.clinic_id, pt.person_id into v_clinic_id, v_person_id
    from public.patients pt
   where pt.id = p_patient_id;
  if v_clinic_id is null then
    raise exception 'no such patient';
  end if;

  -- The source says who typed it: the patient app is only ever the patient
  -- themself, and the other two are only ever this clinic's front desk. RLS
  -- would allow either party either way; this keeps the label honest.
  if v_source = 'patient_app' then
    if p_patient_id not in (select private.my_patient_ids()) then
      raise exception 'only the patient can fill in their form in the patient app';
    end if;
  elsif not private.is_clinic_staff(v_clinic_id) then
    raise exception 'only this clinic''s staff can fill in a patient''s form';
  end if;

  if p_person is not null and p_person <> '{}'::jsonb then
    pe := jsonb_populate_record(null::public.persons, p_person);
    if p_person ? 'full_name' and coalesce(btrim(pe.full_name), '') = '' then
      raise exception 'patient name is required';
    end if;

    update public.persons set
      full_name     = case when p_person ? 'full_name' then btrim(pe.full_name) else full_name end,
      phone         = case when p_person ? 'phone' then nullif(btrim(pe.phone), '') else phone end,
      email         = case when p_person ? 'email' then nullif(btrim(pe.email), '') else email end,
      date_of_birth = case when p_person ? 'date_of_birth' then pe.date_of_birth else date_of_birth end,
      sex           = case when p_person ? 'sex' then pe.sex else sex end,
      address       = case when p_person ? 'address' then nullif(btrim(pe.address), '') else address end,
      occupation    = case when p_person ? 'occupation' then nullif(btrim(pe.occupation), '') else occupation end,
      emergency_contact_name  = case when p_person ? 'emergency_contact_name'
                                     then nullif(btrim(pe.emergency_contact_name), '')
                                     else emergency_contact_name end,
      emergency_contact_phone = case when p_person ? 'emergency_contact_phone'
                                     then nullif(btrim(pe.emergency_contact_phone), '')
                                     else emergency_contact_phone end
     where id = v_person_id;

    -- An RLS-filtered update is silent; say so instead of pretending.
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
      raise exception 'you cannot change this patient''s details';
    end if;
  end if;

  perform private.write_intake(p_patient_id, v_clinic_id, p_intake, v_source);
end;
$$;

revoke all on function public.register_patient(uuid, jsonb, jsonb, text) from public, anon;
revoke all on function public.save_patient_intake(uuid, jsonb, jsonb, text) from public, anon;
grant execute on function public.register_patient(uuid, jsonb, jsonb, text) to authenticated;
grant execute on function public.save_patient_intake(uuid, jsonb, jsonb, text) to authenticated;

-- ── 4. Staff PIN, for taking the tablet back ────────────────────────────────
-- While a patient fills in the form on the front desk tablet, the app is still
-- signed in as the staff member. The PIN is what separates "hand it back" from
-- "browse the clinic's patients": the app will not leave the form without it.
--
-- One PIN per account, not per clinic: it unlocks this device's session,
-- which is the account's. Four digits are few, so the defence is the attempt
-- limit, not the hash: after 5 wrong tries the PIN is refused for 5 minutes.
-- A hash nobody can read (no SELECT policy, functions only) is enough; bcrypt
-- over 10^4 PINs would not buy anything a stolen table would not already give
-- away. sha256 is built in, so no extension schema has to be named from a
-- function pinned to search_path = ''.

create table public.staff_pins (
  profile_id      uuid primary key references public.profiles (id) on delete cascade,
  salt            text not null,
  pin_hash        text not null,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  updated_at      timestamptz not null default now()
);

alter table public.staff_pins enable row level security;
-- No policies: only the functions below touch it.

create or replace function private.hash_pin(p_salt text, p_pin text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p_salt || ':' || p_pin, 'UTF8')), 'hex');
$$;

revoke all on function private.hash_pin(text, text) from public, anon, authenticated;

create or replace function public.has_staff_pin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.staff_pins where profile_id = auth.uid());
$$;

create or replace function public.set_staff_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_salt text := replace(gen_random_uuid()::text, '-', '');
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clinic_memberships m
                 where m.profile_id = auth.uid()) then
    raise exception 'only clinic staff have a staff PIN';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'the PIN must be 4 digits';
  end if;

  insert into public.staff_pins (profile_id, salt, pin_hash)
  values (auth.uid(), v_salt, private.hash_pin(v_salt, p_pin))
  on conflict (profile_id) do update set
    salt = excluded.salt,
    pin_hash = excluded.pin_hash,
    failed_attempts = 0,
    locked_until = null,
    updated_at = now();
end;
$$;

-- True when p_pin is the caller's PIN. A wrong PIN returns false rather than
-- raising, so the attempt count it records is not rolled back with the error.
create or replace function public.verify_staff_pin(p_pin text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.staff_pins;
begin
  select * into p from public.staff_pins where profile_id = auth.uid();
  if p.profile_id is null then
    raise exception 'set a staff PIN first';
  end if;
  if p.locked_until > now() then
    raise exception 'too many wrong PINs; try again in % min',
      ceil(extract(epoch from p.locked_until - now()) / 60)::int;
  end if;

  if private.hash_pin(p.salt, coalesce(p_pin, '')) = p.pin_hash then
    update public.staff_pins
       set failed_attempts = 0, locked_until = null
     where profile_id = p.profile_id;
    return true;
  end if;

  update public.staff_pins
     set failed_attempts = case when p.failed_attempts + 1 >= 5 then 0
                                else p.failed_attempts + 1 end,
         locked_until    = case when p.failed_attempts + 1 >= 5
                                then now() + interval '5 minutes' end
   where profile_id = p.profile_id;
  return false;
end;
$$;

revoke all on function public.has_staff_pin()        from public, anon;
revoke all on function public.set_staff_pin(text)    from public, anon;
revoke all on function public.verify_staff_pin(text) from public, anon;
grant execute on function public.has_staff_pin()        to authenticated;
grant execute on function public.set_staff_pin(text)    to authenticated;
grant execute on function public.verify_staff_pin(text) to authenticated;
