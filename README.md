# health-platform-be

Supabase backend for [health-platform-fe](../health-platform-fe) — a Flutter
Melos workspace with four apps (patient, doctor, assistant, admin) running three
clinic flavors (dental, optometry, pediatrics).

There is no custom server. This repo is the database: schema migrations, Row
Level Security policies, and seed data. The apps talk to Supabase directly
through `supabase_flutter`.

## One project, four apps, three clinics

A Supabase *project* is one Postgres database + one auth instance + one API URL.
It is not per client app:

- **All four Flutter apps** connect to this single project. They differ by the
  role on the signed-in user's profile, not by endpoint.
- **All three clinic flavors** live in the same database as rows in `clinics`.
  Isolation is enforced by RLS, not by separate projects.

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
    20260817120000_init_schema.sql   tables, enums, constraints, triggers
    20260817120100_rls_policies.sql  private helpers + every RLS policy
  seed.sql                           MockData ported to SQL, re-runnable
  tests/
    run.sh                           throwaway cluster → migrate → seed → test
    rls_test.sh                      69 behavioural checks
    supabase_shim.sql                test-only stubs for Supabase's auth schema
```

## Schema

| Table | Purpose |
|---|---|
| `clinics` | The three tenants. `type` is the `clinic_type` enum. |
| `profiles` | 1:1 with `auth.users`. Holds the `app_role` that drives every RLS decision. |
| `clinic_memberships` | Which clinics a staff member works at. Patients have no row. |
| `services` | Per-clinic service catalogue with durations (was a hardcoded Dart list). |
| `doctors` | Roster, specialty, `available_weekdays`, `available_time_slots`. |
| `patients` | Charts. `profile_id` is nullable so assistants can register walk-ins with no account. |
| `appointments` | The core table. `service_name` snapshots the service at booking time so renaming a service never rewrites history. |

Integrity is declarative wherever possible:

- **No double-booking** — a partial unique index on `(doctor_id, scheduled_at)`
  excluding cancelled rows, so a freed slot can be rebooked.
- **No cross-clinic bookings** — composite foreign keys mean an appointment's
  doctor *and* service must belong to its clinic. No trigger needed.
- `available_weekdays` is constrained to 1–7; service durations must be positive.
- `appointments` is published to `supabase_realtime`, so the admin dashboard and
  the assistant check-in screen can update live. RLS still applies to the
  realtime payloads.

## Roles and access

Four roles, matching the four apps. Every table is deny-by-default and `anon`
gets nothing — all four apps require a signed-in user.

| | patient | doctor | assistant | admin |
|---|---|---|---|---|
| Own appointments | read | — | — | — |
| Clinic appointments | — | read | read | read |
| Book | self, `pending` only | clinic | clinic | clinic |
| Confirm / complete | **no** | clinic | clinic | clinic |
| Cancel own booking | yes | — | — | — |
| Delete appointment | no | no | no | yes |
| Patient charts | own only | treating clinic | treating clinic | treating clinic |
| Register walk-in | — | — | yes | yes |
| Doctor roster | read | read + own availability | read | write |
| Services | read | read | read | write |

Two deliberate hard edges:

- **Patients cannot confirm their own bookings.** Inserts are forced to
  `status = 'pending'`; the only status change a patient may make is
  `'cancelled'`.
- **Nobody can escalate their own role.** `handle_new_user` always assigns
  `'patient'` and deliberately ignores `raw_user_meta_data->>'role'`, because
  that field is client-supplied — honouring it would let anyone sign up as an
  admin. A trigger additionally blocks all role changes that do not come from
  the service role key.

### Why `patients.registered_clinic_id` exists

A clinic's roster cannot be defined as "patients who have an appointment here" —
a walk-in registered ten seconds ago has no appointment yet, so the assistant
who just created the record could not read it back, and `.insert().select()`
(which supabase-dart uses to return the inserted row) would fail outright.
`registered_clinic_id` is the patient's home clinic; staff see their roster plus
anyone referred in via an appointment.

## Setup

### 1. Create the project

At [supabase.com/dashboard](https://supabase.com/dashboard), create a project in
the **Southeast Asia (Singapore)** region — closest to PH users. Save the
database password.

### 2. Apply the schema

**Dashboard** (no tooling needed): open the SQL Editor and run, in order:

1. `supabase/migrations/20260817120000_init_schema.sql`
2. `supabase/migrations/20260817120100_rls_policies.sql`
3. `supabase/seed.sql`

**Or the CLI** (`brew install supabase/tap/supabase`):

```sh
supabase link --project-ref <your-project-ref>
supabase db push          # applies both migrations
psql "$DATABASE_URL" -f supabase/seed.sql
```

### 3. Wire up a test user

The seed creates clinical records, not accounts. To sign in as Juan (the patient
app's current user), sign up through the app or the dashboard, then link and
promote with the **service role key** / SQL editor:

```sql
-- Link a signed-up account to a seeded patient chart
update public.patients
   set profile_id = '<auth-user-uuid>'
 where id = '30000000-0000-0000-0000-000000000001';   -- Juan dela Cruz

-- Promote a user to clinic staff (role changes require the service role)
update public.profiles set role = 'assistant' where id = '<auth-user-uuid>';
insert into public.clinic_memberships (profile_id, clinic_id)
values ('<auth-user-uuid>', '10000000-0000-0000-0000-000000000001');  -- dental

-- For a doctor, also link the roster row
update public.doctors set profile_id = '<auth-user-uuid>'
 where id = '20000000-0000-0000-0000-000000000001';   -- Dr Maria Santos
```

Seeded UUIDs are stable and traceable: `1…` clinics, `2…` doctors, `3…`
patients, `4…` appointments, with ordinals following the Dart fixture order
(doctor `…0004` is the mock's `o1`, Dr Bautista).

## Tests

```sh
./supabase/tests/run.sh
```

Spins up a throwaway Postgres cluster, applies both migrations, seeds twice (to
prove the seed is idempotent), and runs 69 checks — seed integrity, the
declarative constraints, the auth bridge, and RLS from the perspective of a
patient, a doctor, an assistant, and an anonymous caller.

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

## Next: wiring the frontend

Nothing in the Flutter workspace points here yet — it still reads
`MockData`. The swap is contained to `packages/dependencies`:

1. Add `supabase_flutter` to `packages/dependencies/pubspec.yaml`.
2. Add `fromJson`/`toJson` to the models. Column names are snake_case
   (`scheduled_at`, `full_name`, `clinic_type`), Dart fields are camelCase.
3. Convert the Riverpod providers in
   `packages/dependencies/lib/src/providers/` from synchronous `Provider`s over
   `MockData` to `AsyncNotifierProvider`s over Supabase queries. Every read is
   already funnelled through these, so no screen needs to change shape.
4. Replace `currentPatientIdProvider` (hardcoded `'pt1'`) and
   `currentDoctorProvider` (first doctor of the clinic type) with lookups
   against the signed-in user's `profile_id`.
5. `MockData`'s appointment dates are pinned to 2026-05-09, so they are already
   stale. The seed uses relative dates instead; drop the fixture rather than
   maintaining both.
