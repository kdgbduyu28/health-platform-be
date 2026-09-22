-- ============================================================================
-- health-platform · staff apply with a code, an admin approves
--
-- Until now a doctor or assistant got in only when an admin typed their email
-- into invite_staff. The applicant could not say "I work here" and the admin
-- had no queue of people waiting. This migration adds both halves:
--
--   create_staff_invite   an admin issues a single-use code for ONE doctor or
--                         assistant (the patient join code stays reusable)
--   redeem_staff_invite   the new hire, signed in, enters it — which files a
--                         request and grants NOTHING yet
--   decide_staff_request  an admin approves (membership created, and for a
--                         doctor a roster row linked) or rejects
--   revoke_staff_invite   an admin withdraws a code or a waiting request
--   my_staff_requests     what the applicant sees while they wait
--
-- It also adds branch admins: an admin membership with `branch_locked`. Inside
-- their branch they are an admin like any other — every RLS policy that checks
-- private.is_clinic_admin still passes — but they cannot create, change or
-- remove admins, and they cannot be an admin at any other clinic.
-- ============================================================================

-- ── 1. Branch admins ────────────────────────────────────────────────────────

alter table public.clinic_memberships
  add column branch_locked boolean not null default false,
  add constraint clinic_memberships_branch_lock_admin_only
    check (not branch_locked or role = 'admin');

-- An admin who may also manage the clinic's admins.
create or replace function private.is_full_admin(p_clinic uuid)
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
      and m.role = 'admin'
      and not m.branch_locked
  );
$$;

grant execute on function private.is_full_admin(uuid) to authenticated;

-- "Last admin" now means last FULL admin. A clinic left with only branch
-- admins would have nobody able to appoint another admin, ever.
create or replace function private.is_last_admin(p_clinic uuid, p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
           select 1 from public.clinic_memberships m
           where m.clinic_id = p_clinic and m.profile_id = p_profile
             and m.role = 'admin' and not m.branch_locked)
     and not exists (
           select 1 from public.clinic_memberships m
           where m.clinic_id = p_clinic and m.profile_id <> p_profile
             and m.role = 'admin' and not m.branch_locked);
$$;

-- The lock is enforced on the table, not only in invite_staff, so the service
-- role and provision_clinic.sql cannot break it by accident either. The
-- advisory lock serialises two admin grants for the same account, which could
-- otherwise each miss the other's uncommitted row.
create or replace function private.enforce_branch_lock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.role <> 'admin' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.profile_id::text, 0));

  if exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = new.profile_id
      and m.clinic_id <> new.clinic_id
      and m.role = 'admin'
      and (new.branch_locked or m.branch_locked)
  ) then
    raise exception 'a branch admin can be an admin at one branch only';
  end if;

  return new;
end;
$$;

revoke all on function private.enforce_branch_lock() from public, anon, authenticated;

create trigger clinic_memberships_branch_lock
  before insert or update of role, branch_locked, profile_id, clinic_id
  on public.clinic_memberships
  for each row execute function private.enforce_branch_lock();

-- ── 2. invite_staff / remove_staff learn about branch admins ────────────────
-- A new parameter changes the signature, and PostgREST cannot pick between two
-- overloads that both accept the old arguments, so the old one is dropped.

drop function public.invite_staff(uuid, text, public.app_role);

create function public.invite_staff(
  p_clinic_id     uuid,
  p_email         text,
  p_role          public.app_role,
  p_branch_locked boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id   uuid;
  v_current_role public.app_role;
  v_locked       boolean := p_role = 'admin' and coalesce(p_branch_locked, false);
begin
  if not private.is_clinic_admin(p_clinic_id) then
    raise exception 'only an admin of this clinic can add staff';
  end if;

  if p_role not in ('doctor', 'assistant', 'admin') then
    raise exception 'staff role must be doctor, assistant or admin';
  end if;

  select pr.id into v_profile_id
    from public.profiles pr
   where lower(pr.email) = lower(trim(p_email));

  if v_profile_id is null then
    raise exception 'no account uses that email yet; ask them to sign up first';
  end if;

  select m.role into v_current_role
    from public.clinic_memberships m
   where m.clinic_id = p_clinic_id and m.profile_id = v_profile_id;

  if not private.is_full_admin(p_clinic_id) then
    if p_role = 'admin' then
      raise exception 'only a full admin can make someone an admin';
    end if;
    if v_current_role = 'admin' then
      raise exception 'only a full admin can change an admin''s role';
    end if;
  end if;

  if (p_role <> 'admin' or v_locked)
     and private.is_last_admin(p_clinic_id, v_profile_id) then
    raise exception 'a clinic must keep at least one full admin';
  end if;

  insert into public.clinic_memberships (profile_id, clinic_id, role, branch_locked)
  values (v_profile_id, p_clinic_id, p_role, v_locked)
  on conflict (profile_id, clinic_id) do update
    set role = excluded.role, branch_locked = excluded.branch_locked;

  return v_profile_id;
end;
$$;

create or replace function public.remove_staff(
  p_clinic_id  uuid,
  p_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_clinic_admin(p_clinic_id) then
    raise exception 'only an admin of this clinic can remove staff';
  end if;

  if not private.is_full_admin(p_clinic_id) and exists (
    select 1 from public.clinic_memberships m
    where m.clinic_id = p_clinic_id and m.profile_id = p_profile_id
      and m.role = 'admin'
  ) then
    raise exception 'only a full admin can remove an admin';
  end if;

  if private.is_last_admin(p_clinic_id, p_profile_id) then
    raise exception 'a clinic must keep at least one full admin';
  end if;

  delete from public.clinic_memberships
   where clinic_id = p_clinic_id and profile_id = p_profile_id;

  update public.doctors
     set profile_id = null
   where clinic_id = p_clinic_id and profile_id = p_profile_id;
end;
$$;

-- ── 3. Staff invites ────────────────────────────────────────────────────────
-- One row is one code's whole life:
--
--   open ──redeem──▶ pending ──approve──▶ approved
--     │                 │  └───reject───▶ rejected
--     └────revoke───────┴──────────────▶ revoked
--
-- The applicant's name and email are copied in at redemption. Admins cannot
-- read the profile of someone who is not yet staff (profiles_select_colleagues
-- needs a membership), and loosening that for a waiting list would expose every
-- account that ever typed a code.

create table public.staff_invites (
  id             uuid primary key default gen_random_uuid(),
  clinic_id      uuid not null references public.clinics (id) on delete cascade,
  role           public.app_role not null
                 constraint staff_invites_staff_role check (role in ('doctor', 'assistant')),
  code           text not null default private.new_join_code()
                 constraint staff_invites_code_key unique
                 constraint staff_invites_code_format check (code ~ '^[A-Z0-9]{6,16}$'),
  -- Who the admin issued it for ("Dr Reyes"), so an open code is recognisable.
  label          text,
  status         text not null default 'open'
                 constraint staff_invites_status
                 check (status in ('open', 'pending', 'approved', 'rejected', 'revoked')),
  expires_at     timestamptz not null default now() + interval '7 days',
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  redeemed_by    uuid references public.profiles (id) on delete set null,
  redeemer_name  text,
  redeemer_email text,
  redeemed_at    timestamptz,
  decided_by     uuid references public.profiles (id) on delete set null,
  decided_at     timestamptz,
  -- The roster row an approved doctor was linked to.
  doctor_id      uuid references public.doctors (id) on delete set null,
  constraint staff_invites_decided_after_redeemed
    check (status in ('open', 'revoked') or redeemed_at is not null)
);

create index staff_invites_clinic_status on public.staff_invites (clinic_id, status);

-- One waiting request per person per clinic; a second code would only be noise
-- in the admin's queue.
create unique index staff_invites_one_pending_per_applicant
  on public.staff_invites (clinic_id, redeemed_by)
  where status = 'pending';

-- Readable by the clinic's admins, branch admins included. There is no write
-- policy: every state change goes through the functions below.
alter table public.staff_invites enable row level security;

create policy staff_invites_select_admin on public.staff_invites
  for select to authenticated using (private.is_clinic_admin(clinic_id));

-- ── create_staff_invite ─────────────────────────────────────────────────────

create or replace function public.create_staff_invite(
  p_clinic_id  uuid,
  p_role       public.app_role,
  p_label      text default null,
  p_valid_days int  default 7
)
returns public.staff_invites
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.staff_invites;
begin
  if not private.is_clinic_admin(p_clinic_id) then
    raise exception 'only an admin of this clinic can issue staff codes';
  end if;

  if p_role not in ('doctor', 'assistant') then
    raise exception 'staff codes are for doctors and assistants; add admins by email';
  end if;

  if p_valid_days is null or p_valid_days not between 1 and 30 then
    raise exception 'a staff code can be valid for 1 to 30 days';
  end if;

  -- Same retry as rotate_join_code: a collision is not realistic, but it
  -- should never surface as a unique-constraint error.
  for attempt in 1..5 loop
    begin
      insert into public.staff_invites (clinic_id, role, label, expires_at, created_by)
      values (p_clinic_id, p_role, nullif(trim(p_label), ''),
              now() + make_interval(days => p_valid_days), auth.uid())
      returning * into v_invite;
      return v_invite;
    exception when unique_violation then
      null;
    end;
  end loop;

  raise exception 'could not generate a unique staff code; try again';
end;
$$;

-- ── redeem_staff_invite ─────────────────────────────────────────────────────
-- p_app_role is the app the code was typed into. A doctor code entered in the
-- assistant app would otherwise be approved into an app the person never
-- opens. It does confirm that the code exists — acceptable, since a caller who
-- has a valid single-use code was meant to have it.
--
-- FOR UPDATE re-checks `status = 'open'` after waiting on a concurrent
-- redeemer, so two people racing one code cannot both get it.

create or replace function public.redeem_staff_invite(
  p_code     text,
  p_app_role public.app_role
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_invite public.staff_invites;
begin
  if v_uid is null then
    raise exception 'sign in before entering a staff code';
  end if;

  select i.* into v_invite
    from public.staff_invites i
    join public.clinics c on c.id = i.clinic_id
   where i.code = upper(trim(p_code))
     and i.status = 'open'
     and i.expires_at > now()
     and c.is_active
     for update of i;

  if not found then
    raise exception 'that staff code is not valid, has expired, or was already used';
  end if;

  if v_invite.role <> p_app_role then
    raise exception 'this code is for the % app', initcap(v_invite.role::text);
  end if;

  if exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = v_uid and m.clinic_id = v_invite.clinic_id
  ) then
    raise exception 'you are already on staff at this clinic';
  end if;

  if exists (
    select 1 from public.staff_invites i
    where i.clinic_id = v_invite.clinic_id and i.redeemed_by = v_uid
      and i.status = 'pending'
  ) then
    raise exception 'you already have a request waiting at this clinic';
  end if;

  update public.staff_invites i
     set status         = 'pending',
         redeemed_by    = v_uid,
         redeemed_at    = now(),
         redeemer_name  = pr.full_name,
         redeemer_email = pr.email
    from public.profiles pr
   where i.id = v_invite.id
     and pr.id = v_uid;

  return v_invite.id;
end;
$$;

-- ── decide_staff_request ────────────────────────────────────────────────────
-- Approving a doctor also puts them on the roster, because the doctor app is
-- built around the signed-in doctor's roster row. Either link a row the clinic
-- already has (the seed's doctors have no accounts yet) or create one, which
-- needs a specialty.
--
-- "Does not exist" covers another clinic's request too, so an admin cannot
-- probe for requests they may not see.

create or replace function public.decide_staff_request(
  p_invite_id uuid,
  p_approve   boolean,
  p_doctor_id uuid default null,
  p_specialty text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_invite    public.staff_invites;
  v_doctor_id uuid;
  v_name      text;
begin
  select * into v_invite
    from public.staff_invites
   where id = p_invite_id
     for update;

  if not found or not private.is_clinic_admin(v_invite.clinic_id) then
    raise exception 'that request does not exist';
  end if;

  if v_invite.status <> 'pending' then
    raise exception 'this request has already been decided';
  end if;

  if not coalesce(p_approve, false) then
    update public.staff_invites
       set status = 'rejected', decided_by = v_uid, decided_at = now()
     where id = p_invite_id;
    return;
  end if;

  if v_invite.redeemed_by is null then
    raise exception 'the account behind this request no longer exists';
  end if;

  if exists (
    select 1 from public.clinic_memberships m
    where m.profile_id = v_invite.redeemed_by and m.clinic_id = v_invite.clinic_id
  ) then
    raise exception 'they are already on staff here; reject this request instead';
  end if;

  if v_invite.role = 'doctor' then
    if p_doctor_id is not null then
      update public.doctors
         set profile_id = v_invite.redeemed_by
       where id = p_doctor_id
         and clinic_id = v_invite.clinic_id
         and profile_id is null
      returning id into v_doctor_id;

      if v_doctor_id is null then
        raise exception 'pick a roster entry at this clinic that is not linked to anyone yet';
      end if;
    else
      if nullif(trim(p_specialty), '') is null then
        raise exception 'enter the doctor''s specialty, or link them to an existing roster entry';
      end if;

      select coalesce(pr.full_name, v_invite.redeemer_name) into v_name
        from public.profiles pr
       where pr.id = v_invite.redeemed_by;

      insert into public.doctors (clinic_id, profile_id, full_name, specialty)
      values (v_invite.clinic_id, v_invite.redeemed_by,
              coalesce(v_name, v_invite.redeemer_name, 'Doctor'), trim(p_specialty))
      returning id into v_doctor_id;
    end if;
  end if;

  insert into public.clinic_memberships (profile_id, clinic_id, role)
  values (v_invite.redeemed_by, v_invite.clinic_id, v_invite.role);

  update public.staff_invites
     set status = 'approved', decided_by = v_uid, decided_at = now(),
         doctor_id = v_doctor_id
   where id = p_invite_id;
end;
$$;

-- ── revoke_staff_invite ─────────────────────────────────────────────────────

create or replace function public.revoke_staff_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.staff_invites;
begin
  select * into v_invite
    from public.staff_invites
   where id = p_invite_id
     for update;

  if not found or not private.is_clinic_admin(v_invite.clinic_id) then
    raise exception 'that staff code does not exist';
  end if;

  if v_invite.status not in ('open', 'pending') then
    raise exception 'this code has already been decided';
  end if;

  update public.staff_invites
     set status = 'revoked', decided_by = auth.uid(), decided_at = now()
   where id = p_invite_id;
end;
$$;

-- ── my_staff_requests ───────────────────────────────────────────────────────
-- An applicant is not a member yet, so RLS hides the clinic from them. This
-- returns the one thing they need to see — the name of the clinic they applied
-- to — and nothing else about it.

create or replace function public.my_staff_requests()
returns table (
  id          uuid,
  clinic_name text,
  role        public.app_role,
  status      text,
  redeemed_at timestamptz,
  decided_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select i.id, c.name, i.role, i.status, i.redeemed_at, i.decided_at
    from public.staff_invites i
    join public.clinics c on c.id = i.clinic_id
   where i.redeemed_by = auth.uid()
   order by i.redeemed_at desc;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────

revoke all on function public.invite_staff(uuid, text, public.app_role, boolean)            from public, anon;
revoke all on function public.create_staff_invite(uuid, public.app_role, text, int)         from public, anon;
revoke all on function public.redeem_staff_invite(text, public.app_role)                    from public, anon;
revoke all on function public.decide_staff_request(uuid, boolean, uuid, text)               from public, anon;
revoke all on function public.revoke_staff_invite(uuid)                                     from public, anon;
revoke all on function public.my_staff_requests()                                           from public, anon;

grant execute on function public.invite_staff(uuid, text, public.app_role, boolean)         to authenticated;
grant execute on function public.create_staff_invite(uuid, public.app_role, text, int)      to authenticated;
grant execute on function public.redeem_staff_invite(text, public.app_role)                 to authenticated;
grant execute on function public.decide_staff_request(uuid, boolean, uuid, text)            to authenticated;
grant execute on function public.revoke_staff_invite(uuid)                                  to authenticated;
grant execute on function public.my_staff_requests()                                        to authenticated;
