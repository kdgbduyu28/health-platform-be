-- ============================================================================
-- health-platform · the patient list as a working table
--
-- The directory showed a name, a phone and a visit count. A clinic runs its
-- follow-ups from that list, so search_patients now also returns, for every
-- chart:
--
--   first / last / next visit, the doctor and service at the last one,
--   what the patient still owes, open treatment plan items, age,
--   and the remarks the desk works from (flags):
--
--     recall      last completed visit more than the clinic's recall
--                 interval ago (clinics.recall_months, default 6), and
--                 nothing booked
--     balance     money still owed on an issued bill (drafts do not count)
--     no_contact  neither a phone nor an email on file
--     attention   one of `attention` (below) holds:
--                   unbooked_plan    planned dental work, nothing booked
--                   no_show          the last visit was a no-show
--                   overdue_balance  a bill unpaid 30+ days after issue
--     pedia       under 18
--     adult       18 or over (neither, without a date of birth)
--
-- It filters (every flag in p_filters must hold), sorts (p_sort, p_desc) and
-- counts each flag over the search, so the list's filter chips carry numbers.
--
-- Still SECURITY INVOKER: RLS decides what counts. Every clinic role reads
-- invoices (invoices_select_staff), so doctors see balances too — as the
-- clinic asked.
--
-- The old four-argument call keeps working: the new arguments default.
-- ============================================================================

-- ── 1. The recall interval, a clinic setting ───────────────────────────────

alter table public.clinics
  add column recall_months smallint not null default 6
    constraint clinics_recall_months_range check (recall_months between 1 and 36);

grant update (recall_months) on public.clinics to authenticated;

-- ── 2. search_patients ──────────────────────────────────────────────────────
-- A new signature, so the old one goes: two overloads that both accept the
-- four-argument call would be ambiguous to PostgREST.

drop function if exists public.search_patients(uuid, text, int, int);

create or replace function public.search_patients(
  p_clinic_id uuid,
  p_query     text    default null,
  p_limit     int     default 30,
  p_offset    int     default 0,
  p_filters   text[]  default null,
  p_sort      text    default 'name',
  p_desc      boolean default false
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
      private.local_digits(p_query)            as digits,
      coalesce((select c.recall_months from public.clinics c
                 where c.id = p_clinic_id), 6) as recall_months
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
  stats as (
    select
      m.id, m.pt, m.pe,
      v.completed_visits, v.first_visit_at, v.last_visit_at, v.next_visit_at,
      l.last_status, l.last_service, l.last_doctor,
      b.balance, b.oldest_unpaid_at,
      d.planned_count,
      case when (m.pe).date_of_birth is null then null
           else extract(year from age(current_date, (m.pe).date_of_birth))::int
      end as age
    from matches m
    cross join lateral (
      select
        count(*) filter (where a.status = 'completed')            as completed_visits,
        min(a.scheduled_at) filter (where a.status = 'completed')  as first_visit_at,
        max(a.scheduled_at) filter (where a.status = 'completed')  as last_visit_at,
        min(a.scheduled_at) filter (
          where a.scheduled_at > now()
            and a.status not in ('cancelled', 'no_show'))         as next_visit_at
      from public.appointments a
      where a.patient_id = m.id
    ) v
    -- How the most recent visit that is over turned out.
    left join lateral (
      select a.status, a.service_name, dr.full_name
      from public.appointments a
      join public.doctors dr on dr.id = a.doctor_id
      where a.patient_id = m.id
        and a.scheduled_at <= now()
        and a.status in ('completed', 'no_show')
      order by a.scheduled_at desc
      limit 1
    ) l (last_status, last_service, last_doctor) on true
    cross join lateral (
      select
        coalesce(sum(i.balance), 0)                                 as balance,
        min(coalesce(i.issued_at, i.created_at)) filter (where i.balance > 0)
                                                                    as oldest_unpaid_at
      from public.invoices i
      where i.patient_id = m.id and i.status = 'issued'
    ) b
    cross join lateral (
      select count(*) as planned_count
      from public.dental_chart_entries e
      where e.patient_id = m.id and e.status = 'planned'
    ) d
  ),
  attention as (
    select s.*,
      array_remove(array[
        case when s.planned_count > 0 and s.next_visit_at is null
             then 'unbooked_plan' end,
        case when s.last_status = 'no_show' then 'no_show' end,
        case when s.oldest_unpaid_at < now() - interval '30 days'
             then 'overdue_balance' end
      ], null) as reasons
    from stats s
  ),
  flagged as (
    select a.*,
      array_remove(array[
        case when a.last_visit_at < now() - make_interval(months => q.recall_months)
              and a.next_visit_at is null then 'recall' end,
        case when a.balance > 0 then 'balance' end,
        case when coalesce(btrim((a.pe).phone), '') = ''
              and coalesce(btrim((a.pe).email), '') = '' then 'no_contact' end,
        case when cardinality(a.reasons) > 0 then 'attention' end,
        case when a.age < 18 then 'pedia' when a.age >= 18 then 'adult' end
      ], null) as flags
    from attention a
    cross join q
  ),
  filtered as (
    select f.*,
      case coalesce(p_sort, 'name')
        when 'last_visit'  then extract(epoch from f.last_visit_at)
        when 'first_visit' then extract(epoch from f.first_visit_at)
        when 'next_visit'  then extract(epoch from f.next_visit_at)
        when 'balance'     then f.balance
        when 'visits'      then f.completed_visits::numeric
        when 'age'         then f.age::numeric
      end as sort_key
    from flagged f
    where p_filters is null or f.flags @> p_filters
  ),
  ordered as (
    select f.*,
      row_number() over (
        order by
          case when not coalesce(p_desc, false) then f.sort_key end asc nulls last,
          case when coalesce(p_desc, false)     then f.sort_key end desc nulls last,
          case when coalesce(p_desc, false) and coalesce(p_sort, 'name') = 'name'
               then lower((f.pe).full_name) end desc,
          lower((f.pe).full_name), f.id
      ) as rn
    from filtered f
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'counts', (
      select jsonb_build_object(
        'all',        count(*),
        'recall',     count(*) filter (where 'recall'     = any(flags)),
        'balance',    count(*) filter (where 'balance'    = any(flags)),
        'no_contact', count(*) filter (where 'no_contact' = any(flags)),
        'attention',  count(*) filter (where 'attention'  = any(flags)),
        'pedia',      count(*) filter (where 'pedia'      = any(flags)),
        'adult',      count(*) filter (where 'adult'      = any(flags)))
      from flagged),
    'patients', coalesce((
      select jsonb_agg(
        to_jsonb(o.pt)
          || jsonb_build_object(
               'person',             to_jsonb(o.pe),
               'completed_visits',   o.completed_visits,
               'first_visit_at',     o.first_visit_at,
               'last_visit_at',      o.last_visit_at,
               'next_visit_at',      o.next_visit_at,
               'last_visit_status',  o.last_status,
               'last_visit_service', o.last_service,
               'last_visit_doctor',  o.last_doctor,
               'balance',            o.balance,
               'planned_count',      o.planned_count,
               'age',                o.age,
               'flags',              to_jsonb(o.flags),
               'attention',          to_jsonb(o.reasons))
        order by o.rn)
      from ordered o
      where o.rn >  greatest(coalesce(p_offset, 0), 0)
        and o.rn <= greatest(coalesce(p_offset, 0), 0)
                    + greatest(1, least(coalesce(p_limit, 30), 100))), '[]'::jsonb));
$$;

revoke all on function public.search_patients(uuid, text, int, int, text[], text, boolean)
  from public, anon;
grant execute on function public.search_patients(uuid, text, int, int, text[], text, boolean)
  to authenticated;

-- Bills are summed per chart on every list page.
create index if not exists invoices_patient_status_idx
  on public.invoices (patient_id, status);
