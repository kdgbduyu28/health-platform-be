-- Moving a visit instead of cancelling it and booking again, so its history,
-- notes and bill stay on one row.
--
--   1. An appointment remembers where it was moved from, when, by whom, and
--      how many times.
--   2. available_slots can leave one visit out of the reckoning — the one
--      being moved — or a 60-minute visit could never shift by 30 minutes.
--   3. public.reschedule_appointment: the one way to move a visit. A patient
--      moves only to a time available_slots offers, and the visit goes back
--      to pending for the clinic to confirm; staff keep the status and may
--      also change the doctor.
--   4. A patient's own UPDATE may change the status and nothing else. Until
--      now appointments_cancel_own_patient pinned only the resulting status,
--      so a "cancel" could also rewrite the time, doctor or service.

-- ── 1. Where a visit was moved from ────────────────────────────────────────

alter table public.appointments
  add column rescheduled_from timestamptz,
  add column rescheduled_at   timestamptz,
  add column rescheduled_by   uuid references public.profiles (id) on delete set null,
  add column reschedule_count int not null default 0;

-- ── 2. Availability that ignores the visit being moved ─────────────────────
-- Same body as 20260923120100 plus p_ignore. Dropped rather than overloaded:
-- two candidates would make a three-argument call ambiguous. Callers passing
-- three named arguments — the deployed apps, guard_patient_booking — resolve
-- to this one through the default.

drop function public.available_slots(uuid, date, uuid);

create function public.available_slots(
  p_doctor_id  uuid,
  p_date       date,
  p_service_id uuid default null,
  p_ignore     uuid default null
)
returns setof timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_clinic   uuid;
  v_tz       text;
  v_weekdays smallint[];
  v_slots    text[];
  v_minutes  int;
begin
  select d.clinic_id, c.timezone, d.available_weekdays, d.available_time_slots
    into v_clinic, v_tz, v_weekdays, v_slots
    from public.doctors d
    join public.clinics c on c.id = d.clinic_id
   where d.id = p_doctor_id and d.is_active and c.is_active;

  if v_clinic is null or not private.is_clinic_member(v_clinic) then
    return;
  end if;
  if not (extract(isodow from p_date)::smallint = any (v_weekdays)) then
    return;
  end if;
  if exists (
    select 1 from public.doctor_time_off t
     where t.clinic_id = v_clinic
       and (t.doctor_id is null or t.doctor_id = p_doctor_id)
       and p_date between t.starts_on and t.ends_on
  ) then
    return;
  end if;

  select s.duration_minutes into v_minutes
    from public.services s
   where s.id = p_service_id and s.clinic_id = v_clinic;
  v_minutes := coalesce(v_minutes, 30);

  return query
    select slot.starts_at
      from (
        select distinct (p_date + t::time) at time zone v_tz as starts_at
          from unnest(v_slots) as t
      ) slot
     where slot.starts_at > now()
       and not exists (
         select 1 from public.appointments a
          where a.doctor_id = p_doctor_id
            and a.id is distinct from p_ignore
            and a.status not in ('cancelled', 'no_show')
            and tstzrange(a.scheduled_at, a.ends_at)
                && tstzrange(slot.starts_at,
                             slot.starts_at + make_interval(mins => v_minutes)))
     order by slot.starts_at;
end;
$$;

revoke all on function public.available_slots(uuid, date, uuid, uuid) from public, anon;
grant execute on function public.available_slots(uuid, date, uuid, uuid) to authenticated;

-- ── 3. Moving a visit ──────────────────────────────────────────────────────
--
-- Security definer because a patient has no UPDATE on the time (see 4); the
-- checks below are the policy. The overlap trigger and exclusion constraint
-- from 20260923120100 still decide a race, and still ignore the visit itself.

create or replace function public.reschedule_appointment(
  p_appointment_id uuid,
  p_scheduled_at   timestamptz,
  p_doctor_id      uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt   public.appointments;
  v_staff  boolean;
  v_doctor uuid;
  v_tz     text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  select * into v_appt from public.appointments
   where id = p_appointment_id
     for update;

  -- Someone else's visit reads exactly like a missing one.
  if not found
     or not (private.is_clinic_staff(v_appt.clinic_id)
             or v_appt.patient_id in (select private.my_patient_ids())) then
    raise exception 'Appointment not found.' using errcode = 'P0002';
  end if;
  v_staff  := private.is_clinic_staff(v_appt.clinic_id);
  v_doctor := coalesce(p_doctor_id, v_appt.doctor_id);

  if v_appt.status not in ('pending', 'confirmed') then
    raise exception 'Only a visit that has not started can be moved.';
  end if;
  if p_scheduled_at is null or p_scheduled_at <= now() then
    raise exception 'A visit can only move to a time still to come.';
  end if;
  if p_scheduled_at = v_appt.scheduled_at and v_doctor = v_appt.doctor_id then
    return;
  end if;
  if v_doctor <> v_appt.doctor_id and not exists (
    select 1 from public.doctors d
     where d.id = v_doctor and d.clinic_id = v_appt.clinic_id and d.is_active
  ) then
    raise exception 'That doctor is not taking visits here.';
  end if;

  -- A patient takes only what a booking screen would have offered them.
  if not v_staff then
    select c.timezone into v_tz from public.clinics c where c.id = v_appt.clinic_id;
    if not exists (
      select 1
        from public.available_slots(v_doctor,
                                    (p_scheduled_at at time zone v_tz)::date,
                                    v_appt.service_id,
                                    v_appt.id) s
       where s = p_scheduled_at
    ) then
      raise exception 'That time is not available. Please pick another.';
    end if;
  end if;

  update public.appointments
     set scheduled_at     = p_scheduled_at,
         doctor_id        = v_doctor,
         rescheduled_from = v_appt.scheduled_at,
         rescheduled_at   = now(),
         rescheduled_by   = auth.uid(),
         reschedule_count = v_appt.reschedule_count + 1,
         -- The clinic agreed to the old time, not to this one.
         status = case when v_staff then v_appt.status else 'pending' end
   where id = v_appt.id;
end;
$$;

revoke all on function public.reschedule_appointment(uuid, timestamptz, uuid) from public, anon;
grant execute on function public.reschedule_appointment(uuid, timestamptz, uuid) to authenticated;

-- ── 4. A patient's UPDATE changes the status only ──────────────────────────
-- current_user, not auth.uid(): inside reschedule_appointment (security
-- definer) the caller is still the patient, but the statement runs as the
-- function's owner, and that path has done its own checks.

create or replace function private.guard_patient_appointment_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' or private.is_clinic_staff(old.clinic_id) then
    return new;
  end if;
  if (to_jsonb(new) - 'status' - 'updated_at')
     is distinct from (to_jsonb(old) - 'status' - 'updated_at') then
    raise exception 'You can cancel or reschedule this visit; anything else, please call the clinic.';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_patient_appointment_update() from public, anon, authenticated;

create trigger appointments_guard_patient_update
  before update on public.appointments
  for each row execute function private.guard_patient_appointment_update();
