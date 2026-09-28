-- Payments and the ledger.
--
--   1. How a patient paid: BPI, BDO and QRPH join cash, GCash and the rest.
--   2. Anyone on staff marks a visit done. The front desk may now complete a
--      visit that has arrived or is with the doctor; starting a consultation
--      is still a clinician's.
--   3. complete_visit: marks the visit done with the services performed, and
--      puts them on the visit's draft bill at the catalogue price, so the
--      total adds itself up. A doctor may do this without billing rights: the
--      prices come from the catalogue, never from the caller.
--   4. set_service_price: the front desk keeps the price list. Everything
--      else about a service stays an admin's.
--   5. expenses: money out. Added by the front desk and admins, never edited,
--      voided by an admin with a reason — like a payment.
--   6. ledger_summary / ledger_entries: gross, paid, pending, expenses and
--      net over some days, and the money in and out behind them.

-- ── 1. Payment methods ─────────────────────────────────────────────────────
-- Not used below, so adding them inside this migration's transaction is fine.

alter type public.payment_method add value if not exists 'bpi' after 'maya';
alter type public.payment_method add value if not exists 'bdo' after 'bpi';
alter type public.payment_method add value if not exists 'qrph' after 'bdo';

-- ── 2. Who marks a visit done ──────────────────────────────────────────────
-- Same as 20260923120100 but for the completed step:
--
--   any staff    arrived / in_consultation → completed
--   doctor/admin confirmed / arrived → in_consultation (unchanged)
--
-- confirmed → completed stays refused: the patient is checked in first
-- (complete_visit does both in one go).

create or replace function private.guard_appointment_status()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_from text := case when tg_op = 'INSERT' then null else old.status::text end;
  v_to   text := new.status::text;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and v_to not in ('pending', 'confirmed', 'arrived') then
      raise exception 'a new visit starts as pending, confirmed or arrived, not %', v_to;
    end if;
    if v_to = 'arrived' then new.arrived_at := coalesce(new.arrived_at, now()); end if;
    return new;
  end if;

  if v_from = v_to then
    return new;
  end if;

  if auth.uid() is not null and not private.is_clinic_admin(new.clinic_id) then
    if not private.is_clinic_staff(new.clinic_id) then
      -- A patient: the RLS policy has already pinned this to cancelling.
      if v_from not in ('pending', 'confirmed') then
        raise exception 'This visit can no longer be cancelled here. Please call the clinic.';
      end if;
    elsif not (
         (v_from = 'pending'   and v_to in ('confirmed', 'cancelled'))
      or (v_from = 'confirmed' and v_to in ('arrived', 'in_consultation', 'no_show', 'cancelled'))
      or (v_from = 'arrived'   and v_to in ('in_consultation', 'completed', 'cancelled'))
      or (v_from = 'in_consultation' and v_to = 'completed')
    ) then
      raise exception 'A % visit cannot become %.', replace(v_from, '_', ' '), replace(v_to, '_', ' ');
    elsif v_to = 'in_consultation' and not private.is_clinician(new.clinic_id) then
      raise exception 'Only a doctor or admin can start a consultation.';
    end if;
  end if;

  if v_to = 'no_show' and new.scheduled_at > now() then
    raise exception 'A visit can be marked as a no-show only once its time has come.';
  end if;

  case v_to
    when 'arrived' then
      new.arrived_at := now();
    when 'in_consultation' then
      new.arrived_at := coalesce(new.arrived_at, now());
      new.started_at := now();
    when 'completed' then
      new.arrived_at := coalesce(new.arrived_at, now());
      new.completed_at := now();
    else null;
  end case;
  return new;
end;
$$;

-- ── 3. Marking a visit done ────────────────────────────────────────────────
-- p_services: [{"service_id": "…", "quantity": 1}, …] — what was done.
--
-- The visit moves to completed (through arrived if it was only confirmed),
-- held to the status guard above as the caller. Then its bill:
--   no bill yet      a draft is started with those services (none: no bill)
--   a draft          its service lines are replaced; lines typed in by hand
--                    (no service) stay
--   issued / paid    left alone — it is the front desk's now
-- Called on a visit already completed, it only does the bill part: that is
-- how the services are corrected afterwards.
--
-- Returns the visit's live bill, or null if it has none.
--
-- Security definer, because a doctor writes the lines without billing
-- rights. It checks the caller is staff at the visit's clinic, takes only
-- that clinic's services, and prices them from the catalogue.

create or replace function public.complete_visit(
  p_appointment_id uuid,
  p_services       jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt    public.appointments;
  v_invoice public.invoices;
  v_items   jsonb;
begin
  select * into v_appt from public.appointments where id = p_appointment_id for update;
  if not found or not private.is_clinic_staff(v_appt.clinic_id) then
    raise exception 'Appointment not found.' using errcode = 'P0002';
  end if;

  if jsonb_typeof(coalesce(p_services, '[]'::jsonb)) <> 'array' then
    raise exception 'The services must be a list.';
  end if;

  -- One entry per service, quantities added up.
  select coalesce(jsonb_agg(jsonb_build_object('service_id', service_id, 'quantity', quantity)), '[]'::jsonb)
    into v_items
    from (select (e->>'service_id')::uuid as service_id,
                 sum(coalesce((e->>'quantity')::int, 1))::int as quantity
            from jsonb_array_elements(coalesce(p_services, '[]'::jsonb)) e
           group by 1) g;

  if exists (select 1 from jsonb_to_recordset(v_items) x(service_id uuid, quantity int)
              where x.quantity not between 1 and 999) then
    raise exception 'Each service is done between 1 and 999 times.';
  end if;
  if exists (select 1 from jsonb_to_recordset(v_items) x(service_id uuid, quantity int)
              where not exists (select 1 from public.services s
                                 where s.id = x.service_id
                                   and s.clinic_id = v_appt.clinic_id)) then
    raise exception 'That service is not offered here.';
  end if;

  -- The visit.
  case v_appt.status
    when 'completed' then
      null;
    when 'confirmed' then
      update public.appointments set status = 'arrived'   where id = v_appt.id;
      update public.appointments set status = 'completed' where id = v_appt.id;
    when 'arrived', 'in_consultation' then
      update public.appointments set status = 'completed' where id = v_appt.id;
    else
      raise exception 'A % visit cannot be marked as done.', replace(v_appt.status::text, '_', ' ');
  end case;

  -- Its bill.
  select * into v_invoice from public.invoices
   where appointment_id = v_appt.id and status <> 'void'
   for update;

  if found and v_invoice.status <> 'draft' then
    return v_invoice.id;
  end if;

  if v_invoice.id is null then
    if jsonb_array_length(v_items) = 0 then
      return null;
    end if;
    insert into public.invoices (clinic_id, patient_id, appointment_id)
    values (v_appt.clinic_id, v_appt.patient_id, v_appt.id)
    returning * into v_invoice;
  end if;

  delete from public.invoice_items
   where invoice_id = v_invoice.id and service_id is not null;

  insert into public.invoice_items (invoice_id, clinic_id, service_id, description, quantity, unit_price)
  select v_invoice.id, v_appt.clinic_id, s.id, s.name, vs.quantity, coalesce(s.price, 0)
    from jsonb_to_recordset(v_items) vs(service_id uuid, quantity int)
    join public.services s on s.id = vs.service_id
   order by s.name;

  return v_invoice.id;
end;
$$;

revoke all on function public.complete_visit(uuid, jsonb) from public, anon;
grant execute on function public.complete_visit(uuid, jsonb) to authenticated;

-- ── 4. The price list ──────────────────────────────────────────────────────
-- The front desk quotes and bills the prices, so it keeps them. Null clears
-- a price. A new price applies to bills drafted from now on; lines already
-- on a bill keep theirs.

create or replace function public.set_service_price(p_service_id uuid, p_price numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_clinic uuid;
begin
  select s.clinic_id into v_clinic from public.services s where s.id = p_service_id;
  if not found or not private.can_bill(v_clinic) then
    raise exception 'Service not found.' using errcode = 'P0002';
  end if;
  if p_price is not null and (p_price < 0 or p_price > 9999999) then
    raise exception 'Enter a price from 0 up.';
  end if;
  update public.services set price = round(p_price, 2) where id = p_service_id;
end;
$$;

revoke all on function public.set_service_price(uuid, numeric) from public, anon;
grant execute on function public.set_service_price(uuid, numeric) to authenticated;

-- ── 5. Expenses ────────────────────────────────────────────────────────────

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  clinic_id   uuid not null references public.clinics (id) on delete cascade,
  -- The clinic's calendar day it was spent. Receipts come in late, so this
  -- may be in the past — never in the future.
  spent_on    date not null default current_date,
  -- "Supplies", "Rent", "Salaries" — the apps suggest a few; free text.
  category    text not null
    constraint expenses_category_valid check (length(trim(category)) between 1 and 40),
  description text
    constraint expenses_description_valid check (length(description) <= 500),
  amount      numeric(12, 2) not null
    constraint expenses_amount_positive check (amount > 0),
  method      public.payment_method not null default 'cash',
  reference   text,
  created_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  voided_at   timestamptz,
  voided_by   uuid references public.profiles (id) on delete set null,
  void_reason text
);

create index expenses_clinic_day_idx on public.expenses (clinic_id, spent_on desc);

create or replace function private.guard_expense()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_today date;
begin
  if tg_op = 'UPDATE' then
    if current_user = 'authenticated' then
      raise exception 'An expense cannot be edited. An admin can void it.';
    end if;
    return new;
  end if;

  select (now() at time zone c.timezone)::date into v_today
    from public.clinics c where c.id = new.clinic_id;
  if new.spent_on > v_today then
    raise exception 'An expense cannot be dated in the future.';
  end if;

  new.category := trim(new.category);
  new.description := nullif(trim(new.description), '');
  new.reference := nullif(trim(new.reference), '');
  if current_user = 'authenticated' then
    new.created_by := auth.uid();
    new.created_at := now();
    new.voided_at := null;  new.voided_by := null;  new.void_reason := null;
  end if;
  return new;
end;
$$;

revoke all on function private.guard_expense() from public, anon, authenticated;

create trigger expenses_guard
  before insert or update on public.expenses
  for each row execute function private.guard_expense();

alter table public.expenses enable row level security;

-- The front desk and admins. Doctors do not see the clinic's spending.
create policy expenses_select_billing on public.expenses
  for select to authenticated using (private.can_bill(clinic_id));
create policy expenses_insert_billing on public.expenses
  for insert to authenticated with check (private.can_bill(clinic_id));
-- No UPDATE or DELETE policy: void_expense is the only way to take one back.

create or replace function public.void_expense(p_expense_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exp public.expenses;
begin
  select * into v_exp from public.expenses where id = p_expense_id for update;
  if not found or not private.can_bill(v_exp.clinic_id) then
    raise exception 'Expense not found.' using errcode = 'P0002';
  end if;
  if not private.is_clinic_admin(v_exp.clinic_id) then
    raise exception 'Only an admin can void an expense.' using errcode = '42501';
  end if;
  if v_exp.voided_at is not null then
    raise exception 'This expense is already void.';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Say why the expense is being voided.';
  end if;

  update public.expenses
     set voided_at   = now(),
         voided_by   = auth.uid(),
         void_reason = trim(p_reason)
   where id = p_expense_id;
end;
$$;

revoke all on function public.void_expense(uuid, text) from public, anon;
grant execute on function public.void_expense(uuid, text) to authenticated;

-- ── 6. The ledger ──────────────────────────────────────────────────────────
-- Over the clinic's calendar days [p_from, p_to]:
--
--   gross     what the bills issued in those days came to (after discounts)
--   discounts what was taken off them
--   paid      money received in those days, whichever bill it was for
--   pending   what the bills issued in those days still owe
--   expenses  money out, by the day it was spent
--   net       paid − expenses: cash in hand, not accrual
--
-- plus, as of now whatever the days: outstanding (everything still owed)
-- and drafts (visits done but not yet billed out).
--
-- The front desk and admins only.

create or replace function public.ledger_summary(p_clinic_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tz     text;
  v_result jsonb;
begin
  if not private.can_bill(p_clinic_id) then
    raise exception 'Only the front desk and admins can see the ledger.' using errcode = '42501';
  end if;
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  with billed as (
    select v.total, v.discount_amount, v.balance
      from public.invoices v
     where v.clinic_id = p_clinic_id
       and v.status in ('issued', 'paid')
       and (v.issued_at at time zone v_tz)::date between p_from and p_to
  ),
  paid as (
    select p.method, p.amount
      from public.payments p
     where p.clinic_id = p_clinic_id
       and p.voided_at is null
       and (p.received_at at time zone v_tz)::date between p_from and p_to
  ),
  spent as (
    select e.category, e.amount
      from public.expenses e
     where e.clinic_id = p_clinic_id
       and e.voided_at is null
       and e.spent_on between p_from and p_to
  )
  select jsonb_build_object(
    'gross',        (select coalesce(sum(total), 0) from billed),
    'discounts',    (select coalesce(sum(discount_amount), 0) from billed),
    'bill_count',   (select count(*) from billed),
    'paid',         (select coalesce(sum(amount), 0) from paid),
    'payment_count', (select count(*) from paid),
    'by_method',    coalesce((select jsonb_object_agg(method::text, total)
                                from (select method, sum(amount) as total
                                        from paid group by method) m), '{}'::jsonb),
    'pending',      (select coalesce(sum(balance), 0) from billed),
    'expenses',     (select coalesce(sum(amount), 0) from spent),
    'by_category',  coalesce((select jsonb_object_agg(category, total)
                                from (select category, sum(amount) as total
                                        from spent group by category) c), '{}'::jsonb),
    'net',          (select coalesce(sum(amount), 0) from paid)
                    - (select coalesce(sum(amount), 0) from spent),
    'outstanding',  (select coalesce(sum(v.balance), 0) from public.invoices v
                      where v.clinic_id = p_clinic_id and v.status = 'issued'),
    'unpaid_count', (select count(*) from public.invoices v
                      where v.clinic_id = p_clinic_id and v.status = 'issued'),
    'draft_total',  (select coalesce(sum(v.total), 0) from public.invoices v
                      where v.clinic_id = p_clinic_id and v.status = 'draft'),
    'draft_count',  (select count(*) from public.invoices v
                      where v.clinic_id = p_clinic_id and v.status = 'draft')
  ) into v_result;
  return v_result;
end;
$$;

-- Every payment and expense in those days, newest first, voided ones
-- included (marked) so the ledger shows what was taken back.
create or replace function public.ledger_entries(p_clinic_id uuid, p_from date, p_to date)
returns table (
  kind        text,         -- 'payment' | 'expense'
  id          uuid,
  happened_at timestamptz,
  amount      numeric,
  method      public.payment_method,
  reference   text,
  title       text,         -- the patient, or the expense's category
  detail      text,         -- the bill number, or the expense's description
  invoice_id  uuid,
  voided      boolean,
  void_reason text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tz text;
begin
  if not private.can_bill(p_clinic_id) then
    raise exception 'Only the front desk and admins can see the ledger.' using errcode = '42501';
  end if;
  select c.timezone into v_tz from public.clinics c where c.id = p_clinic_id;

  return query
  select 'payment'::text, p.id, p.received_at, p.amount, p.method, p.reference,
         coalesce(pe.full_name, 'Patient'), v.number, v.id,
         p.voided_at is not null, p.void_reason
    from public.payments p
    join public.invoices v on v.id = p.invoice_id
    left join public.patients pt on pt.id = v.patient_id
    left join public.persons pe on pe.id = pt.person_id
   where p.clinic_id = p_clinic_id
     and (p.received_at at time zone v_tz)::date between p_from and p_to
  union all
  select 'expense'::text, e.id,
         -- The day it was spent, at noon there, so it sorts into its day.
         ((e.spent_on + time '12:00') at time zone v_tz), e.amount, e.method, e.reference,
         e.category, e.description, null::uuid,
         e.voided_at is not null, e.void_reason
    from public.expenses e
   where e.clinic_id = p_clinic_id
     and e.spent_on between p_from and p_to
   order by 3 desc
   limit 1000;
end;
$$;

revoke all on function public.ledger_summary(uuid, date, date) from public, anon;
revoke all on function public.ledger_entries(uuid, date, date) from public, anon;
grant execute on function public.ledger_summary(uuid, date, date) to authenticated;
grant execute on function public.ledger_entries(uuid, date, date) to authenticated;
