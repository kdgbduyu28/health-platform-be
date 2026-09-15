-- ============================================================================
-- health-platform · seed data
--
-- Originally a port of the Flutter MockData fixture, now shaped for multiple
-- independent tenants:
--
--   D-Touch Dental Clinic      dental     the real client's demo tenant
--   ClearVision Eye Clinic     optometry
--   Little Stars Pediatrics    pedia
--   BrightSmile Dental Studio  dental     a SECOND dental tenant, unrelated to
--                                         D-Touch — the fixture that proves
--                                         same-vertical clinics coexist and
--                                         stay isolated
--
-- Dates are RELATIVE to today in Asia/Manila, so today/upcoming views never go
-- stale. IDs are stable UUIDs prefixed by entity type, with ordinal suffixes:
--
--   1… clinics   2… doctors   3… patient charts   4… appointments   5… persons
--
-- A person holds one chart per clinic they have visited, so charts outnumber
-- people: Juan (5…1) has charts at D-Touch (3…1), ClearVision (3…7) and
-- Little Stars (3…8).
--
-- Safe to re-run: every statement upserts. Persons and doctors are seeded
-- WITHOUT an account link — they are clinical records, not logins. See
-- dev/create_demo_users.sql to attach accounts.
-- ============================================================================

-- Slot helper: day offset from "today in Manila" + wall-clock time.
create or replace function pg_temp.slot(day_offset int, hhmm time)
returns timestamptz
language sql
as $$
  select (((now() at time zone 'Asia/Manila')::date + day_offset) + hhmm)
         at time zone 'Asia/Manila';
$$;

-- ── Clinics ─────────────────────────────────────────────────────────────────
-- Join codes are fixed here so demos and tests can use them; real clinics get
-- a generated one (private.new_join_code).

-- D-Touch's artwork ships inside the apps' shared package, so its logo columns
-- use the `asset:` prefix rather than a hosted URL. Every other clinic falls
-- back to its vertical's icon until it uploads a logo.

insert into public.clinics
  (id, type, name, slug, join_code, seed_color, logo_url, wordmark_url)
values
  ('10000000-0000-0000-0000-000000000001', 'dental',    'D-Touch Dental Clinic',
   'd-touch-dental-clinic',     'DTOUCH26', '#654F3B',
   'asset:assets/brand/dtouch_mark.png', 'asset:assets/brand/dtouch_wordmark.png'),
  ('10000000-0000-0000-0000-000000000002', 'optometry', 'ClearVision Eye Clinic',
   'clearvision-eye-clinic',    'CLEARV26', '#1E6FA8', null, null),
  ('10000000-0000-0000-0000-000000000003', 'pedia',     'Little Stars Pediatrics',
   'little-stars-pediatrics',   'STARS026', '#D9692B', null, null),
  ('10000000-0000-0000-0000-000000000004', 'dental',    'BrightSmile Dental Studio',
   'brightsmile-dental-studio', 'BRIGHT26', '#1F8A70', null, null)
on conflict (id) do update set
  type         = excluded.type,
  name         = excluded.name,
  slug         = excluded.slug,
  join_code    = excluded.join_code,
  seed_color   = excluded.seed_color,
  logo_url     = excluded.logo_url,
  wordmark_url = excluded.wordmark_url;

-- ── Services ────────────────────────────────────────────────────────────────
-- Keyed by clinic id, not type: two clinics now share the dental vertical and
-- keep separate catalogues.

insert into public.services (clinic_id, name, duration_minutes)
select v.clinic_id::uuid, v.name, v.mins
from (values
  -- D-Touch
  ('10000000-0000-0000-0000-000000000001', 'Teeth Cleaning',          45),
  ('10000000-0000-0000-0000-000000000001', 'Tooth Extraction',        45),
  ('10000000-0000-0000-0000-000000000001', 'Dental Filling',          30),
  ('10000000-0000-0000-0000-000000000001', 'Root Canal',              90),
  ('10000000-0000-0000-0000-000000000001', 'Braces Adjustment',       30),
  ('10000000-0000-0000-0000-000000000001', 'Teeth Whitening',         60),
  ('10000000-0000-0000-0000-000000000001', 'Dental X-Ray',            15),
  ('10000000-0000-0000-0000-000000000001', 'Wisdom Tooth Removal',    90),
  -- ClearVision ('Pediatric Eye Exam' is used by an appointment but was
  -- missing from the original Dart service list, so it is added here.)
  ('10000000-0000-0000-0000-000000000002', 'Eye Examination',         30),
  ('10000000-0000-0000-0000-000000000002', 'Contact Lens Fitting',    45),
  ('10000000-0000-0000-0000-000000000002', 'Eyeglasses Prescription', 30),
  ('10000000-0000-0000-0000-000000000002', 'Glaucoma Screening',      30),
  ('10000000-0000-0000-0000-000000000002', 'LASIK Consultation',      45),
  ('10000000-0000-0000-0000-000000000002', 'Retinal Exam',            30),
  ('10000000-0000-0000-0000-000000000002', 'Low Vision Assessment',   60),
  ('10000000-0000-0000-0000-000000000002', 'Pediatric Eye Exam',      45),
  -- Little Stars
  ('10000000-0000-0000-0000-000000000003', 'Well-Child Visit',        30),
  ('10000000-0000-0000-0000-000000000003', 'Vaccination',             15),
  ('10000000-0000-0000-0000-000000000003', 'Sick Visit',              20),
  ('10000000-0000-0000-0000-000000000003', 'Growth Assessment',       30),
  ('10000000-0000-0000-0000-000000000003', 'Development Screening',   60),
  ('10000000-0000-0000-0000-000000000003', 'Newborn Check-up',        30),
  ('10000000-0000-0000-0000-000000000003', 'School Physical',         30),
  -- BrightSmile
  ('10000000-0000-0000-0000-000000000004', 'Teeth Cleaning',          45),
  ('10000000-0000-0000-0000-000000000004', 'Dental Filling',          30),
  ('10000000-0000-0000-0000-000000000004', 'Dental Implant Consultation', 30)
) as v(clinic_id, name, mins)
on conflict (clinic_id, name) do update
  set duration_minutes = excluded.duration_minutes,
      is_active = true;

-- ── Doctors ─────────────────────────────────────────────────────────────────
-- Time slot sets from the original Dart fixture: _morning, _afternoon, _allDay.

insert into public.doctors
  (id, clinic_id, full_name, specialty, available_weekdays, available_time_slots)
values
  -- D-Touch
  ('20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001',
   'Maria Santos', 'General Dentistry', '{1,2,3,4,5}',
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30}'),
  ('20000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000001',
   'Jose Reyes', 'Orthodontics', '{1,3,5}',
   '{13:00,13:30,14:00,14:30,15:00,15:30,16:00,16:30}'),
  ('20000000-0000-0000-0000-000000000003',
   '10000000-0000-0000-0000-000000000001',
   'Ana Cruz', 'Oral Surgery', '{2,4,6}',
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30}'),
  -- ClearVision
  ('20000000-0000-0000-0000-000000000004',
   '10000000-0000-0000-0000-000000000002',
   'Carlos Bautista', 'Clinical Optometry', '{1,2,3,4,5}',
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30}'),
  ('20000000-0000-0000-0000-000000000005',
   '10000000-0000-0000-0000-000000000002',
   'Grace Flores', 'Pediatric Optometry', '{2,4}',
   '{13:00,13:30,14:00,14:30,15:00,15:30,16:00,16:30}'),
  ('20000000-0000-0000-0000-000000000006',
   '10000000-0000-0000-0000-000000000002',
   'Ramon Dela Cruz', 'Low Vision Specialist', '{1,3,5}',
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30,13:00,13:30,14:00,14:30,15:00,15:30,16:00,16:30}'),
  -- Little Stars
  ('20000000-0000-0000-0000-000000000007',
   '10000000-0000-0000-0000-000000000003',
   'Elena Garcia', 'General Pediatrics', '{1,2,3,4,5,6}',
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30}'),
  ('20000000-0000-0000-0000-000000000008',
   '10000000-0000-0000-0000-000000000003',
   'Miguel Torres', 'Neonatology', '{1,2,3,4,5}',
   '{13:00,13:30,14:00,14:30,15:00,15:30,16:00,16:30}'),
  ('20000000-0000-0000-0000-000000000009',
   '10000000-0000-0000-0000-000000000003',
   'Liza Mendoza', 'Developmental Pediatrics', '{3,5}',
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30,13:00,13:30,14:00,14:30,15:00,15:30,16:00,16:30}'),
  -- BrightSmile
  ('20000000-0000-0000-0000-00000000000a',
   '10000000-0000-0000-0000-000000000004',
   'Paolo Villanueva', 'Cosmetic Dentistry', '{1,2,3,4,5}',
   '{09:00,09:30,10:00,10:30,11:00,11:30}')
on conflict (id) do update set
  full_name            = excluded.full_name,
  specialty            = excluded.specialty,
  available_weekdays   = excluded.available_weekdays,
  available_time_slots = excluded.available_time_slots,
  is_active            = true;

-- ── Persons ─────────────────────────────────────────────────────────────────

insert into public.persons (id, full_name, phone, email, date_of_birth) values
  ('50000000-0000-0000-0000-000000000001', 'Juan dela Cruz', '09171234567', 'juan@email.com',   '1990-03-15'),
  ('50000000-0000-0000-0000-000000000002', 'Maria Reyes',    '09281234567', 'maria@email.com',  '1985-07-22'),
  ('50000000-0000-0000-0000-000000000003', 'Pedro Santos',   '09391234567', 'pedro@email.com',  '2015-01-10'),
  ('50000000-0000-0000-0000-000000000004', 'Ana Bautista',   '09451234567', 'ana@email.com',    '2010-08-05'),
  ('50000000-0000-0000-0000-000000000005', 'Carlos Flores',  '09561234567', 'carlos@email.com', '1975-11-30'),
  ('50000000-0000-0000-0000-000000000006', 'Lisa Torres',    '09671234567', 'lisa@email.com',   '2020-04-18')
on conflict (id) do update set
  full_name     = excluded.full_name,
  phone         = excluded.phone,
  email         = excluded.email,
  date_of_birth = excluded.date_of_birth;

-- ── Patient charts ──────────────────────────────────────────────────────────
-- One per (person, clinic). Maria has charts at both dental tenants, each with
-- notes the other must never see — the isolation tests lean on exactly this.

insert into public.patients (id, person_id, clinic_id, medical_notes) values
  -- D-Touch
  ('30000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', null),
  ('30000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Allergic to latex.'),
  ('30000000-0000-0000-0000-000000000005', '50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', null),
  ('30000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', null),
  -- ClearVision
  ('30000000-0000-0000-0000-000000000007', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', null),
  ('30000000-0000-0000-0000-000000000009', '50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', null),
  ('30000000-0000-0000-0000-00000000000b', '50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', null),
  ('30000000-0000-0000-0000-00000000000c', '50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', null),
  -- Little Stars
  ('30000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', null),
  ('30000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000003', null),
  ('30000000-0000-0000-0000-000000000006', '50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000003', null),
  ('30000000-0000-0000-0000-000000000008', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', null),
  -- BrightSmile
  ('30000000-0000-0000-0000-00000000000d', '50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004', 'Considering implants; wants a second opinion.')
on conflict (id) do update set
  medical_notes = excluded.medical_notes;

-- ── Appointments ────────────────────────────────────────────────────────────
-- Three or four appointments today per original clinic, a few upcoming, a few
-- completed. Each appointment points at the patient's chart AT THAT CLINIC —
-- the composite FK refuses anything else.

insert into public.appointments
  (id, clinic_id, patient_id, doctor_id, service_id, service_name,
   scheduled_at, status, notes)
select v.id, v.clinic_id, v.patient_id, v.doctor_id, s.id, v.service_name,
       v.scheduled_at, v.status, v.notes
from (values
  -- ─ D-TOUCH ─
  ('40000000-0000-0000-0000-000000000001'::uuid,
   '10000000-0000-0000-0000-000000000001'::uuid,
   '30000000-0000-0000-0000-000000000001'::uuid,
   '20000000-0000-0000-0000-000000000001'::uuid,
   'Teeth Cleaning', pg_temp.slot(0, '09:00'),
   'confirmed'::public.appointment_status, null::text),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001',
   'Dental Filling', pg_temp.slot(0, '10:00'), 'pending', null),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002',
   'Braces Adjustment', pg_temp.slot(0, '14:00'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Root Canal', pg_temp.slot(5, '09:00'), 'pending', null),
  ('40000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003',
   'Tooth Extraction', pg_temp.slot(7, '10:30'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Teeth Cleaning', pg_temp.slot(-7, '09:00'), 'completed',
   'Good oral hygiene. Follow-up in 6 months.'),
  ('40000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001',
   'Dental X-Ray', pg_temp.slot(-11, '10:00'), 'completed',
   'No cavities detected.'),

  -- ─ CLEARVISION ─
  ('40000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000004',
   'Eye Examination', pg_temp.slot(0, '09:30'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-000000000005',
   'Pediatric Eye Exam', pg_temp.slot(0, '14:00'), 'pending', null),
  ('40000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000004',
   'Contact Lens Fitting', pg_temp.slot(4, '10:00'), 'pending', null),
  ('40000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-00000000000c', '20000000-0000-0000-0000-000000000006',
   'Glaucoma Screening', pg_temp.slot(6, '11:00'), 'confirmed', null),
  ('40000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000004',
   'Eye Examination', pg_temp.slot(-7, '09:00'), 'completed',
   'Prescribed -2.50 OD, -2.75 OS. Recommend glasses.'),

  -- ─ LITTLE STARS ─
  ('40000000-0000-0000-0000-00000000000d', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000007',
   'Well-Child Visit', pg_temp.slot(0, '08:00'), 'completed', null),
  ('40000000-0000-0000-0000-00000000000e', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000007',
   'Vaccination', pg_temp.slot(0, '10:30'), 'confirmed', null),
  ('40000000-0000-0000-0000-00000000000f', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000008',
   'Sick Visit', pg_temp.slot(0, '15:00'), 'pending', null),
  ('40000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000008', '20000000-0000-0000-0000-000000000007',
   'Growth Assessment', pg_temp.slot(7, '09:00'), 'pending', null),
  ('40000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000009',
   'Development Screening', pg_temp.slot(12, '14:00'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000007',
   'Vaccination', pg_temp.slot(-14, '09:00'), 'completed',
   'MMR vaccine administered. Next dose in 12 months.'),

  -- ─ BRIGHTSMILE ─
  ('40000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000004',
   '30000000-0000-0000-0000-00000000000d', '20000000-0000-0000-0000-00000000000a',
   'Dental Implant Consultation', pg_temp.slot(3, '10:00'), 'pending', null)
) as v(id, clinic_id, patient_id, doctor_id, service_name,
       scheduled_at, status, notes)
left join public.services s
  on s.clinic_id = v.clinic_id and s.name = v.service_name
on conflict (id) do update set
  scheduled_at = excluded.scheduled_at,
  status       = excluded.status,
  notes        = excluded.notes,
  service_id   = excluded.service_id;
