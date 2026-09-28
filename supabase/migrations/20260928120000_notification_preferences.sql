-- Notification preferences: which kinds of notification an account does not
-- want, per app.
--
-- A muted kind is not written at all — no inbox row, so no push either. That
-- is simpler to reason about than "in the inbox but not pushed", and it is
-- what people mean when they switch a kind off in Settings.
--
-- One row per muted (account, app, kind); no row means "on", so every
-- account starts with everything on and this table stays small. Per app,
-- because one account can be a doctor in one app and a patient in another,
-- and wanting fewer pings as staff says nothing about wanting fewer as a
-- patient.
--
-- Push on/off for a device is not stored here: that is the browser's
-- subscription (public.push_subscriptions), which the apps already manage.

create table public.notification_mutes (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  app        public.app_role not null,
  kind       text not null check (kind in (
    'booking_requested', 'visit_confirmed', 'visit_moved', 'visit_cancelled',
    'visit_reminder', 'patient_arrived', 'patient_note', 'invoice_issued'
  )),
  created_at timestamptz not null default now(),
  primary key (profile_id, app, kind)
);

alter table public.notification_mutes enable row level security;

create policy notification_mutes_select_own on public.notification_mutes
  for select to authenticated using (profile_id = auth.uid());

create policy notification_mutes_insert_own on public.notification_mutes
  for insert to authenticated with check (profile_id = auth.uid());

create policy notification_mutes_delete_own on public.notification_mutes
  for delete to authenticated using (profile_id = auth.uid());

-- Same as 20260924120200_notifications, plus the mute check.
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
  -- They switched this kind off in Settings.
  if exists (select 1 from public.notification_mutes m
              where m.profile_id = p_profile_id and m.app = p_app and m.kind = p_kind) then
    return;
  end if;
  insert into public.notifications
    (profile_id, app, clinic_id, kind, title, body, link, appointment_id)
  values
    (p_profile_id, p_app, p_clinic_id, p_kind, p_title, p_body, p_link, p_appointment_id);
end;
$$;
