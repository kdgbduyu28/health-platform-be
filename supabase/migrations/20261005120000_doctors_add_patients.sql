-- ============================================================================
-- health-platform · doctors add patients too
--
-- Until now only the front desk and admins could create a chart
-- (private.can_register_patients). A doctor seeing someone the desk never
-- registered — a relative squeezed in after hours, a patient at a clinic
-- with no receptionist — had to wait for someone else to add them.
--
-- Now every staff role may add a patient: the person, their chart here, and
-- the form (register_patient, which is SECURITY INVOKER, so these policies
-- are what decide). The same policies make a doctor's walk-in booking of a
-- new patient work, since book_walk_in creates the chart the same way.
--
-- What does NOT change: CSV import and export stay with the front desk and
-- admins. Those functions are SECURITY DEFINER and check
-- private.can_register_patients themselves, which is left as it is.
-- ============================================================================

-- May add a patient at this clinic: any staff role.
create or replace function private.can_add_patients(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = auth.uid()
      and m.clinic_id = p_clinic
      and m.role in ('doctor', 'assistant', 'admin')
  );
$$;

grant execute on function private.can_add_patients(uuid) to authenticated;

-- May add patients somewhere: the gate for creating a person, who has no
-- clinic of their own. Only persons_insert_staff reads it.
create or replace function private.is_registrar()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = auth.uid()
      and m.role in ('doctor', 'assistant', 'admin')
  );
$$;

drop policy patients_insert_staff on public.patients;
create policy patients_insert_staff on public.patients
  for insert to authenticated with check (
    private.can_add_patients(clinic_id)
    and private.person_is_linkable(person_id)
  );

comment on function private.can_register_patients(uuid) is
  'Front desk and admins: CSV import and export of patients, visits and dental charts. '
  'Adding a single patient is private.can_add_patients (every staff role).';
