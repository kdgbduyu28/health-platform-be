-- ============================================================================
-- health-platform · close the cross-tenant catalogue reads
--
-- `clinics`, `doctors` and `services` were each `select … using (true)`: any
-- signed-in user could read every clinic's name, full doctor roster and
-- service catalogue. With one operator's three demo clinics that was a
-- convenient clinic picker. With independent clients it hands each clinic's
-- staffing and pricing surface to every other client's users.
--
-- Now a user reads a clinic — and its roster and catalogue — only if they
-- belong to it: as staff (a membership) or as a patient (a chart there).
-- A brand-new signup belongs to nothing and so sees nothing, until they join
-- with a clinic's code (join_clinic, 20260914120400).
-- ============================================================================

create or replace function private.is_clinic_member(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
           select 1 from public.clinic_memberships m
           where m.profile_id = auth.uid() and m.clinic_id = p_clinic)
      or exists (
           select 1 from public.patients pt
           join public.persons pe on pe.id = pt.person_id
           where pe.profile_id = auth.uid() and pt.clinic_id = p_clinic);
$$;

grant execute on function private.is_clinic_member(uuid) to authenticated;

drop policy clinics_select_authenticated on public.clinics;
create policy clinics_select_member on public.clinics
  for select to authenticated using (private.is_clinic_member(id));

drop policy doctors_select_authenticated on public.doctors;
create policy doctors_select_member on public.doctors
  for select to authenticated using (private.is_clinic_member(clinic_id));

drop policy services_select_authenticated on public.services;
create policy services_select_member on public.services
  for select to authenticated using (private.is_clinic_member(clinic_id));
