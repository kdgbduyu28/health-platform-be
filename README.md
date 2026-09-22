# health-platform-be

Supabase backend for [health-platform-fe](../health-platform-fe) — a Flutter
Melos workspace with four apps (patient, doctor, assistant, admin) serving any
number of clinics.

There is no custom server. This repo is the database: schema migrations, Row
Level Security policies, a handful of database functions, and seed data. The
apps talk to Supabase directly through `supabase_flutter`.

## One project, four apps, many clinics

A Supabase *project* is one Postgres database + one auth instance + one API URL.

- **All four apps** connect to this one project. A build decides only *which
  app* it is; *which clinic* it shows comes from whoever signs in.
- **Every clinic is a tenant row** in `clinics`. D-Touch Dental Clinic is one
  tenant. Isolation between tenants is enforced by RLS, not by separate
  projects, and onboarding another clinic is data, not a release — see
  [docs/onboarding.md](docs/onboarding.md).

So the whole platform is **1 active project**. The free tier allows 2, which
leaves one spare — use it for a staging project.

Free tier limits worth knowing: 500 MB database, 1 GB file storage, 5 GB egress,
50,000 monthly active users, and **projects pause after 1 week of inactivity**
(one click to restore).

> **Not for real patient data.** Supabase does not offer HIPAA on Free or Pro —
> it is a paid add-on from the Team plan up. For Philippine clinics the relevant
> regime is RA 10173 (Data Privacy Act) rather than HIPAA, but either way the
> free tier is for demo and portfolio data only. Revisit before any real clinic
> uses this.

## Layout

```
supabase/
  migrations/
    20260817120000_init_schema.sql            tables, enums, constraints, triggers
    20260817120100_rls_policies.sql           private helpers + the original policies
    20260818090000_harden_trigger_functions.sql
    20260818100000_dedupe_appointment_fks.sql
    20260901120000_book_walk_in_rpc.sql
    20260914120000_clinics_as_tenants.sql     verticals as data, tenant config columns
    20260914120100_person_chart_split.sql     persons + one chart per clinic
    20260914120200_staff_across_clinics.sql   roles move onto memberships
    20260914120300_tenant_scoped_reads.sql    clinics/doctors/services scoped to members
    20260914120400_onboarding_rpcs.sql        join_clinic, invite_staff, admin self-service
    20260915120000_private_clinical_notes.sql chart/visit notes, clinicians only
    20260916120000_staff_approval_and_branch_admins.sql
    20260922120000_public_clinic_pages.sql    clinic_by_slug for the public page
    20260923120000_visit_statuses.sql         arrived, in_consultation, no_show
    20260923120100_visit_flow_and_availability.sql
    20260924120000_rescheduling.sql           reschedule_appointment
    20260924120100_billing.sql                invoices, lines, payments
    20260924120200_notifications.sql          inbox, push subscriptions, reminders
  functions/
    send-push/index.ts                        Web Push delivery (Edge Function)
    .env.example                              the secrets it needs
  seed.sql                                    four demo tenants, re-runnable
  dev/
    create_demo_users.sql                     demo accounts wired to the seed
    provision_clinic.sql                      onboard a real clinic
  tests/
    run.sh                                    throwaway cluster → migrate → seed → test
    rls_test.sh                               395 behavioural checks
    supabase_shim.sql                         test-only stubs for Supabase's auth schema
docs/
  onboarding.md                               runbook for adding a clinic client
```

The first five migrations built a three-clinic demo. The `20260914…` set turns
it into a multi-tenant platform; each file's header explains the problem it
fixes, and each leaves the database in a working state on its own.

## Schema

| Table | Purpose |
|---|---|
| `clinic_types` | The verticals (dental, optometry, pedia, …). A new one is an `INSERT`. |
| `clinics` | The tenants. Name, slug, vertical, brand colour, logo, join code, `is_active`. |
| `profiles` | 1:1 with `auth.users`. An account and nothing more — no role. |
| `clinic_memberships` | Staff: which clinics an account works at, and **its role at each one**. |
| `services` | Per-clinic service catalogue: duration (what a visit blocks) and an optional price. |
| `doctors` | Per-clinic roster. The same account may be on several clinics' rosters. |
| `persons` | Who someone is: name, phone, email, DOB, optional account link. One per human. |
| `patients` | A **chart**: one per (person, clinic). Belongs to that clinic forever. |
| `appointments` | The core table. `service_name` snapshots the service at booking time so renaming a service never rewrites history. `patient_note` is what the doctor wants the patient to read. |
| `chart_notes` | The standing medical note on a chart (allergies, conditions). Clinicians only. |
| `visit_notes` | The consultation note on an appointment. Clinicians only. |
| `doctor_time_off` | Days nobody can book: a doctor's leave, or (no `doctor_id`) the whole clinic closed. |
| `invoices` | A bill, usually for one visit: draft → issued (numbered, locked) → paid, or void. Totals are computed, never written by a client. |
| `invoice_items` | A bill's lines. Editable only while the bill is a draft. |
| `payments` | Money received on an issued bill. Never edited or deleted; an admin voids a mistake, with a reason. |
| `notifications` | Each account's inbox, one row per update, for one app. Written only by triggers. |
| `push_subscriptions` | Browsers that asked for Web Push: one row per browser, owned by whoever signed in last on it. |

Integrity is declarative wherever possible:

- **No overlapping visits** — each appointment ends at `scheduled_at` plus its
  service's duration (`ends_at`, set by trigger), and an exclusion constraint
  refuses two visits of one doctor that overlap. Cancelled visits and no-shows
  free their time.
- **No cross-clinic bookings** — composite foreign keys pin an appointment's
  doctor, service *and chart* to its clinic. No trigger needed.
- **One chart per person per clinic**, and a chart can never move to another
  person or clinic (a trigger, since RLS cannot compare old and new rows).
- `available_weekdays` is constrained to 1–7; service durations must be positive;
  slugs, join codes and brand colours are format-checked.
- `appointments` is published to `supabase_realtime`. RLS still applies to the
  realtime payloads.

### Visits

```
pending → confirmed → arrived → in_consultation → completed
              └──────────────────────┘   (a doctor may start from confirmed)
+ cancelled (before the consultation)   + no_show (once the time has passed)
```

A trigger holds everyone but admins (and the service role) to that flow, and
stamps `arrived_at`, `started_at`, `completed_at`. Only doctors and admins
start or complete a consultation; a patient can cancel only while pending or
confirmed.

`public.available_slots(doctor, date, service)` returns the start times a
booking screen may offer: the doctor's working weekday and listed times, no
time off, not past, and nothing overlapping for the service's whole length.
A **patient's** booking must be one of them (trigger). Staff may book off the
grid — a walk-in squeezed in at 11:10 — but never on top of another visit.

### Rescheduling

`public.reschedule_appointment(appointment, new_start, doctor?)` moves a visit
that has not started (pending or confirmed) to a time still to come, keeping
its history, notes and bill on one row. `rescheduled_from`, `rescheduled_at`,
`rescheduled_by` and `reschedule_count` record the move.

- A **patient** moves only their own visit, only to a time `available_slots`
  offers, and it goes back to `pending`: the clinic agreed to the old time,
  not the new one.
- **Staff** keep the status, may switch the doctor, and may go off the grid —
  never onto another visit.

`available_slots` takes an optional fourth argument, the visit being moved, so
a 60-minute visit can still shift by 30 minutes. A patient's own `UPDATE` may
change the status (to cancel) and nothing else.

### Billing

```
draft ──issue──→ issued ⇄ paid        (paid once the payments cover it)
  │                 └──void──→ void   (only with no payments standing)
  └─ deleted
```

- `create_invoice_for_appointment(visit)` starts a draft with the visit's
  service at the catalogue price (zero if none is set) — or returns the
  visit's existing bill. One live bill per visit.
- While a draft: add, edit and remove lines; set a discount (the apps offer
  senior citizen / PWD 20%). `issue_invoice` numbers it per clinic
  (`INV-000001`) and locks it.
- `payments` go on an issued bill, for no more than it still owes, stamped
  with who received them and *now* — they cannot be backdated. A bill with
  its balance covered becomes `paid`.
- `void_payment` is **admin only**: the front desk handles cash, so it does
  not also get to make a payment disappear. `void_invoice` needs a reason and
  no standing payments; the number stays used.
- `billing_summary(clinic, from, to)` gives money collected (by method),
  billed, and outstanding.

The front desk and admins bill (`private.can_bill`); doctors read. A patient
reads their own bills once issued, never drafts. These are **statements of
account, not BIR official receipts** — nothing here is an accredited receipting
system, and the apps say so on every bill.

### Notifications

Supabase has no push service of its own; this uses its standard pieces.

```
appointments / invoices ──trigger──→ notifications ──pg_net──→ send-push ──Web Push──→ browsers
                                          │                    (Edge Function)
                                          └── Realtime ──→ the in-app inbox
pg_cron ──every 15 min──→ send_visit_reminders()
```

| Who | Hears about |
|---|---|
| patient | visit confirmed, moved or cancelled by the clinic; a note from the doctor; a bill issued; a reminder within 24 h of a confirmed visit |
| front desk (assistants, admins) | a patient's booking request, move or cancellation |
| doctor | their patient is in the waiting room |

Nobody is told about their own action; walk-ins without an account and the
service role notify no one. Each notification belongs to one **app**, and is
pushed only to browsers subscribed in that app, with a link into it.

The apps are web builds, so this is standard Web Push with a VAPID key — no
Firebase project, no app-store builds. On iPhone, Web Push reaches a site only
once it is added to the home screen (iOS 16.4+); the inbox reaches everyone.
Signing out removes that browser's subscription first, so a shared device does
not keep receiving the last person's notifications.

## Tenancy

**Belonging.** Staff belong to a clinic through a membership, which carries
their role *at that clinic*. Patients belong through a chart there. Nothing
else grants anything: a fresh signup sees no clinics, no rosters and no
records until they join one.

**Seeing.** A user reads a clinic — its roster, its catalogue, its charts and
appointments — only if they belong to it. Two dental clinics on the platform
cannot see each other's staff, services or patients.

**Shared identity, private charts.** When a person is a patient at two clinics,
both clinics can read their `persons` row (name, phone), because both need to
contact them. Each clinic's chart, and the clinical notes on it, is visible
only to that clinic.

**Clinical notes, clinicians only.** Within a clinic, `chart_notes` and
`visit_notes` are readable and writable by its doctors and admins — not by the
front desk, and not by the patient. They are separate tables rather than
columns because RLS filters rows, not columns: the front desk has to read the
chart and the appointment, and the patient has to read their appointment. A
patient reads only `appointments.patient_note`, which only a clinician can
write (a guard trigger).

**Getting in.**

- A patient joins with the clinic's code: `join_clinic` creates their chart.
- A clinic admin adds staff with `invite_staff` (the person must already have
  an account) and removes them with `remove_staff`.
- The front desk registers walk-ins with `book_walk_in`.

A walk-in who is already a patient elsewhere becomes a *new* person record at
this clinic. Matching them across clinics would mean one clinic's front desk
searching another clinic's patients, which is exactly what the model prevents.
Merging duplicates is an operator task.

## Roles and access

Four roles, matching the four apps, each held **per clinic**. Every table is
deny-by-default and `anon` reads no table. Its one door is
`public.clinic_by_slug(slug)`: the public page at `/:clinic` in the apps —
name, branding, contact details, active services and active doctors of an
active clinic. Never the join code, never a doctor's account.

| | patient | doctor | assistant | admin |
|---|---|---|---|---|
| Own appointments | read | — | — | — |
| Clinic appointments | — | read | read | read |
| Book | self, `pending` only | clinic | clinic | clinic |
| Confirm / complete | **no** | clinic | clinic | clinic |
| Cancel own booking | yes | — | — | — |
| Delete appointment | no | no | no | clinic |
| Charts | own (read) | clinic | clinic | clinic |
| Person details | own | clinic's patients | clinic's patients | clinic's patients |
| Register walk-in | — | — | yes | yes |
| Doctor roster | read | read + own availability | read | write |
| Services | read | read | read | write |
| Clinic details, logo, colour, join code | — | — | — | write |
| Staff | — | — | — | add, approve staff codes, change role, remove |
| Reschedule | own, to an offered time; back to `pending` | clinic | clinic | clinic |
| Bills and lines | own, once issued (read) | read | write | write |
| Take a payment | — | — | yes | yes |
| Void a payment | — | — | — | yes |
| Notifications | own inbox | own inbox | own inbox | own inbox |

"Clinic" always means *a clinic where the user holds that role*.

A **branch admin** is an `admin` membership with `branch_locked = true`. It
passes every admin check at that clinic — the column above applies in full —
except managing admins: `invite_staff` and `remove_staff` refuse to let it
create, change or remove an admin of either kind.

Deliberate hard edges:

- **Patients cannot confirm their own bookings.** Inserts are forced to
  `status = 'pending'`; the only change a patient may make is `'cancelled'`,
  or a move through `reschedule_appointment`, which sends it back to pending.
  They cannot read or write clinical notes at all, only the `patient_note`
  their doctor leaves on an appointment.
- **A signup grants nothing.** `handle_new_user` creates a profile and ignores
  everything in `raw_user_meta_data` except the display name. There is no role
  on an account to escalate.
- **Roles are per clinic.** An admin role granted by one clinic has no effect at
  any other clinic the same account belongs to. (With the old account-wide
  role, it did — see `20260914120200_staff_across_clinics.sql`.)
- **Admins run their clinic, not the platform.** Column privileges let an admin
  edit their clinic's name, logo, colour, contact details, timezone and join
  code, but not its vertical, slug or `is_active`.
- **Every clinic keeps at least one full admin.** `invite_staff` and
  `remove_staff` refuse to demote, branch-lock or remove the last one.
- **A branch admin is an admin at one branch only.** A trigger on
  `clinic_memberships` rejects any admin membership elsewhere for an account
  holding a branch-locked one, whoever writes it — service role included.
- **A staff code grants nothing by itself.** Codes are single-use, per person,
  for `doctor` or `assistant`, and expire. `redeem_staff_invite` only files a
  request; the membership (and a doctor's roster link) is created when an admin
  approves it with `decide_staff_request`. `staff_invites` has no write policy
  at all.

## Setup

### 1. Create the project

At [supabase.com/dashboard](https://supabase.com/dashboard), create a project in
the **Southeast Asia (Singapore)** region — closest to PH users. Save the
database password.

### 2. Apply the schema and seed

With the CLI (`brew install supabase/tap/supabase`):

```sh
supabase link --project-ref <your-project-ref>
supabase db push                       # applies every migration, in order
psql "$DATABASE_URL" -f supabase/seed.sql
```

Or paste each migration into the SQL Editor in filename order, then `seed.sql`.

### 3. Demo accounts

```sh
supabase db query --linked "$(cat supabase/dev/create_demo_users.sql)"
```

Creates five accounts (password `demo1234`), including `admin@brightsmile.ph`,
an admin at a second dental clinic, which is the quickest way to watch tenant
isolation work: sign in as it and D-Touch does not exist.

Seeded UUIDs are stable and traceable: `1…` clinics, `2…` doctors, `3…` charts,
`4…` appointments, `5…` persons. Demo join codes are fixed: `DTOUCH26`,
`CLEARV26`, `STARS026`, `BRIGHT26`.

### 4. A real clinic

Follow [docs/onboarding.md](docs/onboarding.md).

### 5. Password reset emails

The apps reset passwords with a one-time code typed into the app, not a link,
so no redirect URLs are involved. Two dashboard settings are needed before it
works for real users:

1. **Custom SMTP** — *Authentication → Emails → SMTP Settings*. Supabase's
   built-in mailer only delivers to members of the project's team, a few
   emails an hour. Any provider works (Resend, Brevo and Postmark have free
   tiers); verify a sending domain with them first.
2. **The Reset Password template** — *Authentication → Emails → Templates →
   Reset Password*. The default body only has a link, and the apps ask for the
   code. Replace it with something that shows `{{ .Token }}`:

   ```html
   <h2>Reset your password</h2>
   <p>Enter this code in the app:</p>
   <p style="font-size:24px;letter-spacing:4px"><strong>{{ .Token }}</strong></p>
   <p>It expires in an hour. If you did not ask for this, you can ignore it.</p>
   ```

Then check *Authentication → Rate Limits*: the email limit caps password resets
per hour across the whole project.

### 6. Push notifications

The inbox works as soon as the migrations are in. Push needs four more steps,
once per project:

1. **Secrets for the function.** `supabase/functions/.env` (gitignored; copy
   `.env.example`) holds the VAPID key pair, a contact address, and a shared
   secret. Generate a key pair with `npx web-push generate-vapid-keys` and put
   its **public** half in the apps too (`SupabaseConfig.vapidPublicKey`, or
   `--dart-define=VAPID_PUBLIC_KEY=…`). Then:

   ```sh
   supabase secrets set --env-file supabase/functions/.env
   ```

2. **Deploy the function** (`config.toml` turns off its JWT check; the shared
   secret is what authorises the database's calls):

   ```sh
   supabase functions deploy send-push --use-api
   ```

3. **Tell the database where it is**, in the SQL Editor, with the same secret:

   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/send-push', 'push_function_url');
   select vault.create_secret('<PUSH_WEBHOOK_SECRET>', 'push_webhook_secret');
   ```

4. Check that the migration scheduled the reminders:
   `select jobname, schedule from cron.job;` lists `visit-reminders` and
   `prune-notifications`.

To see a delivery fail, look at `net._http_response` (the database's side) and
the function's logs in the dashboard.

### Upgrading a project that predates the tenancy migrations

The `20260914…` migrations carry existing data over: each patient becomes a
person with one chart per clinic they had appointments at (clinical notes stay
on the original clinic's chart), self-signups with no clinic and no visits keep
their identity but get no chart, and account-wide roles move onto memberships.
Each migration's header describes exactly what it does to existing rows.

For a project holding only demo data, a clean slate is simpler:
`supabase db reset --linked`, then the seed and demo accounts. **That deletes
everything in the project.**

Either way, the deployed apps stop working the moment these migrations land —
they read columns that no longer exist — until the matching frontend is
deployed. Ship both together.

## Tests

```sh
./supabase/tests/run.sh
```

Spins up a throwaway Postgres cluster, applies every migration, seeds twice (to
prove the seed is idempotent), and runs 395 checks: seed integrity, the
declarative constraints, the auth bridge, RLS from the perspective of a patient,
doctor, assistant, admin and anonymous caller, isolation between two dental
tenants, the onboarding functions, branch admins, the staff-code flow, the
visit flow and availability, rescheduling, billing, and who is notified of
what. The test cluster has no pg_net or pg_cron, so it checks what lands in
the inbox, not delivery.

Needs a local Postgres 15+ (Postgres.app, or `brew install postgresql@17`).
**No Docker and no Supabase CLI required** — `tests/supabase_shim.sql` stubs the
Supabase-managed pieces (`auth.users`, `auth.uid()`, the `anon`/`authenticated`
roles) and is never applied to a real project.

To run against `supabase start` instead:

```sh
PGPORT=54322 PGDATABASE=postgres ./supabase/tests/rls_test.sh
```

One thing the harness encodes, because it is easy to get wrong: an RLS-filtered
`UPDATE`/`DELETE` does **not** raise — it silently matches zero rows. Only
`INSERT` (and a failing `WITH CHECK`) raises. So denial of a write is asserted
by row count via `RETURNING`, never by expecting an error.
