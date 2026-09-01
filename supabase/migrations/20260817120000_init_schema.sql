-- ============================================================================
-- health-platform · core schema
--
-- Mirrors the Dart models in health-platform-fe/packages/dependencies:
--   ClinicType        -> public.clinic_type enum + public.clinics
--   AppointmentStatus -> public.appointment_status enum
--   Doctor            -> public.doctors
--   Patient           -> public.patients
--   Appointment       -> public.appointments
--   ClinicType.services -> public.services (was a hardcoded Dart list)
-- ============================================================================

create extension if not exists pgcrypto;

-- ── Enums ───────────────────────────────────────────────────────────────────

create type public.clinic_type as enum ('dental', 'optometry', 'pedia');

create type public.appointment_status as enum (
  'pending', 'confirmed', 'completed', 'cancelled'
);

-- One role per signed-in user, matching the four Flutter apps.
create type public.app_role as enum ('patient', 'doctor', 'assistant', 'admin');

-- ── Clinics ─────────────────────────────────────────────────────────────────
-- The three clinic flavors are tenant *rows*, not separate Supabase projects.
-- All four apps and all three flavors share one project; isolation is by RLS.

create table public.clinics (
  id         uuid primary key default gen_random_uuid(),
  type       public.clinic_type not null unique,
  name       text not null,
  timezone   text not null default 'Asia/Manila',
  created_at timestamptz not null default now()
);

-- ── Profiles ────────────────────────────────────────────────────────────────
-- 1:1 with auth.users. Holds the role that drives every RLS decision.

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  role       public.app_role not null default 'patient',
  full_name  text not null,
  email      text,
  phone      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Which clinics a staff member (doctor / assistant / admin) works at.
-- Patients have no membership row; they are scoped by their patient record.
create table public.clinic_memberships (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  clinic_id  uuid not null references public.clinics (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (profile_id, clinic_id)
);

-- ── Services ────────────────────────────────────────────────────────────────

create table public.services (
  id               uuid primary key default gen_random_uuid(),
  clinic_id        uuid not null references public.clinics (id) on delete cascade,
  name             text not null,
  duration_minutes int not null default 30 check (duration_minutes > 0),
  is_active        boolean not null default true,
  unique (clinic_id, name),
  -- Lets appointments enforce "service belongs to the same clinic" via a
  -- composite foreign key instead of a trigger.
  unique (id, clinic_id)
);

-- ── Doctors ─────────────────────────────────────────────────────────────────

create table public.doctors (
  id                   uuid primary key default gen_random_uuid(),
  profile_id           uuid unique references public.profiles (id) on delete set null,
  clinic_id            uuid not null references public.clinics (id) on delete cascade,
  full_name            text not null,
  specialty            text not null,
  available_weekdays   smallint[] not null default '{1,2,3,4,5}', -- 1=Mon … 7=Sun
  available_time_slots text[] not null default '{}',              -- '09:00', '09:30', …
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  constraint doctors_weekdays_valid
    check (available_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),
  unique (id, clinic_id)
);

-- ── Patients ────────────────────────────────────────────────────────────────
-- profile_id is nullable on purpose: assistants create walk-in patient records
-- for people who have never signed up for an account.

create table public.patients (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid unique references public.profiles (id) on delete set null,
  -- The clinic that holds this patient's chart. Staff can see their own
  -- clinic's roster from the moment a record is created; without this, a
  -- walk-in would be invisible to the assistant who just registered them,
  -- because visibility would depend on an appointment that does not exist yet.
  -- Null for patients who signed themselves up before choosing a clinic.
  registered_clinic_id uuid references public.clinics (id) on delete set null,
  full_name     text not null,
  phone         text not null,
  email         text,
  date_of_birth date,
  medical_notes text,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index patients_registered_clinic_idx
  on public.patients (registered_clinic_id);

-- ── Appointments ────────────────────────────────────────────────────────────

create table public.appointments (
  id           uuid primary key default gen_random_uuid(),
  clinic_id    uuid not null references public.clinics (id) on delete cascade,
  patient_id   uuid not null references public.patients (id) on delete cascade,
  doctor_id    uuid not null references public.doctors (id) on delete restrict,
  service_id   uuid references public.services (id) on delete set null,
  -- Snapshot of the service name at booking time, so renaming or retiring a
  -- service never rewrites history. Matches Appointment.service in Dart.
  service_name text not null,
  scheduled_at timestamptz not null,
  status       public.appointment_status not null default 'pending',
  notes        text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  -- The doctor must practise at the clinic the appointment belongs to.
  constraint appointments_doctor_matches_clinic
    foreign key (doctor_id, clinic_id) references public.doctors (id, clinic_id),

  -- Same for the service. MATCH SIMPLE means this is skipped when
  -- service_id is null, which is what we want for ad-hoc services.
  constraint appointments_service_matches_clinic
    foreign key (service_id, clinic_id) references public.services (id, clinic_id)
);

-- A doctor cannot hold two live appointments in the same slot. Cancelled ones
-- are excluded so a freed slot can be rebooked.
create unique index appointments_no_double_booking
  on public.appointments (doctor_id, scheduled_at)
  where status <> 'cancelled';

create index appointments_clinic_schedule_idx
  on public.appointments (clinic_id, scheduled_at desc);
create index appointments_patient_idx
  on public.appointments (patient_id, scheduled_at desc);
create index appointments_doctor_idx
  on public.appointments (doctor_id, scheduled_at desc);
create index doctors_clinic_idx on public.doctors (clinic_id) where is_active;
create index services_clinic_idx on public.services (clinic_id) where is_active;

-- ── updated_at maintenance ──────────────────────────────────────────────────

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger patients_set_updated_at
  before update on public.patients
  for each row execute function public.set_updated_at();

create trigger appointments_set_updated_at
  before update on public.appointments
  for each row execute function public.set_updated_at();

-- ── Auth bridge ─────────────────────────────────────────────────────────────
-- Every new auth user gets a profile. The role is ALWAYS 'patient' here and is
-- deliberately not read from raw_user_meta_data: that field is client-supplied,
-- so honouring it would let anyone sign up as an admin. Staff are promoted by
-- an existing admin (or by service-role key), never at sign-up.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      split_part(coalesce(new.email, 'user'), '@', 1)
    ),
    new.email,
    'patient'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── Realtime ────────────────────────────────────────────────────────────────
-- Lets the admin dashboard and assistant check-in screen update live.
-- RLS still applies to realtime payloads.

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.appointments;
  end if;
end;
$$;
