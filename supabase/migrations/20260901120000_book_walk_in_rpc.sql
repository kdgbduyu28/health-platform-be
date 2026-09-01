-- ============================================================================
-- health-platform · atomic walk-in booking
--
-- Registering a walk-in is two writes: create the chart, then book against it.
-- Done from the client that is two round trips and two transactions, so losing
-- the double-booking race on the second one leaves an orphan patient record
-- behind — a chart for someone who was never actually booked, cluttering the
-- clinic's roster and needing manual cleanup.
--
-- A function body runs inside a single transaction, so the unique-index
-- violation on the appointment rolls the patient insert back with it. Either
-- both rows exist or neither does.
--
-- SECURITY INVOKER (the default, stated here because it is the whole point):
-- the function runs as the caller, so every RLS policy still applies. Making
-- this SECURITY DEFINER would turn it into a hole that lets any signed-in user
-- create patients and bookings at clinics they have nothing to do with —
-- exactly the checks patients_insert_staff and appointments_insert_clinic_staff
-- exist to enforce.
-- ============================================================================

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
  v_patient_id uuid;
  v_appointment_id uuid;
begin
  if coalesce(trim(p_full_name), '') = '' then
    raise exception 'patient name is required';
  end if;
  if coalesce(trim(p_phone), '') = '' then
    raise exception 'patient phone is required';
  end if;

  -- registered_clinic_id is what makes this row readable back to the staff
  -- member who just created it; RLS also requires it to be a clinic they staff.
  insert into public.patients
    (registered_clinic_id, full_name, phone, email, created_by)
  values
    (p_clinic_id, trim(p_full_name), trim(p_phone),
     nullif(trim(coalesce(p_email, '')), ''), auth.uid())
  returning id into v_patient_id;

  -- Staff may book straight to confirmed; RLS only pins patients themselves
  -- to 'pending'.
  insert into public.appointments
    (clinic_id, patient_id, doctor_id, service_id, service_name,
     scheduled_at, status, created_by)
  values
    (p_clinic_id, v_patient_id, p_doctor_id, p_service_id, p_service_name,
     p_scheduled_at, 'confirmed', auth.uid())
  returning id into v_appointment_id;

  return v_appointment_id;
end;
$$;

-- Only signed-in callers. anon would be rejected by RLS anyway, but there is
-- no reason to publish the endpoint to it.
revoke all on function public.book_walk_in(
  uuid, text, text, uuid, text, timestamptz, uuid, text
) from public, anon;

grant execute on function public.book_walk_in(
  uuid, text, text, uuid, text, timestamptz, uuid, text
) to authenticated;

comment on function public.book_walk_in(
  uuid, text, text, uuid, text, timestamptz, uuid, text
) is
  'Registers a walk-in patient and books their appointment in one '
  'transaction. Runs as the caller, so RLS decides whether they may do it.';
