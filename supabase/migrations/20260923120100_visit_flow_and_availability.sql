-- Visits that run a real day: a status flow, real availability, and the
-- roster and catalogue an admin can finally manage.
--
--   1. Appointments get an end time, from their service's duration.
--   2. Double booking means OVERLAPPING, not "same start time": a 60-minute
--      service at 09:00 now blocks 09:30.
--   3. The status flow from 20260923120000 is enforced, and each step
--      stamped (arrived_at, started_at, completed_at).
--   4. Time off: a doctor's leave, or the whole clinic closed for a day.
--   5. public.available_slots — the times a booking screen may offer. A
--      patient's booking must be one of them; staff may book outside the
--      grid (their judgement), but never on top of another visit.
--   6. Services get an optional price.
--   7. A doctor editing their own roster row may change only their schedule.

-- ── 1. End times ───────────────────────────────────────────────────────────

create extension if not exists btree_gist with schema extensions;

alter table public.appointments
  add column duration_minutes int not null default 30
    constraint appointments_duration_valid check (duration_minutes between 5 and 480),
  add column ends_at      timestamptz,
  add column arrived_at   timestamptz,
  add column started_at   timestamptz,
  add column completed_at timestamptz;

update public.appointments a
   set duration_minutes = s.duration_minutes
  from public.services s
 where s.id = a.service_id;

update public.appointments
   set ends_at = scheduled_at + make_interval(mins => duration_minutes);

alter table public.appointments alter column ends_at set not null;

-- Duration follows the service; the end follows the start. Neither is the
-- client's to set, so both are recomputed rather than trusted.
create or replace function private.set_appointment_times()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.service_id is not null
     and (tg_op = 'INSERT' or new.service_id is distinct from old.service_id) then
    select s.duration_minutes into new.duration_minutes
      from public.services s where s.id = new.service_id;
  end if;
  new.ends_at := new.scheduled_at + make_interval(mins => new.duration_minutes);

  -- A readable refusal for the common case. The exclusion constraint below
  -- still decides a race between two bookings in flight.
  if new.status not in ('cancelled', 'no_show')
     and (tg_op = 'INSERT'
          or new.scheduled_at is distinct from old.scheduled_at
          or new.ends_at      is distinct from old.ends_at
          or new.doctor_id    is distinct from old.doctor_id
          or old.status in ('cancelled', 'no_show'))
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
  return new;
end;
$$;

revoke all on function private.set_appointment_times() from public, anon, authenticated;

create trigger appointments_set_times
  before insert or update of scheduled_at, service_id, duration_minutes, doctor_id, status
  on public.appointments
  for each row execute function private.set_appointment_times();

-- ── 2. No overlapping visits per doctor ────────────────────────────────────

drop index public.appointments_no_double_booking;

alter table public.appointments
  add constraint appointments_no_overlap
    exclude using gist (doctor_id with =, tstzrange(scheduled_at, ends_at) with &&)
    where (status not in ('cancelled', 'no_show'));

-- ── 3. The status flow ─────────────────────────────────────────────────────
--
-- Who may move a visit where:
--   patient      pending/confirmed → cancelled (their own; RLS already
--                allows nothing else)
--   any staff    pending → confirmed; confirmed → arrived / no_show;
--                pending/confirmed/arrived → cancelled
--   doctor/admin confirmed/arrived → in_consultation → completed
--   admin        anything — corrections happen
--
-- The service role (auth.uid() is null: seeds, the dashboard) is not held to
-- it.

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
    if auth.uid() is not null and v_to not in ('pending', 'confirmed', 'arrived') then
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
      or (v_from = 'arrived'   and v_to in ('in_consultation', 'cancelled'))
      or (v_from = 'in_consultation' and v_to = 'completed')
    ) then
      raise exception 'A % visit cannot become %.', replace(v_from, '_', ' '), replace(v_to, '_', ' ');
    elsif v_to in ('in_consultation', 'completed') and not private.is_clinician(new.clinic_id) then
      raise exception 'Only a doctor or admin can start or complete a consultation.';
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
      new.completed_at := now();
    else null;
  end case;
  return new;
end;
$$;

revoke all on function private.guard_appointment_status() from public, anon, authenticated;

create trigger appointments_guard_status
  before insert or update of status on public.appointments
  for each row execute function private.guard_appointment_status();

create index appointments_doctor_day_idx
  on public.appointments (doctor_id, scheduled_at)
  where status not in ('cancelled', 'no_show');

-- ── 4. Time off ────────────────────────────────────────────────────────────

create table public.doctor_time_off (
  id         uuid primary key default gen_random_uuid(),
  clinic_id  uuid not null references public.clinics (id) on delete cascade,
  -- Null: the whole clinic is closed (a holiday).
  doctor_id  uuid,
  starts_on  date not null,
  ends_on    date not null,
  reason     text,
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint doctor_time_off_order check (ends_on >= starts_on),
  constraint doctor_time_off_span  check (ends_on - starts_on <= 366),
  -- Pins a doctor's leave to that doctor's clinic. MATCH SIMPLE: a
  -- clinic-wide closure (null doctor) skips it.
  constraint doctor_time_off_doctor_in_clinic
    foreign key (doctor_id, clinic_id) references public.doctors (id, clinic_id)
    on delete cascade
);

create index doctor_time_off_lookup_idx
  on public.doctor_time_off (clinic_id, starts_on, ends_on);

alter table public.doctor_time_off enable row level security;

create policy doctor_time_off_select_staff on public.doctor_time_off
  for select to authenticated using (private.is_clinic_staff(clinic_id));

create policy doctor_time_off_write_admin on public.doctor_time_off
  for all to authenticated
  using (private.is_clinic_admin(clinic_id))
  with check (private.is_clinic_admin(clinic_id));

-- A doctor may book their own leave, and only their own.
create policy doctor_time_off_write_own on public.doctor_time_off
  for all to authenticated
  using (doctor_id in (select private.my_doctor_ids()))
  with check (doctor_id in (select private.my_doctor_ids()));

-- ── 5. Availability ────────────────────────────────────────────────────────

-- Every start time [p_doctor_id] can take a [p_service_id]-long visit on
-- [p_date] (the clinic's calendar day): on a working weekday, off nobody's
-- leave or a closure, not already past, and not overlapping another visit.
--
-- Security definer so a patient can see which times are taken without
-- reading anyone's appointments; it returns times, never who holds them.
create or replace function public.available_slots(
  p_doctor_id  uuid,
  p_date       date,
  p_service_id uuid default null
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
            and a.status not in ('cancelled', 'no_show')
            and tstzrange(a.scheduled_at, a.ends_at)
                && tstzrange(slot.starts_at,
                             slot.starts_at + make_interval(mins => v_minutes)))
     order by slot.starts_at;
end;
$$;

revoke all on function public.available_slots(uuid, date, uuid) from public, anon;
grant execute on function public.available_slots(uuid, date, uuid) to authenticated;

-- A patient books only what available_slots offers. Staff are trusted with
-- the grid (a walk-in squeezed in at 11:10) but not with overlaps, which the
-- constraint above refuses to everyone.
create or replace function private.guard_patient_booking()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tz text;
begin
  if auth.uid() is null or private.is_clinic_staff(new.clinic_id) then
    return new;
  end if;
  select c.timezone into v_tz from public.clinics c where c.id = new.clinic_id;
  if not exists (
    select 1
      from public.available_slots(new.doctor_id,
                                  (new.scheduled_at at time zone v_tz)::date,
                                  new.service_id) s
     where s = new.scheduled_at
  ) then
    raise exception 'That time is not available. Please pick another.';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_patient_booking() from public, anon, authenticated;

create trigger appointments_guard_patient_booking
  before insert on public.appointments
  for each row execute function private.guard_patient_booking();

-- ── 6. Prices ──────────────────────────────────────────────────────────────

alter table public.services
  add column price numeric(10, 2)
    constraint services_price_valid check (price >= 0);

-- The public page shows it too.
create or replace function public.clinic_by_slug(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id',            c.id,
    'name',          c.name,
    'slug',          c.slug,
    'type',          c.type,
    'clinic_type',   jsonb_build_object('display_name', t.display_name,
                                        'icon_name',    t.icon_name),
    'timezone',      c.timezone,
    'seed_color',    c.seed_color,
    'logo_url',      c.logo_url,
    'wordmark_url',  c.wordmark_url,
    'contact_phone', c.contact_phone,
    'address',       c.address,
    'is_active',     c.is_active,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',               s.id,
               'clinic_id',        s.clinic_id,
               'name',             s.name,
               'duration_minutes', s.duration_minutes,
               'price',            s.price,
               'is_active',        s.is_active)
             order by s.name)
      from public.services s
      where s.clinic_id = c.id and s.is_active), '[]'::jsonb),
    'doctors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',                 d.id,
               'clinic_id',          d.clinic_id,
               'full_name',          d.full_name,
               'specialty',          d.specialty,
               'available_weekdays', d.available_weekdays,
               'is_active',          d.is_active)
             order by d.full_name)
      from public.doctors d
      where d.clinic_id = c.id and d.is_active), '[]'::jsonb)
  )
  from public.clinics c
  join public.clinic_types t on t.slug = c.type
  where c.slug = lower(trim(p_slug))
    and c.is_active;
$$;

-- ── 7. Doctors: schedule format, and what a doctor may edit themselves ─────

create or replace function private.valid_time_slots(p_slots text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(bool_and(s ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'), true)
    from unnest(p_slots) s;
$$;

alter table public.doctors
  add constraint doctors_time_slots_valid
    check (private.valid_time_slots(available_time_slots));

-- doctors_update_self let a doctor rewrite their whole row — name, clinic,
-- even is_active. Their schedule is theirs; the rest is the admin's.
create or replace function private.guard_doctor_self_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null or private.is_clinic_admin(old.clinic_id) then
    return new;
  end if;
  if (new.id, new.profile_id, new.clinic_id, new.full_name, new.specialty, new.is_active)
     is distinct from
     (old.id, old.profile_id, old.clinic_id, old.full_name, old.specialty, old.is_active) then
    raise exception 'You can change your working days and hours; ask an admin for anything else.';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_doctor_self_update() from public, anon, authenticated;

create trigger doctors_guard_self_update
  before update on public.doctors
  for each row execute function private.guard_doctor_self_update();
