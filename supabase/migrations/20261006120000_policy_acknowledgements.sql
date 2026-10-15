-- ============================================================================
-- health-platform · Privacy Policy and Terms acknowledgements (RA 10173)
--
-- The Data Privacy Act gives everyone the right to be informed BEFORE their
-- data is collected (RA 10173 §16(a); IRR §34). The create-account form shows
-- the platform's Privacy Policy and its Terms and Conditions, and will not
-- submit until the box is ticked. This records that it was, and which
-- version of each the person saw, so the platform can show who was told
-- what, and when — and ask again when either changes.
--
-- This is not consent to health processing. An account runs on the contract
-- the person asked for (§12(b)); consent to process HEALTH information
-- (§13(a)) is asked for separately, per clinic, on the patient information
-- form (patient_intakes.consent_at, 20260927120000). The NPC's guidance is
-- to keep the two apart rather than bundle them into one tick.
--
--   document   'privacy' (the Privacy Policy) or 'terms'
--   version    the document's date, `2026-09-30`, matching the `version` of
--              PrivacyPolicy / TermsAndConditions in the apps
--
-- How rows get here:
--   sign-up    handle_new_user reads `privacy_policy_version` and
--              `terms_version` from the sign-up metadata. The time is the
--              server's; the version is the app's word for what it showed.
--              A missing or malformed one records nothing — a sign-up is
--              never refused over it, or the builds already deployed could
--              not sign anyone up.
--   later      acknowledge_policy(document, version), from the apps, for
--              accounts made before this (or before a newer version).
--
-- Who reads it: the person themself. Nobody updates or deletes a row; it goes
-- with the account (on delete cascade), like the rest of the profile.
-- ============================================================================

create table public.policy_acknowledgements (
  id               bigint generated always as identity primary key,
  profile_id       uuid not null references public.profiles (id) on delete cascade,
  document         text not null
    constraint policy_ack_document_valid
      check (document in ('privacy', 'terms')),
  version          text not null
    constraint policy_ack_version_valid
      check (version ~ '^\d{4}-\d{2}-\d{2}$'),
  acknowledged_at  timestamptz not null default now(),
  source           text not null
    constraint policy_ack_source_valid
      check (source in ('sign_up', 'app')),
  constraint policy_ack_once_per_version unique (profile_id, document, version)
);

alter table public.policy_acknowledgements enable row level security;

create policy policy_ack_select_own on public.policy_acknowledgements
  for select to authenticated
  using (profile_id = (select auth.uid()));

-- Written only by the definer functions below.
revoke insert, update, delete on public.policy_acknowledgements
  from anon, authenticated;

-- ── Sign-up ────────────────────────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(
      nullif(v_meta ->> 'full_name', ''),
      split_part(coalesce(new.email, 'user'), '@', 1)
    ),
    new.email
  );

  insert into public.policy_acknowledgements (profile_id, document, version, source)
  select new.id, d.document, d.version, 'sign_up'
    from (values ('privacy', v_meta ->> 'privacy_policy_version'),
                 ('terms',   v_meta ->> 'terms_version')) as d (document, version)
   where d.version ~ '^\d{4}-\d{2}-\d{2}$';
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

-- ── Later ──────────────────────────────────────────────────────────────────
-- Idempotent: acknowledging the same version twice keeps the first time.
create or replace function public.acknowledge_policy(p_document text, p_version text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_document is null or p_document not in ('privacy', 'terms') then
    raise exception 'not a policy document: %', p_document
      using errcode = '22023';
  end if;
  if p_version is null or p_version !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'not a policy version: %', p_version
      using errcode = '22023';
  end if;

  insert into public.policy_acknowledgements (profile_id, document, version, source)
  values (auth.uid(), p_document, p_version, 'app')
  on conflict on constraint policy_ack_once_per_version do nothing;
end;
$$;

revoke all on function public.acknowledge_policy(text, text) from public, anon;
grant execute on function public.acknowledge_policy(text, text) to authenticated;
