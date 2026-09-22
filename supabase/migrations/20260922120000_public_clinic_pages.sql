-- Public clinic pages: /:clinic in every app.
--
-- Each app now puts the clinic's slug first in its URLs (/dtouchdental,
-- /dtouchdental/book, …), and the patient app shows a landing page at
-- /:clinic to visitors who are not signed in. Until now `anon` could read
-- nothing, so there was no way to draw that page.
--
-- Two halves:
--
--   1. public.clinic_by_slug — the ENTIRE anonymous surface. It returns what a
--      clinic would print on its own website: name, branding, contact details,
--      active services and active doctors. Never the join code (that is what
--      admits a patient), never an inactive clinic, never a patient or a
--      staff account. Security definer precisely so that no RLS policy has to
--      open a table to anon; review it as carefully as a policy.
--
--   2. Reserved slugs. A slug is the first path segment, so a clinic called
--      "Not Found" must not be able to shadow the /not-found route. Slugs stay
--      operator-only (outside the admin UPDATE grant), so this only stops the
--      operator making that mistake.

-- ── 1. Reserved slugs ───────────────────────────────────────────────────────

alter table public.clinics
  add constraint clinics_slug_not_reserved
    check (slug not in (
      -- Top-level routes the apps own, and ones kept free for them.
      'not-found', 'sign-in', 'sign-up', 'sign-out', 'reset-password',
      'join', 'book', 'home', 'settings', 'account', 'profile',
      'admin', 'doctor', 'desk', 'assistant', 'patient', 'staff',
      -- Hosting, tooling and the web in general.
      'api', 'app', 'assets', 'static', 'public', 'auth', 'www',
      'help', 'support', 'about', 'privacy', 'terms', 'favicon.ico'
    )),
  add constraint clinics_slug_length
    check (char_length(slug) between 3 and 63);

-- ── 2. The public page ──────────────────────────────────────────────────────

-- Shaped like `clinics?select=*,clinic_type:clinic_types(...)` so the apps'
-- existing Clinic.fromJson reads it unchanged, plus `services` and `doctors`.
-- Null when no ACTIVE clinic has that slug: a suspended clinic's link should
-- look exactly like a mistyped one.
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
               'is_active',        s.is_active)
             order by s.name)
      from public.services s
      where s.clinic_id = c.id and s.is_active), '[]'::jsonb),
    -- Name, specialty and working days only: not the linked account.
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

comment on function public.clinic_by_slug(text) is
  'Public landing-page data for one active clinic. Callable by anon. Never returns join_code.';

revoke all on function public.clinic_by_slug(text) from public;
grant execute on function public.clinic_by_slug(text) to anon, authenticated;
