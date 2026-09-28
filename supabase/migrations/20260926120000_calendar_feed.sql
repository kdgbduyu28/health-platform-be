-- Calendar feed: a patient's visits in their own calendar app.
--
-- Each patient account can have one private feed URL, served as iCalendar by
-- the calendar-feed Edge Function (supabase/functions/calendar-feed). Google
-- Calendar, Apple Calendar and Outlook subscribe to it once and re-read it on
-- their own schedule, so booked, moved and cancelled visits follow without the
-- patient doing anything. Google re-reads a feed only every few hours; the
-- apps also offer a one-off "add to calendar" per visit, which needs nothing
-- from the database.
--
-- A calendar app cannot sign in, so the URL carries a long random token and
-- the token is the credential: whoever holds the URL can read the feed.
-- That is why the feed is deliberately thin (clinic, doctor, time; never the
-- service booked, notes or bills), and why the patient can reset the token,
-- which kills every copy of the old URL at once.
--
-- The feed covers every chart the account has, at every clinic: one calendar
-- for the person, not one per clinic.

-- ── 1. Table ───────────────────────────────────────────────────────────────

create table public.calendar_feeds (
  profile_id      uuid primary key references public.profiles (id) on delete cascade,
  token           text not null unique,
  created_at      timestamptz not null default now(),
  -- When a calendar app last read it: lets a patient see the feed is alive.
  last_fetched_at timestamptz
);

-- 256 bits from two v4 UUIDs (244 random), hex: fits in a URL as it is.
create or replace function private.new_feed_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
$$;

revoke all on function private.new_feed_token() from public, anon, authenticated;

-- ── 2. Row Level Security ──────────────────────────────────────────────────
-- Written only by the functions below.

alter table public.calendar_feeds enable row level security;

create policy calendar_feeds_select_own on public.calendar_feeds
  for select to authenticated using (profile_id = auth.uid());

-- ── 3. The patient's side ──────────────────────────────────────────────────

-- The signed-in account's feed token, made on first ask.
create or replace function public.my_calendar_feed_token()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  insert into public.calendar_feeds (profile_id, token)
  values (auth.uid(), private.new_feed_token())
  on conflict (profile_id) do nothing;

  select f.token into v_token from public.calendar_feeds f where f.profile_id = auth.uid();
  return v_token;
end;
$$;

-- A new URL; the old one stops working at once. For a URL shared by mistake,
-- or a phone that was lost.
create or replace function public.reset_calendar_feed_token()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text := private.new_feed_token();
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  insert into public.calendar_feeds (profile_id, token)
  values (auth.uid(), v_token)
  on conflict (profile_id) do update
    set token = excluded.token, created_at = now(), last_fetched_at = null;
  return v_token;
end;
$$;

revoke all on function public.my_calendar_feed_token() from public, anon;
revoke all on function public.reset_calendar_feed_token() from public, anon;
grant execute on function public.my_calendar_feed_token() to authenticated;
grant execute on function public.reset_calendar_feed_token() to authenticated;

-- ── 4. The feed ────────────────────────────────────────────────────────────
-- Read by the Edge Function with the service role; nobody else may call it,
-- so a token can be checked only by fetching the feed.
--
-- Visits from 90 days ago onwards. Cancelled visits and no-shows are left
-- out: a calendar drops an event that disappears from its feed. An unknown
-- token raises no_data_found (P0002), which the function answers with 404;
-- a known feed with no visits is simply empty.

create or replace function public.calendar_feed_events(p_token text)
returns table (
  appointment_id  uuid,
  status          public.appointment_status,
  scheduled_at    timestamptz,
  ends_at         timestamptz,
  updated_at      timestamptz,
  clinic_name     text,
  clinic_address  text,
  clinic_phone    text,
  clinic_slug     text,
  doctor_name     text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
begin
  update public.calendar_feeds f
     set last_fetched_at = now()
   where f.token = p_token
  returning f.profile_id into v_profile;

  if v_profile is null then
    raise exception 'No such calendar feed.' using errcode = 'P0002';
  end if;

  return query
    select a.id, a.status, a.scheduled_at, a.ends_at, a.updated_at,
           c.name, c.address, c.contact_phone, c.slug, d.full_name
      from public.persons pe
      join public.patients pt on pt.person_id = pe.id
      join public.appointments a on a.patient_id = pt.id
      join public.clinics c on c.id = a.clinic_id
      join public.doctors d on d.id = a.doctor_id
     where pe.profile_id = v_profile
       and a.status not in ('cancelled', 'no_show')
       and a.scheduled_at >= now() - interval '90 days'
     order by a.scheduled_at;
end;
$$;

revoke all on function public.calendar_feed_events(text) from public, anon, authenticated;
grant execute on function public.calendar_feed_events(text) to service_role;
