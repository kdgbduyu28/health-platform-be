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
  seed.sql                                    four demo tenants, re-runnable
  dev/
    create_demo_users.sql                     demo accounts wired to the seed
    provision_clinic.sql                      onboard a real clinic
  tests/
    run.sh                                    throwaway cluster → migrate → seed → test
    rls_test.sh                               164 behavioural checks
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
| `services` | Per-clinic service catalogue with durations. |
| `doctors` | Per-clinic roster. The same account may be on several clinics' rosters. |
| `persons` | Who someone is: name, phone, email, DOB, optional account link. One per human. |
| `patients` | A **chart**: one per (person, clinic). Belongs to that clinic forever. |
| `appointments` | The core table. `service_name` snapshots the service at booking time so renaming a service never rewrites history. `patient_note` is what the doctor wants the patient to read. |
| `chart_notes` | The standing medical note on a chart (allergies, conditions). Clinicians only. |
| `visit_notes` | The consultation note on an appointment. Clinicians only. |

Integrity is declarative wherever possible:

- **No double-booking** — a partial unique index on `(doctor_id, scheduled_at)`
  excluding cancelled rows, so a freed slot can be rebooked.
- **No cross-clinic bookings** — composite foreign keys pin an appointment's
  doctor, service *and chart* to its clinic. No trigger needed.
- **One chart per person per clinic**, and a chart can never move to another
  person or clinic (a trigger, since RLS cannot compare old and new rows).
- `available_weekdays` is constrained to 1–7; service durations must be positive;
  slugs, join codes and brand colours are format-checked.
- `appointments` is published to `supabase_realtime`. RLS still applies to the
  realtime payloads.

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
deny-by-default and `anon` gets nothing.

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
| Staff | — | — | — | invite, change role, remove |

"Clinic" always means *a clinic where the user holds that role*.

Deliberate hard edges:

- **Patients cannot confirm their own bookings.** Inserts are forced to
  `status = 'pending'`; the only change a patient may make is `'cancelled'`.
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
- **Every clinic keeps at least one admin.** `invite_staff` and `remove_staff`
  refuse to demote or remove the last one.

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
prove the seed is idempotent), and runs 164 checks: seed integrity, the
declarative constraints, the auth bridge, RLS from the perspective of a patient,
doctor, assistant, admin and anonymous caller, isolation between two dental
tenants, and the onboarding functions.

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
