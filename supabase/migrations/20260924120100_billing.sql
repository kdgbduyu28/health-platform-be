-- Billing: what a patient owes a clinic, and what they have paid.
--
--   invoices       one bill, usually for one visit. Drafted, then issued
--                  (numbered, locked), then paid by its payments — or voided.
--   invoice_items  its lines. Editable only while the bill is a draft.
--   payments       money received against an issued bill. Never edited or
--                  deleted; a mistake is voided, by an admin, with a reason.
--
--   draft ──issue──→ issued ⇄ paid        (paid when the payments cover it)
--     │                 └──void──→ void   (only with no payments standing)
--     └─ deleted
--
-- Totals are the database's to compute: subtotal from the lines, amount paid
-- from the payments, the status from both. A client writes lines, a discount
-- and payments, and reads the rest.
--
-- Who: the front desk and admins bill (private.can_bill). Doctors and other
-- staff read. A patient reads their own bills once issued — never drafts.
--
-- These are statements, not BIR official receipts: nothing here is an
-- accredited receipting system, and the apps must not call them one.

-- ── 1. Who may bill ────────────────────────────────────────────────────────

create or replace function private.can_bill(p_clinic uuid)
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
      and m.role in ('assistant', 'admin')
  );
$$;

grant execute on function private.can_bill(uuid) to authenticated;

-- ── 2. Tables ──────────────────────────────────────────────────────────────

create type public.invoice_status as enum ('draft', 'issued', 'paid', 'void');

create type public.payment_method as enum
  ('cash', 'gcash', 'maya', 'card', 'bank_transfer', 'hmo', 'other');

-- The last number issued at each clinic. Touched only by issue_invoice.
create table public.invoice_counters (
  clinic_id   uuid primary key references public.clinics (id) on delete cascade,
  last_number int not null default 0
);

alter table public.invoice_counters enable row level security;

create table public.invoices (
  id              uuid primary key default gen_random_uuid(),
  clinic_id       uuid not null references public.clinics (id) on delete cascade,
  patient_id      uuid not null,
  appointment_id  uuid,
  -- INV-000042, unique per clinic; set when issued, never before.
  number          text,
  status          public.invoice_status not null default 'draft',
  subtotal        numeric(12, 2) not null default 0,
  discount_amount numeric(12, 2) not null default 0
    constraint invoices_discount_valid check (discount_amount >= 0),
  -- "Senior citizen", "PWD", "Promo" — shown on the bill.
  discount_reason text,
  total           numeric(12, 2) not null default 0
    constraint invoices_discount_within_total check (total >= 0),
  amount_paid     numeric(12, 2) not null default 0,
  balance         numeric(12, 2) generated always as (total - amount_paid) stored,
  notes           text,
  issued_at       timestamptz,
  issued_by       uuid references public.profiles (id) on delete set null,
  voided_at       timestamptz,
  voided_by       uuid references public.profiles (id) on delete set null,
  void_reason     text,
  created_by      uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint invoices_id_clinic_key unique (id, clinic_id),
  constraint invoices_number_key unique (clinic_id, number),
  -- The chart and the visit belong to the bill's clinic. MATCH SIMPLE: a bill
  -- with no visit (a retainer, a product) skips the second.
  constraint invoices_patient_in_clinic
    foreign key (patient_id, clinic_id) references public.patients (id, clinic_id),
  constraint invoices_appointment_in_clinic
    foreign key (appointment_id, clinic_id) references public.appointments (id, clinic_id)
);

-- One live bill per visit. A voided one can be replaced.
create unique index invoices_one_per_visit
  on public.invoices (appointment_id)
  where appointment_id is not null and status <> 'void';

create index invoices_clinic_idx  on public.invoices (clinic_id, created_at desc);
create index invoices_patient_idx on public.invoices (patient_id, created_at desc);

create trigger invoices_set_updated_at
  before update on public.invoices
  for each row execute function public.set_updated_at();

create table public.invoice_items (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null,
  clinic_id   uuid not null,
  service_id  uuid,
  description text not null
    constraint invoice_items_description_present check (length(trim(description)) > 0),
  quantity    int not null default 1
    constraint invoice_items_quantity_valid check (quantity between 1 and 999),
  unit_price  numeric(12, 2) not null
    constraint invoice_items_price_valid check (unit_price >= 0),
  amount      numeric(12, 2) generated always as (quantity * unit_price) stored,
  created_at  timestamptz not null default now(),
  constraint invoice_items_invoice_in_clinic
    foreign key (invoice_id, clinic_id) references public.invoices (id, clinic_id)
    on delete cascade,
  constraint invoice_items_service_in_clinic
    foreign key (service_id, clinic_id) references public.services (id, clinic_id)
);

create index invoice_items_invoice_idx on public.invoice_items (invoice_id);

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null,
  clinic_id   uuid not null,
  amount      numeric(12, 2) not null
    constraint payments_amount_positive check (amount > 0),
  method      public.payment_method not null default 'cash',
  -- GCash/Maya reference, card slip, HMO approval code.
  reference   text,
  received_at timestamptz not null default now(),
  received_by uuid default auth.uid() references public.profiles (id) on delete set null,
  voided_at   timestamptz,
  voided_by   uuid references public.profiles (id) on delete set null,
  void_reason text,
  constraint payments_invoice_in_clinic
    foreign key (invoice_id, clinic_id) references public.invoices (id, clinic_id)
);

create index payments_invoice_idx on public.payments (invoice_id);
create index payments_clinic_day_idx on public.payments (clinic_id, received_at desc);

-- ── 3. Totals ──────────────────────────────────────────────────────────────
-- Security definer: they write the computed columns, which the guard below
-- keeps away from signed-in clients (it checks current_user, and these run as
-- their owner).

create or replace function private.refresh_invoice(p_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subtotal numeric(12, 2);
  v_paid     numeric(12, 2);
begin
  select coalesce(sum(i.amount), 0) into v_subtotal
    from public.invoice_items i where i.invoice_id = p_invoice_id;
  select coalesce(sum(p.amount), 0) into v_paid
    from public.payments p where p.invoice_id = p_invoice_id and p.voided_at is null;

  update public.invoices v
     set subtotal    = v_subtotal,
         amount_paid = v_paid,
         status = case
                    when v.status in ('issued', 'paid') then
                      case when v_paid >= v_subtotal - v.discount_amount
                           then 'paid' else 'issued' end::public.invoice_status
                    else v.status
                  end
   where v.id = p_invoice_id
     and (v.subtotal, v.amount_paid) is distinct from (v_subtotal, v_paid);
end;
$$;

revoke all on function private.refresh_invoice(uuid) from public, anon, authenticated;

create or replace function private.invoice_children_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.refresh_invoice(old.invoice_id);
  else
    perform private.refresh_invoice(new.invoice_id);
  end if;
  return null;
end;
$$;

revoke all on function private.invoice_children_changed() from public, anon, authenticated;

create trigger invoice_items_refresh_invoice
  after insert or update or delete on public.invoice_items
  for each row execute function private.invoice_children_changed();

create trigger payments_refresh_invoice
  after insert or update on public.payments
  for each row execute function private.invoice_children_changed();

-- ── 4. Guards ──────────────────────────────────────────────────────────────

-- What a client may write on the bill itself: who it is for (at creation),
-- the discount and notes while it is a draft, notes after. Everything else
-- moves through the functions in 5.
create or replace function private.guard_invoice()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' then
    if tg_op = 'INSERT' then
      new.status      := 'draft';
      new.number      := null;
      new.subtotal    := 0;
      new.amount_paid := 0;
      new.issued_at   := null;  new.issued_by := null;
      new.voided_at   := null;  new.voided_by := null;  new.void_reason := null;
      new.created_by  := auth.uid();
      new.created_at  := now();
    else
      if (new.clinic_id, new.patient_id, new.appointment_id, new.number, new.status,
          new.subtotal, new.amount_paid, new.issued_at, new.issued_by,
          new.voided_at, new.voided_by, new.void_reason, new.created_by, new.created_at)
         is distinct from
         (old.clinic_id, old.patient_id, old.appointment_id, old.number, old.status,
          old.subtotal, old.amount_paid, old.issued_at, old.issued_by,
          old.voided_at, old.voided_by, old.void_reason, old.created_by, old.created_at)
      then
        raise exception 'Issue, pay or void a bill with its buttons; its totals are worked out for you.';
      end if;
      if old.status <> 'draft'
         and (new.discount_amount, new.discount_reason)
             is distinct from (old.discount_amount, old.discount_reason) then
        raise exception 'This bill has been issued and can no longer be changed. Void it and bill again.';
      end if;
    end if;
  end if;

  new.total := new.subtotal - new.discount_amount;
  if new.total < 0 then
    raise exception 'The discount is more than the bill.' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_invoice() from public, anon, authenticated;

create trigger invoices_guard
  before insert or update on public.invoices
  for each row execute function private.guard_invoice();

-- Lines change only on a draft.
create or replace function private.guard_invoice_item()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.invoice_status;
begin
  select v.status into v_status from public.invoices v
   where v.id = case when tg_op = 'DELETE' then old.invoice_id else new.invoice_id end;
  -- Null: the bill itself is being deleted, and its lines with it.
  if v_status is not null and v_status <> 'draft' then
    raise exception 'This bill has been issued and can no longer be changed. Void it and bill again.';
  end if;
  if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then
    raise exception 'A line cannot move to another bill.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.guard_invoice_item() from public, anon, authenticated;

create trigger invoice_items_guard
  before insert or update or delete on public.invoice_items
  for each row execute function private.guard_invoice_item();

-- A payment goes on an issued bill, for no more than it still owes, recorded
-- as the person at the desk. After that it is only ever voided (void_payment).
create or replace function private.guard_payment()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  if tg_op = 'UPDATE' then
    if current_user = 'authenticated' then
      raise exception 'A payment cannot be edited. An admin can void it.';
    end if;
    return new;
  end if;

  select * into v_inv from public.invoices v where v.id = new.invoice_id for update;
  if v_inv.status = 'draft' then
    raise exception 'Issue the bill before taking a payment.';
  elsif v_inv.status = 'void' then
    raise exception 'This bill was voided.';
  elsif v_inv.status = 'paid' then
    raise exception 'This bill is already paid in full.';
  elsif new.amount > v_inv.balance then
    raise exception 'That is more than the % still owed.', to_char(v_inv.balance, 'FM999,999,990.00');
  end if;

  if current_user = 'authenticated' then
    new.received_by := auth.uid();
    new.voided_at := null;  new.voided_by := null;  new.void_reason := null;
    -- Backdating is how cash goes missing; a payment is received now.
    new.received_at := now();
  end if;
  return new;
end;
$$;

revoke all on function private.guard_payment() from public, anon, authenticated;

create trigger payments_guard
  before insert or update on public.payments
  for each row execute function private.guard_payment();

-- ── 5. Moving a bill along ─────────────────────────────────────────────────

-- Numbers and locks the bill. A bill that comes to nothing (all discounted)
-- is paid the moment it is issued.
create or replace function public.issue_invoice(p_invoice_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inv    public.invoices;
  v_number int;
begin
  select * into v_inv from public.invoices where id = p_invoice_id for update;
  if not found or not private.can_bill(v_inv.clinic_id) then
    raise exception 'Bill not found.' using errcode = 'P0002';
  end if;
  if v_inv.status <> 'draft' then
    raise exception 'This bill has already been issued.';
  end if;
  if not exists (select 1 from public.invoice_items i where i.invoice_id = p_invoice_id) then
    raise exception 'Add at least one line before issuing the bill.';
  end if;

  insert into public.invoice_counters as c (clinic_id, last_number)
  values (v_inv.clinic_id, 1)
  on conflict (clinic_id) do update set last_number = c.last_number + 1
  returning last_number into v_number;

  update public.invoices
     set status    = case when total <= 0 then 'paid' else 'issued' end::public.invoice_status,
         number    = 'INV-' || lpad(v_number::text, 6, '0'),
         issued_at = now(),
         issued_by = auth.uid()
   where id = p_invoice_id;

  return 'INV-' || lpad(v_number::text, 6, '0');
end;
$$;

-- Takes an issued bill out of the books. Its number stays used: a gap in the
-- sequence with a reason on record, not a missing bill.
create or replace function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  select * into v_inv from public.invoices where id = p_invoice_id for update;
  if not found or not private.can_bill(v_inv.clinic_id) then
    raise exception 'Bill not found.' using errcode = 'P0002';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Say why the bill is being voided.';
  end if;
  if v_inv.status = 'draft' then
    raise exception 'A draft is simply deleted, not voided.';
  elsif v_inv.status = 'void' then
    raise exception 'This bill is already void.';
  end if;
  if exists (select 1 from public.payments p
              where p.invoice_id = p_invoice_id and p.voided_at is null) then
    raise exception 'This bill has payments on it. An admin must void them first.';
  end if;

  update public.invoices
     set status      = 'void',
         voided_at   = now(),
         voided_by   = auth.uid(),
         void_reason = trim(p_reason)
   where id = p_invoice_id;
end;
$$;

-- Admins only: the front desk handles the cash, so it does not also get to
-- make a payment disappear.
create or replace function public.void_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
begin
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found or not private.is_clinic_staff(v_pay.clinic_id) then
    raise exception 'Payment not found.' using errcode = 'P0002';
  end if;
  if not private.is_clinic_admin(v_pay.clinic_id) then
    raise exception 'Only an admin can void a payment.' using errcode = '42501';
  end if;
  if v_pay.voided_at is not null then
    raise exception 'This payment is already void.';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Say why the payment is being voided.';
  end if;
  if exists (select 1 from public.invoices v
              where v.id = v_pay.invoice_id and v.status = 'void') then
    raise exception 'This bill was voided.';
  end if;

  update public.payments
     set voided_at   = now(),
         voided_by   = auth.uid(),
         void_reason = trim(p_reason)
   where id = p_payment_id;
end;
$$;

-- A draft for one visit, with the visit's service as its first line at the
-- catalogue price (zero if the clinic has not set one). Returns the visit's
-- live bill instead if it already has one, so a double tap makes one bill.
-- Security invoker: RLS on invoices decides whether this caller may bill.
create or replace function public.create_invoice_for_appointment(p_appointment_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_appt  public.appointments;
  v_id    uuid;
  v_price numeric(12, 2);
begin
  select * into v_appt from public.appointments where id = p_appointment_id;
  if not found then
    raise exception 'Appointment not found.' using errcode = 'P0002';
  end if;

  select v.id into v_id from public.invoices v
   where v.appointment_id = p_appointment_id and v.status <> 'void';
  if found then
    return v_id;
  end if;

  if v_appt.status in ('pending', 'cancelled', 'no_show') then
    raise exception 'Bill a visit once the patient is here.';
  end if;

  select s.price into v_price from public.services s where s.id = v_appt.service_id;

  insert into public.invoices (clinic_id, patient_id, appointment_id)
  values (v_appt.clinic_id, v_appt.patient_id, v_appt.id)
  returning id into v_id;

  insert into public.invoice_items (invoice_id, clinic_id, service_id, description, unit_price)
  values (v_id, v_appt.clinic_id, v_appt.service_id, v_appt.service_name, coalesce(v_price, 0));

  return v_id;
end;
$$;

-- Money in and money owed at [p_clinic_id] for the clinic's calendar days
-- [p_from, p_to]. Security invoker: a caller who cannot read the clinic's
-- bills gets zeros.
create or replace function public.billing_summary(p_clinic_id uuid, p_from date, p_to date)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with tz as (
    select c.timezone from public.clinics c where c.id = p_clinic_id
  ),
  paid as (
    select p.method, p.amount
      from public.payments p, tz
     where p.clinic_id = p_clinic_id
       and p.voided_at is null
       and (p.received_at at time zone tz.timezone)::date between p_from and p_to
  )
  select jsonb_build_object(
    'collected', (select coalesce(sum(amount), 0) from paid),
    'by_method', coalesce((select jsonb_object_agg(method::text, total)
                             from (select method, sum(amount) as total
                                     from paid group by method) m), '{}'::jsonb),
    'billed', (select coalesce(sum(v.total), 0)
                 from public.invoices v, tz
                where v.clinic_id = p_clinic_id
                  and v.status in ('issued', 'paid')
                  and (v.issued_at at time zone tz.timezone)::date between p_from and p_to),
    -- Outstanding is as of now, whatever the range.
    'outstanding', (select coalesce(sum(v.balance), 0) from public.invoices v
                     where v.clinic_id = p_clinic_id and v.status = 'issued'),
    'unpaid_count', (select count(*) from public.invoices v
                      where v.clinic_id = p_clinic_id and v.status = 'issued'),
    'draft_count', (select count(*) from public.invoices v
                     where v.clinic_id = p_clinic_id and v.status = 'draft')
  );
$$;

revoke all on function public.issue_invoice(uuid)                  from public, anon;
revoke all on function public.void_invoice(uuid, text)             from public, anon;
revoke all on function public.void_payment(uuid, text)             from public, anon;
revoke all on function public.create_invoice_for_appointment(uuid) from public, anon;
revoke all on function public.billing_summary(uuid, date, date)    from public, anon;
grant execute on function public.issue_invoice(uuid)                  to authenticated;
grant execute on function public.void_invoice(uuid, text)             to authenticated;
grant execute on function public.void_payment(uuid, text)             to authenticated;
grant execute on function public.create_invoice_for_appointment(uuid) to authenticated;
grant execute on function public.billing_summary(uuid, date, date)    to authenticated;

-- ── 6. Row Level Security ──────────────────────────────────────────────────

alter table public.invoices      enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments      enable row level security;

-- A patient's view: their own charts' bills, once issued.
create or replace function private.my_invoice_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select v.id from public.invoices v
   where v.patient_id in (select private.my_patient_ids())
     and v.status <> 'draft';
$$;

grant execute on function private.my_invoice_ids() to authenticated;

create policy invoices_select_staff on public.invoices
  for select to authenticated using (private.is_clinic_staff(clinic_id));
create policy invoices_select_own_patient on public.invoices
  for select to authenticated using (id in (select private.my_invoice_ids()));
create policy invoices_insert_billing on public.invoices
  for insert to authenticated with check (private.can_bill(clinic_id));
create policy invoices_update_billing on public.invoices
  for update to authenticated
  using (private.can_bill(clinic_id)) with check (private.can_bill(clinic_id));
create policy invoices_delete_draft on public.invoices
  for delete to authenticated using (private.can_bill(clinic_id) and status = 'draft');

create policy invoice_items_select_staff on public.invoice_items
  for select to authenticated using (private.is_clinic_staff(clinic_id));
create policy invoice_items_select_own_patient on public.invoice_items
  for select to authenticated using (invoice_id in (select private.my_invoice_ids()));
create policy invoice_items_write_billing on public.invoice_items
  for all to authenticated
  using (private.can_bill(clinic_id)) with check (private.can_bill(clinic_id));

create policy payments_select_staff on public.payments
  for select to authenticated using (private.is_clinic_staff(clinic_id));
create policy payments_select_own_patient on public.payments
  for select to authenticated
  using (invoice_id in (select private.my_invoice_ids()) and voided_at is null);
-- No UPDATE or DELETE policy: void_payment is the only way to take one back.
create policy payments_insert_billing on public.payments
  for insert to authenticated with check (private.can_bill(clinic_id));
