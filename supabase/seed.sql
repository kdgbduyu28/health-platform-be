-- ============================================================================
-- health-platform · seed data
--
-- A direct port of MockData in
--   health-platform-fe/packages/dependencies/lib/src/data/mock_data.dart
--
-- Two deliberate differences from the Dart mock:
--
--  1. Dates are RELATIVE to today in Asia/Manila, not pinned to 2026-05-09.
--     The mock's hardcoded dates mean today/upcoming views go empty once that
--     date passes; seeding relative keeps the demo alive indefinitely.
--  2. IDs are stable UUIDs with an ordinal suffix, prefixed by entity type:
--       1… clinics   2… doctors   3… patients   4… appointments
--     Doctor ordinals follow the Dart list order (d1 d2 d3 o1 o2 o3 p1 p2 p3),
--     so doctor …0004 is the mock's 'o1' — Dr. Bautista.
--
-- Safe to re-run: every statement upserts.
-- Patients and doctors are seeded WITHOUT profile_id — they are clinical
-- records, not accounts. See the README for linking a signup to a record.
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

insert into public.clinics (id, type, name) values
  ('10000000-0000-0000-0000-000000000001', 'dental',    'D-Touch Dental Clinic'),
  ('10000000-0000-0000-0000-000000000002', 'optometry', 'ClearVision Eye Clinic'),
  ('10000000-0000-0000-0000-000000000003', 'pedia',     'Little Stars Pediatrics')
on conflict (id) do update set name = excluded.name;

-- ── Services (were the hardcoded ClinicType.services lists in Dart) ─────────

insert into public.services (clinic_id, name, duration_minutes)
select c.id, v.name, v.mins
from (values
  -- Dental
  ('dental',    'Teeth Cleaning',          45),
  ('dental',    'Tooth Extraction',        45),
  ('dental',    'Dental Filling',          30),
  ('dental',    'Root Canal',              90),
  ('dental',    'Braces Adjustment',       30),
  ('dental',    'Teeth Whitening',         60),
  ('dental',    'Dental X-Ray',            15),
  ('dental',    'Wisdom Tooth Removal',    90),
  -- Optometry ('Pediatric Eye Exam' is used by appointment b2 but was missing
  -- from the Dart service list, so it is added here.)
  ('optometry', 'Eye Examination',         30),
  ('optometry', 'Contact Lens Fitting',    45),
  ('optometry', 'Eyeglasses Prescription', 30),
  ('optometry', 'Glaucoma Screening',      30),
  ('optometry', 'LASIK Consultation',      45),
  ('optometry', 'Retinal Exam',            30),
  ('optometry', 'Low Vision Assessment',   60),
  ('optometry', 'Pediatric Eye Exam',      45),
  -- Pediatrics
  ('pedia',     'Well-Child Visit',        30),
  ('pedia',     'Vaccination',             15),
  ('pedia',     'Sick Visit',              20),
  ('pedia',     'Growth Assessment',       30),
  ('pedia',     'Development Screening',   60),
  ('pedia',     'Newborn Check-up',        30),
  ('pedia',     'School Physical',         30)
) as v(clinic, name, mins)
join public.clinics c on c.type = v.clinic::public.clinic_type
on conflict (clinic_id, name) do update
  set duration_minutes = excluded.duration_minutes,
      is_active = true;

-- ── Doctors ─────────────────────────────────────────────────────────────────
-- Time slot sets from the Dart fixture: _morning, _afternoon, _allDay.

insert into public.doctors
  (id, clinic_id, full_name, specialty, available_weekdays, available_time_slots)
values
  -- Dental (mock d1–d3)
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
  -- Optometry (mock o1–o3)
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
  -- Pediatrics (mock p1–p3)
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
   '{08:00,08:30,09:00,09:30,10:00,10:30,11:00,11:30,13:00,13:30,14:00,14:30,15:00,15:30,16:00,16:30}')
on conflict (id) do update set
  full_name            = excluded.full_name,
  specialty            = excluded.specialty,
  available_weekdays   = excluded.available_weekdays,
  available_time_slots = excluded.available_time_slots,
  is_active            = true;

-- ── Patients (mock pt1–pt6) ─────────────────────────────────────────────────
-- registered_clinic_id is each patient's home clinic. Patients who also visit a
-- sibling clinic stay visible to that clinic's staff through their appointment
-- there, so Juan (registered dental) is still readable by optometry staff.

insert into public.patients
  (id, registered_clinic_id, full_name, phone, email, date_of_birth)
values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   'Juan dela Cruz', '09171234567', 'juan@email.com',   '1990-03-15'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   'Maria Reyes',    '09281234567', 'maria@email.com',  '1985-07-22'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003',
   'Pedro Santos',   '09391234567', 'pedro@email.com',  '2015-01-10'),
  ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000003',
   'Ana Bautista',   '09451234567', 'ana@email.com',    '2010-08-05'),
  ('30000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001',
   'Carlos Flores',  '09561234567', 'carlos@email.com', '1975-11-30'),
  ('30000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000003',
   'Lisa Torres',    '09671234567', 'lisa@email.com',   '2020-04-18')
on conflict (id) do update set
  registered_clinic_id = excluded.registered_clinic_id,
  full_name            = excluded.full_name,
  phone                = excluded.phone,
  email                = excluded.email,
  date_of_birth        = excluded.date_of_birth;

-- ── Appointments (mock a1–a7, b1–b5, c1–c6) ─────────────────────────────────
-- Day offsets preserve the mock's shape relative to its "today": three or four
-- appointments today per clinic, a few upcoming, a few completed in the past.

insert into public.appointments
  (id, clinic_id, patient_id, doctor_id, service_id, service_name,
   scheduled_at, status, notes)
select v.id, v.clinic_id, v.patient_id, v.doctor_id, s.id, v.service_name,
       v.scheduled_at, v.status, v.notes
from (values
  -- ─ DENTAL ─
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
   '30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003',
   'Tooth Extraction', pg_temp.slot(7, '10:30'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Teeth Cleaning', pg_temp.slot(-7, '09:00'), 'completed',
   'Good oral hygiene. Follow-up in 6 months.'),
  ('40000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001',
   'Dental X-Ray', pg_temp.slot(-11, '10:00'), 'completed',
   'No cavities detected.'),

  -- ─ OPTOMETRY ─
  ('40000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000004',
   'Eye Examination', pg_temp.slot(0, '09:30'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000005',
   'Pediatric Eye Exam', pg_temp.slot(0, '14:00'), 'pending', null),
  ('40000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'Contact Lens Fitting', pg_temp.slot(4, '10:00'), 'pending', null),
  ('40000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000006',
   'Glaucoma Screening', pg_temp.slot(6, '11:00'), 'confirmed', null),
  ('40000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'Eye Examination', pg_temp.slot(-7, '09:00'), 'completed',
   'Prescribed -2.50 OD, -2.75 OS. Recommend glasses.'),

  -- ─ PEDIA ─
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
   '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'Growth Assessment', pg_temp.slot(7, '09:00'), 'pending', null),
  ('40000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000009',
   'Development Screening', pg_temp.slot(12, '14:00'), 'confirmed', null),
  ('40000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000007',
   'Vaccination', pg_temp.slot(-14, '09:00'), 'completed',
   'MMR vaccine administered. Next dose in 12 months.')
) as v(id, clinic_id, patient_id, doctor_id, service_name,
       scheduled_at, status, notes)
left join public.services s
  on s.clinic_id = v.clinic_id and s.name = v.service_name
on conflict (id) do update set
  scheduled_at = excluded.scheduled_at,
  status       = excluded.status,
  notes        = excluded.notes,
  service_id   = excluded.service_id;
