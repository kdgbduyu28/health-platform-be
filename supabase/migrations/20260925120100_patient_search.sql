-- ============================================================================
-- health-platform · patient search, a page at a time
--
-- The staff apps loaded every chart at the clinic and every appointment the
-- clinic ever had, then searched and counted visits on the device. That is
-- fine for a demo clinic and a problem for a real one after a year: the
-- directory, the walk-in form and the billing picker each paid for the whole
-- patient list on every open.
--
-- search_patients() does the searching, sorting, paging and per-patient visit
-- stats in the database and returns one page, shaped like the apps' existing
-- `patients?select=*,person:persons(*)` rows plus the stats and a total.
--
-- SECURITY INVOKER: RLS decides which charts and visits count, exactly as for
-- a direct query. A caller who is not staff at the clinic gets an empty page.
-- ============================================================================

-- Digits only, with the Philippine +63 prefix rewritten to the local 0, so
-- "+63 917 123 4567" and "0917-123-4567" compare equal. Mirrors the apps'
-- phone matching.
create or replace function private.local_digits(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when d ~ '^63[0-9]{10}$' then '0' || substr(d, 3) else d end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x;
$$;

create or replace function public.search_patients(
  p_clinic_id uuid,
  p_query     text default null,
  p_limit     int  default 30,
  p_offset    int  default 0
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (
    select
      -- LIKE wildcards in what someone typed are literal characters.
      replace(replace(replace(nullif(btrim(p_query), ''),
        '\', '\\'), '%', '\%'), '_', '\_')    as pattern,
      private.local_digits(p_query)            as digits
  ),
  matches as (
    select pt.id, pt, pe
    from public.patients pt
    join public.persons pe on pe.id = pt.person_id
    cross join q
    where pt.clinic_id = p_clinic_id
      and (q.pattern is null
           or pe.full_name ilike '%' || q.pattern || '%'
           or pe.email     ilike '%' || q.pattern || '%'
           -- Three digits before a number search kicks in: "1" matches
           -- everyone.
           or (length(q.digits) >= 3
               and private.local_digits(pe.phone) like '%' || q.digits || '%'))
  ),
  page as (
    select m.*
    from matches m
    order by lower((m.pe).full_name), m.id
    limit greatest(1, least(coalesce(p_limit, 30), 100))
    offset greatest(coalesce(p_offset, 0), 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from matches),
    'patients', coalesce(jsonb_agg(
      to_jsonb(p.pt)
        || jsonb_build_object(
             'person',           to_jsonb(p.pe),
             'completed_visits', s.completed_visits,
             'last_visit_at',    s.last_visit_at,
             'next_visit_at',    s.next_visit_at)
      order by lower((p.pe).full_name), p.id), '[]'::jsonb))
  from page p
  cross join lateral (
    select
      count(*) filter (where a.status = 'completed')           as completed_visits,
      max(a.scheduled_at) filter (where a.status = 'completed') as last_visit_at,
      min(a.scheduled_at) filter (
        where a.scheduled_at > now()
          and a.status not in ('cancelled', 'no_show'))        as next_visit_at
    from public.appointments a
    where a.patient_id = p.id
  ) s;
$$;

revoke all on function public.search_patients(uuid, text, int, int) from public, anon;
grant execute on function public.search_patients(uuid, text, int, int) to authenticated;

-- Past visits are now read a page at a time, newest first, per clinic and
-- per doctor.
create index if not exists appointments_clinic_scheduled_idx
  on public.appointments (clinic_id, scheduled_at desc);
