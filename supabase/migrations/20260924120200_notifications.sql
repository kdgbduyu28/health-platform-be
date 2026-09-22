-- Notifications: an in-app inbox for every account, and Web Push on the
-- devices that opted in.
--
-- Supabase has no push service of its own. The pieces used here are its
-- standard ones:
--
--   triggers (below)      decide who hears about what, and write a row to
--                         public.notifications — the inbox, which works with
--                         or without push, and is live over Realtime.
--   pg_net                on each new row, POSTs its id to the send-push Edge
--                         Function (supabase/functions/send-push).
--   send-push             signs a Web Push message with the platform's VAPID
--                         key and sends it to that account's subscribed
--                         browsers for the app the notification is for.
--   pg_cron               sends the day-before reminders, and prunes the
--                         inbox.
--
-- The apps are web builds, so this is standard Web Push (VAPID): no Firebase
-- project, no app-store builds. On iPhone, Web Push reaches only a site
-- added to the home screen (iOS 16.4+); the inbox reaches everyone.
--
-- pg_net and pg_cron exist only on a real Supabase project. Where they are
-- missing (the throwaway test cluster) this migration still applies: the
-- inbox fills, nothing is sent, no reminders are scheduled. Delivery also
-- stays off until the two Vault secrets it reads exist — see the README.
--
-- Who hears what:
--   patient      their visit confirmed, moved or cancelled by the clinic; a
--                note from the doctor; a bill issued; a reminder the day
--                before a confirmed visit.
--   front desk   (assistants and admins) a patient's booking request, move
--                or cancellation.
--   doctor       their patient is in the waiting room.
-- Nobody is told about what they did themselves, and the service role
-- (seeds, the dashboard) notifies no one.

-- ── 1. Tables ──────────────────────────────────────────────────────────────

create table public.notifications (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id) on delete cascade,
  -- Which app it belongs in, and so which subscriptions it is pushed to: one
  -- account can be a doctor in one app and a patient in another.
  app            public.app_role not null,
  clinic_id      uuid references public.clinics (id) on delete cascade,
  kind           text not null,
  title          text not null,
  body           text not null,
  -- Where tapping it goes: a path in that app, clinic slug included.
  link           text,
  appointment_id uuid references public.appointments (id) on delete cascade,
  created_at     timestamptz not null default now(),
  read_at        timestamptz,
  pushed_at      timestamptz
);

create index notifications_inbox_idx
  on public.notifications (profile_id, app, created_at desc);

create table public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references public.profiles (id) on delete cascade,
  app          public.app_role not null,
  -- The browser's push service URL. One browser, one row: whoever signed in
  -- last on it owns it.
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  user_agent   text,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);

create index push_subscriptions_profile_idx on public.push_subscriptions (profile_id, app);

alter table public.appointments add column reminded_at timestamptz;

-- ── 2. Row Level Security ──────────────────────────────────────────────────
-- Rows are written by the definer functions below, never by clients.

alter table public.notifications      enable row level security;
alter table public.push_subscriptions enable row level security;

create policy notifications_select_own on public.notifications
  for select to authenticated using (profile_id = auth.uid());

create policy notifications_update_own on public.notifications
  for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy push_subscriptions_select_own on public.push_subscriptions
  for select to authenticated using (profile_id = auth.uid());

create policy push_subscriptions_delete_own on public.push_subscriptions
  for delete to authenticated using (profile_id = auth.uid());

-- Marking read is the only change a client makes to its inbox.
create or replace function private.guard_notification_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated'
     and (to_jsonb(new) - 'read_at') is distinct from (to_jsonb(old) - 'read_at') then
    raise exception 'Only read_at can be changed on a notification.';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_notification_update() from public, anon, authenticated;

create trigger notifications_guard_update
  before update on public.notifications
  for each row execute function private.guard_notification_update();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;

-- ── 3. Subscribing a browser ───────────────────────────────────────────────
-- Security definer because the endpoint may still be registered to whoever
-- used this browser before; it becomes the caller's, never shared.

create or replace function public.save_push_subscription(
  p_app        public.app_role,
  p_endpoint   text,
  p_p256dh     text,
  p_auth       text,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if p_endpoint !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'That is not a push subscription.';
  end if;

  insert into public.push_subscriptions (profile_id, app, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_app, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set profile_id = excluded.profile_id,
        app        = excluded.app,
        p256dh     = excluded.p256dh,
        auth       = excluded.auth,
        user_agent = excluded.user_agent,
        created_at = now();
end;
$$;

-- Called on sign-out, so the next person on this browser does not receive
-- the last one's notifications.
create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_subscriptions
   where endpoint = p_endpoint and profile_id = auth.uid();
$$;

revoke all on function public.save_push_subscription(public.app_role, text, text, text, text) from public, anon;
revoke all on function public.delete_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(public.app_role, text, text, text, text) to authenticated;
grant execute on function public.delete_push_subscription(text) to authenticated;

-- ── 4. Writing a notification ──────────────────────────────────────────────

create or replace function private.notify(
  p_profile_id     uuid,
  p_app            public.app_role,
  p_clinic_id      uuid,
  p_kind           text,
  p_title          text,
  p_body           text,
  p_link           text,
  p_appointment_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A walk-in has no account to tell; nobody is told about their own act.
  if p_profile_id is null or p_profile_id = auth.uid() then
    return;
  end if;
  insert into public.notifications
    (profile_id, app, clinic_id, kind, title, body, link, appointment_id)
  values
    (p_profile_id, p_app, p_clinic_id, p_kind, p_title, p_body, p_link, p_appointment_id);
end;
$$;

-- Everyone at the front desk: assistants in the assistant app, admins in the
-- admin app, each opening the page they would handle it from.
create or replace function private.notify_front_desk(
  p_clinic_id      uuid,
  p_kind           text,
  p_title          text,
  p_body           text,
  p_appointment_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slug text;
  r      record;
begin
  select c.slug into v_slug from public.clinics c where c.id = p_clinic_id;
  for r in
    select m.profile_id, m.role from public.clinic_memberships m
     where m.clinic_id = p_clinic_id and m.role in ('assistant', 'admin')
  loop
    perform private.notify(
      r.profile_id, r.role, p_clinic_id, p_kind, p_title, p_body,
      case r.role
        when 'admin' then '/' || v_slug || '/appointments/' || p_appointment_id
        else '/' || v_slug || '/check-in'
      end,
      p_appointment_id);
  end loop;
end;
$$;

-- "Mon, Sep 29 at 9:00 AM" on the clinic's clock.
create or replace function private.visit_time_label(p_at timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_at at time zone p_tz, 'Dy, Mon FMDD "at" FMHH12:MI AM');
$$;

revoke all on function private.notify(uuid, public.app_role, uuid, text, text, text, text, uuid) from public, anon, authenticated;
revoke all on function private.notify_front_desk(uuid, text, text, text, uuid) from public, anon, authenticated;

-- ── 5. Visits ──────────────────────────────────────────────────────────────

create or replace function private.notify_appointment_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slug       text;
  v_tz         text;
  v_patient    uuid;   -- the patient's account, if they have one
  v_name       text;
  v_doctor     uuid;   -- the doctor's account
  v_doctor_nm  text;
  v_by_staff   boolean;
  v_when       text;
  v_link       text;
begin
  if auth.uid() is null then
    return null;
  end if;

  select c.slug, c.timezone into v_slug, v_tz from public.clinics c where c.id = new.clinic_id;
  select pe.profile_id, pe.full_name into v_patient, v_name
    from public.patients pt join public.persons pe on pe.id = pt.person_id
   where pt.id = new.patient_id;
  select d.profile_id, d.full_name into v_doctor, v_doctor_nm
    from public.doctors d where d.id = new.doctor_id;

  v_by_staff := private.is_clinic_staff(new.clinic_id);
  v_when     := private.visit_time_label(new.scheduled_at, v_tz);
  v_link     := '/' || v_slug || '/appointments/' || new.id;

  if tg_op = 'INSERT' then
    if not v_by_staff then
      perform private.notify_front_desk(new.clinic_id, 'booking_requested',
        'New booking request',
        v_name || ' · ' || new.service_name || ' · ' || v_when, new.id);
    end if;
    return null;
  end if;

  if new.scheduled_at is distinct from old.scheduled_at
     or new.doctor_id is distinct from old.doctor_id then
    if v_by_staff then
      perform private.notify(v_patient, 'patient', new.clinic_id, 'visit_moved',
        'Your visit has moved',
        new.service_name || ' is now ' || v_when || ' with Dr. ' || v_doctor_nm || '.',
        v_link, new.id);
    else
      perform private.notify_front_desk(new.clinic_id, 'visit_moved',
        'Visit moved — please confirm',
        v_name || ' moved ' || new.service_name || ' from '
          || private.visit_time_label(old.scheduled_at, v_tz) || ' to ' || v_when || '.',
        new.id);
    end if;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'confirmed' and old.status = 'pending' then
      perform private.notify(v_patient, 'patient', new.clinic_id, 'visit_confirmed',
        'Visit confirmed',
        new.service_name || ' on ' || v_when || ' with Dr. ' || v_doctor_nm || '.',
        v_link, new.id);
    elsif new.status = 'cancelled' and v_by_staff then
      perform private.notify(v_patient, 'patient', new.clinic_id, 'visit_cancelled',
        'Visit cancelled',
        'The clinic cancelled ' || new.service_name || ' on ' || v_when
          || '. Book another time from the app.',
        v_link, new.id);
    elsif new.status = 'cancelled' then
      perform private.notify_front_desk(new.clinic_id, 'visit_cancelled',
        'Visit cancelled by patient',
        v_name || ' cancelled ' || new.service_name || ' on ' || v_when || '.', new.id);
    elsif new.status = 'arrived' then
      perform private.notify(v_doctor, 'doctor', new.clinic_id, 'patient_arrived',
        v_name || ' is here',
        new.service_name || ' at ' || to_char(new.scheduled_at at time zone v_tz, 'FMHH12:MI AM')
          || ' — in the waiting room.',
        v_link, new.id);
    end if;
  end if;

  if nullif(trim(new.patient_note), '') is not null
     and new.patient_note is distinct from old.patient_note then
    perform private.notify(v_patient, 'patient', new.clinic_id, 'patient_note',
      'A note from Dr. ' || v_doctor_nm,
      left(new.patient_note, 140), v_link, new.id);
  end if;

  return null;
end;
$$;

revoke all on function private.notify_appointment_change() from public, anon, authenticated;

create trigger appointments_notify
  after insert or update of status, scheduled_at, doctor_id, patient_note
  on public.appointments
  for each row execute function private.notify_appointment_change();

-- A moved visit is reminded about again, at its new time.
create or replace function private.reset_reminder()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.reminded_at := null;
  return new;
end;
$$;

revoke all on function private.reset_reminder() from public, anon, authenticated;

create trigger appointments_reset_reminder
  before update of scheduled_at on public.appointments
  for each row
  when (new.scheduled_at is distinct from old.scheduled_at)
  execute function private.reset_reminder();

-- ── 6. Bills ───────────────────────────────────────────────────────────────

create or replace function private.notify_invoice_issued()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slug    text;
  v_patient uuid;
begin
  select c.slug into v_slug from public.clinics c where c.id = new.clinic_id;
  select pe.profile_id into v_patient
    from public.patients pt join public.persons pe on pe.id = pt.person_id
   where pt.id = new.patient_id;
  perform private.notify(v_patient, 'patient', new.clinic_id, 'invoice_issued',
    'Your bill is ready',
    new.number || ' · ₱' || to_char(new.total, 'FM999,999,990.00')
      || case when new.status = 'paid' then ' · paid' else '' end,
    '/' || v_slug || '/bills/' || new.id, new.appointment_id);
  return null;
end;
$$;

revoke all on function private.notify_invoice_issued() from public, anon, authenticated;

create trigger invoices_notify_issued
  after update of status on public.invoices
  for each row
  when (old.status = 'draft' and new.status in ('issued', 'paid'))
  execute function private.notify_invoice_issued();

-- ── 7. Reminders ───────────────────────────────────────────────────────────
-- Confirmed visits in the next 24 hours, once each. Not for a visit booked
-- or moved in the last two hours: its patient has just seen the time.

create or replace function private.send_visit_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     record;
  v_n   int := 0;
begin
  for r in
    select a.id, a.clinic_id, a.service_name, a.scheduled_at,
           c.slug, c.timezone, c.name as clinic_name,
           pe.profile_id, d.full_name as doctor_name
      from public.appointments a
      join public.clinics  c  on c.id = a.clinic_id
      join public.patients pt on pt.id = a.patient_id
      join public.persons  pe on pe.id = pt.person_id
      join public.doctors  d  on d.id = a.doctor_id
     where a.status = 'confirmed'
       and a.reminded_at is null
       and a.scheduled_at > now()
       and a.scheduled_at <= now() + interval '24 hours'
       and coalesce(a.rescheduled_at, a.created_at) < now() - interval '2 hours'
       for update of a skip locked
  loop
    perform private.notify(r.profile_id, 'patient', r.clinic_id, 'visit_reminder',
      'Reminder: ' || r.service_name,
      private.visit_time_label(r.scheduled_at, r.timezone) || ' with Dr. ' || r.doctor_name
        || ' at ' || r.clinic_name || '.',
      '/' || r.slug || '/appointments/' || r.id, r.id);
    update public.appointments set reminded_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function private.send_visit_reminders() from public, anon, authenticated;

-- ── 8. Delivery ────────────────────────────────────────────────────────────
-- Hands each new notification to the send-push function. Reads the
-- function's URL and a shared secret from Vault, so neither is in the repo;
-- without them (or without pg_net) it does nothing and the inbox still
-- works. Dynamic SQL, so this compiles on a cluster with neither.

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
end;
$$;

create or replace function private.push_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null
     or to_regclass('vault.decrypted_secrets') is null then
    return null;
  end if;
  execute $q$select max(decrypted_secret) filter (where name = 'push_function_url'),
                    max(decrypted_secret) filter (where name = 'push_webhook_secret')
               from vault.decrypted_secrets$q$
     into v_url, v_secret;
  if v_url is null or v_secret is null then
    return null;
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)'
    using v_url,
          jsonb_build_object('notification_id', new.id),
          jsonb_build_object('Content-Type', 'application/json',
                             'x-push-secret', v_secret);
  return null;
end;
$$;

revoke all on function private.push_notification() from public, anon, authenticated;

create trigger notifications_push
  after insert on public.notifications
  for each row execute function private.push_notification();

-- ── 9. Schedules ───────────────────────────────────────────────────────────

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('visit-reminders', '*/15 * * * *',
                          'select private.send_visit_reminders()');
    perform cron.schedule('prune-notifications', '17 3 * * *',
                          $q$delete from public.notifications
                              where created_at < now() - interval '90 days'$q$);
  end if;
end;
$$;
