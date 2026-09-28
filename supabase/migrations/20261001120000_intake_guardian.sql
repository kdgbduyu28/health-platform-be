-- ============================================================================
-- health-platform · a parent or guardian filling in the form
--
-- Children, and adults who cannot answer for themselves, do not fill in their
-- own patient information form: a parent or guardian does, in the patient app,
-- on the front desk tablet, or answering the front desk. The form now says so.
--
-- The guardian is recorded on the INTAKE, not the person: it is who answered
-- and signed this form at this clinic, and it is replaced along with the rest
-- of the answers the next time the form is saved (by a grown-up patient
-- themself, the guardian columns come back empty).
--
-- Additive: the old apps never send the keys, so their saves record no
-- guardian, exactly as before.
-- ============================================================================

alter table public.patient_intakes
  add column guardian_name         text,
  add column guardian_relationship text
    constraint patient_intakes_guardian_relationship_valid
      check (guardian_relationship in ('parent', 'guardian')),
  add column guardian_phone        text,
  add column guardian_email        text,
  -- A guardian is all of name, relationship and phone, or not there at all.
  add constraint patient_intakes_guardian_complete check (
    (guardian_name is null and guardian_relationship is null
       and guardian_phone is null and guardian_email is null)
    or (guardian_name is not null and guardian_relationship is not null
        and guardian_phone is not null));

-- Same as 20260927120000, plus the guardian. `filled_by_guardian` decides:
-- without it any guardian keys are ignored, so unticking the box on the form
-- cannot leave a half-guardian behind.
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
  r          public.patient_intakes;
  v_guardian boolean := coalesce((p_intake ->> 'filled_by_guardian')::boolean, false);
begin
  if coalesce((p_intake ->> 'consent')::boolean, false) is not true then
    raise exception 'the patient must agree to the privacy consent';
  end if;

  r := jsonb_populate_record(null::public.patient_intakes, p_intake);

  if r.under_treatment is null or r.takes_medications is null then
    raise exception 'answer whether the patient is under treatment and takes medications';
  end if;

  if v_guardian then
    r.guardian_name  := nullif(btrim(r.guardian_name), '');
    r.guardian_phone := nullif(btrim(r.guardian_phone), '');
    r.guardian_email := nullif(btrim(r.guardian_email), '');
    if r.guardian_name is null or r.guardian_relationship is null
       or r.guardian_phone is null then
      raise exception 'give the parent or guardian''s name, relationship and phone';
    end if;
  else
    r.guardian_name := null;
    r.guardian_relationship := null;
    r.guardian_phone := null;
    r.guardian_email := null;
  end if;

  insert into public.patient_intakes as i (
    patient_id, clinic_id, reason_for_visit, last_dental_visit, physician_name,
    under_treatment, treatment_details, takes_medications, medications,
    allergies, allergies_other, conditions, conditions_other,
    pregnant, nursing, birth_control,
    guardian_name, guardian_relationship, guardian_phone, guardian_email,
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
    r.guardian_name, r.guardian_relationship, r.guardian_phone, r.guardian_email,
    now(), btrim(coalesce(r.signed_name, '')), p_source, auth.uid())
  on conflict (patient_id) do update set
    reason_for_visit      = excluded.reason_for_visit,
    last_dental_visit     = excluded.last_dental_visit,
    physician_name        = excluded.physician_name,
    under_treatment       = excluded.under_treatment,
    treatment_details     = excluded.treatment_details,
    takes_medications     = excluded.takes_medications,
    medications           = excluded.medications,
    allergies             = excluded.allergies,
    allergies_other       = excluded.allergies_other,
    conditions            = excluded.conditions,
    conditions_other      = excluded.conditions_other,
    pregnant              = excluded.pregnant,
    nursing               = excluded.nursing,
    birth_control         = excluded.birth_control,
    guardian_name         = excluded.guardian_name,
    guardian_relationship = excluded.guardian_relationship,
    guardian_phone        = excluded.guardian_phone,
    guardian_email        = excluded.guardian_email,
    consent_at            = excluded.consent_at,
    signed_name           = excluded.signed_name,
    source                = excluded.source,
    updated_by            = excluded.updated_by;
end;
$$;
