# Onboarding a clinic

How to add a new clinic client to the platform, from first email to their
first patient booking. Written as a checklist: work top to bottom.

**You need:** access to the Supabase project's SQL editor (or the CLI linked to
it). **The clinic needs:** someone who will be its administrator.

Nothing here involves a code change, a new build, or a deploy. If a step seems
to need one, stop — something is wrong.

---

## 1. Collect from the clinic

| What | Example | Notes |
|---|---|---|
| Clinic name | BrightSmile Dental Studio | As patients should see it. |
| Kind of clinic | Dental | Must match a vertical, or you add one (step 3). |
| Brand colour | `#1F8A70` | Optional. Without it the app uses the platform colour. |
| Logo | a square PNG | Optional. Without it the app shows the vertical's icon. |
| Administrator's email | owner@brightsmile.ph | They will manage staff and settings. |
| Services and durations | Teeth Cleaning, 45 min | Can be added later, but patients cannot book without them. |
| Doctors | Dr Paolo Villanueva, Cosmetic Dentistry | Name, specialty, working days, time slots. |

## 2. The administrator creates an account

Ask them to open any of the four apps, choose **Create an account**, and sign up
with the email above. If email confirmation is on, they confirm it.

They will then see **No clinic access yet**. That is expected; step 4 fixes it.

> The account must exist first. The database cannot create sign-in accounts on
> its own, so every "add this person" step on the platform takes an email that
> has already signed up.

## 3. Provision the clinic

Open `supabase/dev/provision_clinic.sql` and edit the constants at the top:
name, slug, vertical, colour, the admin's email, and the services list.

- **slug** is permanent and URL-safe: lowercase letters, digits and dashes
  (`brightsmile-dental-studio`). The clinic's admin cannot change it later.
- **vertical**: use an existing one (`dental`, `optometry`, `pedia`) or a new
  slug. For a new vertical, also set its display name and a
  [Material icon name](https://fonts.google.com/icons) (e.g. `face` for
  dermatology). An unknown icon name falls back to a generic clinic icon.

Run it:

```sh
supabase db query --linked "$(cat supabase/dev/provision_clinic.sql)"
```

The output shows the new clinic and its **join code**. Keep that code for step 7.

If it fails with *no account for …*, step 2 is not done yet or the email differs.

## 4. Check the administrator can get in

Ask the administrator to sign in to the **admin app** (or tap **Try again** if
they are still on the *No clinic access yet* screen). They should see their
clinic's dashboard — and nothing about any other clinic.

## 5. Branding

In the admin app: **Clinic → Edit details** (the pencil).

- **Brand colour**: `#RRGGBB`. The app re-themes as soon as it is saved.
- **Logo URL**: an `https://` link to a square image. Host it anywhere public; a
  public Supabase Storage bucket in this project works well. If the link breaks
  later, the app quietly falls back to the icon.
- Contact phone and address.

The administrator can do this themselves; you only need to if they ask.

## 6. Doctors

> **Gap:** there is no admin screen for the doctor roster yet, so this step is
> still SQL.

Add each doctor to the roster:

```sql
insert into public.doctors
  (clinic_id, full_name, specialty, available_weekdays, available_time_slots)
select id, 'Paolo Villanueva', 'Cosmetic Dentistry',
       '{1,2,3,4,5}',                         -- 1 = Monday … 7 = Sunday
       '{09:00,09:30,10:00,10:30,11:00,11:30}'
  from public.clinics where slug = 'brightsmile-dental-studio';
```

A doctor who will use the **doctor app** then joins with a staff code (step 8).
When the administrator approves them, they pick this roster row and it is
linked to the doctor's account — no SQL. (Approving can also create a new
roster row, but without working days or time slots, which are still SQL.)

A doctor can be on several clinics' rosters with the same account.

## 7. Patients

Give the clinic its join code (also shown in the admin app under
**Clinic → Patient join code**). Patients install the patient app, create an
account, and enter the code. They then see that clinic — and only that clinic —
and can book.

Walk-ins need nothing: the front desk registers them from the assistant app.

The administrator can **rotate** the code if it spreads too far (the old code
stops working; joined patients are unaffected) or **turn it off** entirely.

## 8. Staff

**Doctors and assistants join with a staff code.** In the admin app,
**Clinic → Staff requests → New code**:

1. Pick **Doctor** or **Assistant**, optionally note who it is for, and create
   the code. One code per person: it works once and expires in 7 days.
2. Give that person the code.
3. They create an account in the doctor or assistant app, sign in, and enter
   the code. That files a request; it grants nothing yet.
4. The request appears under **Staff requests**, and the Clinic tab shows a
   badge. **Approve** or **Decline**. Approving a doctor asks which roster row
   is theirs (step 6), or creates one with their specialty.
5. They tap **Check again** in their app.

Unused codes can be cancelled from the same list. Roles:

- **Assistant** — front desk: check-in, walk-ins, confirmations.
- **Doctor** — their own schedule and consultation notes.

**Admins are added by email**, by a full admin, in **Clinic → Staff → Add**:
the person signs up in any app first, then the admin enters that email and
picks **Admin**.

- **Full admin** — everything: clinic settings, join code, staff, and other
  admins.
- **Branch admin** (the *Branch admin* switch) — everything at this clinic
  *except* adding, changing or removing admins. They approve doctors and
  assistants like any admin. A branch admin cannot be an admin at any other
  clinic.

A full admin can also add a doctor or assistant by email directly, skipping the
code — but that does not link a doctor's roster row.

Tapping a staff member changes their role; the remove icon takes their access
away. Branch admins cannot change or remove admins. A clinic always keeps at
least one **full** admin — the app refuses to remove, demote or branch-lock the
last one.

A role applies to this clinic only. Someone who is an admin here and a doctor
elsewhere stays exactly that.

## 9. Verify isolation

Do this once per new clinic. It takes two minutes and is the one check that
matters most.

- [ ] Signed in as the new clinic's admin, the admin app shows **only** the new
      clinic. No other clinic's name, patients or appointments appear anywhere.
- [ ] Signed in as a patient who joined with the new code, the patient app shows
      **only** the new clinic's doctors and services.
- [ ] Signed in as a D-Touch admin, the new clinic does not appear.

If any of these fail, stop and investigate before the clinic goes live.

---

## Troubleshooting

**"No clinic access yet" after being added.** The email added in the admin app
does not match the one they signed up with (check for typos, or a personal vs
work address), or they are in the wrong app — an assistant opening the doctor
app sees this too. Tap **Try again** after fixing it.

**"That clinic code is not valid."** The code was mistyped, rotated, or turned
off — or the clinic is inactive. Codes ignore case and spaces.

**"That staff code is not valid, has expired, or was already used."** Staff
codes work once and for 7 days. Issue a new one. A patient join code is not a
staff code.

**"This code is for the Doctor app."** A doctor's code was entered in the
assistant app, or the other way round.

**Nobody receives the password reset email.** The project is still on
Supabase's built-in mailer, which only delivers to the project's own team. See
*Password reset emails* in the README.

**The same patient appears twice.** They were registered as a walk-in and later
joined with the code from their own account, which creates a separate person
record. Merging is an operator task: repoint the walk-in's charts to the
account's person record as the service role, then delete the empty person.

**Clinic admin wants to rename the slug or change the vertical.** Operator-only,
by design. Update `clinics` as the service role.

## Suspending a clinic

> **Gap:** `is_active = false` currently only stops *new* patients joining with
> the code. It does not cut off staff or existing patients.

Until suspension is implemented properly, removing access means deleting the
clinic's `clinic_memberships` rows (staff) as the service role. Patients keep
read access to their own records, which is usually what you want.
