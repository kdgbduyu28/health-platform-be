-- One patient, one visit at a time.
--
-- 20260923120100 stopped a DOCTOR being booked twice over. Nothing stopped
-- a PATIENT: Juan could hold Dr Santos at 10:00 and Dr Reyes at 10:00, and
-- the front desk could book it for him. Now:
--
--   1. The readable refusal in set_appointment_times also checks the
--      patient, and the trigger fires when the patient changes.
--   2. An exclusion constraint on (patient_id, time range), the same shape
--      as appointments_no_overlap, decides a race between two bookings.
--   3. available_slots, asked by a patient, leaves out the times they are
--      already booked elsewhere at this clinic — so a booking screen never
--      offers a time the database would then refuse.
--
-- Per chart (patient_id), not per person: a person's charts at two clinics
-- belong to two tenants, and one clinic's refusal must not reveal that the
-- person has a visit at another.
--
-- Cancelled and no-show visits hold no time, as for doctors.

-- ── 1. The readable refusal ────────────────────────────────────────────────
-- Same body as 20260923120100 plus the patient check.

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

revoke all on function private.set_appointment_times() from public, anon, authenticated;

drop trigger appointments_set_times on public.appointments;
create trigger appointments_set_times
  before insert or update of scheduled_at, service_id, duration_minutes, doctor_id, patient_id, status
  on public.appointments
  for each row execute function private.set_appointment_times();

-- ── 2. The constraint ──────────────────────────────────────────────────────
-- Fails if the data already holds a patient in two places at once; those
-- have to be cancelled or moved by hand first (see README).

alter table public.appointments
  add constraint appointments_no_patient_overlap
    exclude using gist (patient_id with =, tstzrange(scheduled_at, ends_at) with &&)
    where (status not in ('cancelled', 'no_show'));

-- ── 3. Availability that knows the patient asking ──────────────────────────
-- Same signature and body as 20260924120000 plus the last NOT EXISTS. Staff
-- see the doctor's free times: a desk booking names its patient only at
-- insert, where section 1 answers.

create or replace function public.available_slots(
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
  v_staff    boolean;
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
  v_staff := private.is_clinic_staff(v_clinic);

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
       and (v_staff or not exists (
         select 1 from public.appointments a
          where a.clinic_id = v_clinic
            and a.patient_id in (select private.my_patient_ids())
            and a.id is distinct from p_ignore
            and a.status not in ('cancelled', 'no_show')
            and tstzrange(a.scheduled_at, a.ends_at)
                && tstzrange(slot.starts_at,
                             slot.starts_at + make_interval(mins => v_minutes))))
     order by slot.starts_at;
end;
$$;

revoke all on function public.available_slots(uuid, date, uuid, uuid) from public, anon;
grant execute on function public.available_slots(uuid, date, uuid, uuid) to authenticated;
