-- ============================================================================
-- health-platform · remove redundant foreign keys on appointments
--
-- `appointments` carried two relationships to `doctors` and two to `services`:
-- a plain single-column FK, and the composite (x_id, clinic_id) FK that keeps
-- a booking's doctor and service inside its own clinic.
--
-- The single-column ones are redundant — a composite FK on (doctor_id,
-- clinic_id) already proves doctor_id exists. Worse, they are actively
-- harmful: PostgREST refuses to embed a related table when more than one
-- relationship exists between the two, so
--
--     appointments?select=*,doctor:doctors(*)
--
-- failed with PGRST201 "Could not embed because more than one relationship was
-- found". That is every appointment query the four apps make.
--
-- Dropping the plain FKs leaves exactly one relationship each. The ON DELETE
-- behaviour of the dropped constraints is preserved by rebuilding the
-- composite ones to carry it, so nothing about deletes changes:
--
--   doctors  — was RESTRICT: a doctor with appointments cannot be deleted.
--   services — was SET NULL: deleting a service blanks service_id on past
--              appointments, which keeps their history readable because
--              service_name is a snapshot taken at booking time.
--
-- The services case needs Postgres 15+ column-specific SET NULL: a bare
-- SET NULL would try to null clinic_id too, which is NOT NULL.
-- ============================================================================

alter table public.appointments
  drop constraint appointments_doctor_id_fkey,
  drop constraint appointments_service_id_fkey;

alter table public.appointments
  drop constraint appointments_doctor_matches_clinic,
  add constraint appointments_doctor_matches_clinic
    foreign key (doctor_id, clinic_id)
    references public.doctors (id, clinic_id)
    on delete restrict;

alter table public.appointments
  drop constraint appointments_service_matches_clinic,
  add constraint appointments_service_matches_clinic
    foreign key (service_id, clinic_id)
    references public.services (id, clinic_id)
    on delete set null (service_id);
