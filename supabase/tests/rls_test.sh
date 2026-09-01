#!/bin/zsh
# Behavioural checks for the health-platform schema + RLS.
#
# Note on assertions: an RLS-filtered UPDATE/DELETE does not raise — it simply
# matches zero rows. So write-denial is asserted with expect_dml(... RETURNING)
# and a count of 0, never with expect_err. expect_err is reserved for genuine
# constraint violations and WITH CHECK failures.
# Connection comes from the environment so this can run against the throwaway
# cluster started by run.sh, or against `supabase start`'s local Postgres
# (PGPORT=54322 PGUSER=postgres PGDATABASE=postgres).
: ${PGHOST:=127.0.0.1} ${PGPORT:=55432} ${PGUSER:=postgres} ${PGDATABASE:=hp}
CONN=(-h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -X -q -t -A -v ON_ERROR_STOP=1)

pass=0; fail=0
trim() { print -r -- "${${1##[[:space:]]##}%%[[:space:]]##}" }

# expect_eq <label> <sql> <expected-scalar>
expect_eq() { local out; out=$(trim "$(psql $CONN -c "$2" 2>&1)")
  if [[ "$out" == "$3" ]]; then print "PASS  $1  ($out)"; ((pass++))
  else print "FAIL  $1  expected '$3', got '$out'"; ((fail++)); fi }

# expect_err <label> <sql>   — must raise
expect_err() { local out
  if out=$(psql $CONN -c "$2" 2>&1); then
    print "FAIL  $1 (expected rejection, but it succeeded)"; ((fail++))
  else print "PASS  $1  [${${(f)out}[1]}]"; ((pass++)); fi }

# expect_ok <label> <sql>    — must succeed
expect_ok() { local out
  if out=$(psql $CONN -c "$2" 2>&1); then print "PASS  $1"; ((pass++))
  else print "FAIL  $1\n      ${${(f)out}[1]}"; ((fail++)); fi }

# expect_dml <label> <session-setup> <dml-with-RETURNING> <expected-row-count>
# Runs setup + DML in one transaction and rolls back, so checks never
# contaminate each other.
expect_dml() { local out
  out=$(trim "$(psql $CONN <<SQL 2>&1
begin;
$2
with x as ($3) select count(*) from x;
rollback;
SQL
)")
  if [[ "$out" == "$4" ]]; then print "PASS  $1  ($out row(s) written)"; ((pass++))
  else print "FAIL  $1  expected $4, got '$out'"; ((fail++)); fi }

JUAN_AUTH='aaaaaaaa-0000-0000-0000-000000000001'
DOC_AUTH='aaaaaaaa-0000-0000-0000-000000000002'
ASST_AUTH='aaaaaaaa-0000-0000-0000-000000000003'
DENTAL='10000000-0000-0000-0000-000000000001'
OPTO='10000000-0000-0000-0000-000000000002'
DR_SANTOS='20000000-0000-0000-0000-000000000001'
DR_BAUTISTA='20000000-0000-0000-0000-000000000004'
PT_JUAN='30000000-0000-0000-0000-000000000001'
PT_MARIA='30000000-0000-0000-0000-000000000002'
A2='40000000-0000-0000-0000-000000000002'
A4='40000000-0000-0000-0000-000000000004'

print "\n── Seed integrity ─────────────────────────────────────────────"
expect_eq "3 clinics"       "select count(*) from public.clinics;" 3
expect_eq "9 doctors"       "select count(*) from public.doctors;" 9
expect_eq "6 patients"      "select count(*) from public.patients;" 6
expect_eq "18 appointments" "select count(*) from public.appointments;" 18
expect_eq "23 services"     "select count(*) from public.services;" 23
expect_eq "every appt resolved to a real service row" \
  "select count(*) from public.appointments where service_id is null;" 0
expect_eq "appointments today (Manila)" \
  "select count(*) from public.appointments
   where (scheduled_at at time zone 'Asia/Manila')::date
       = (now() at time zone 'Asia/Manila')::date;" 8
# Compare DATES in Manila, never `scheduled_at > now()`: eight of the seeded
# appointments are today at 08:00–15:00, so a wall-clock comparison flips
# between 14 and 6 depending on what time of day the suite runs.
expect_eq "future-dated appointments" \
  "select count(*) from public.appointments
   where (scheduled_at at time zone 'Asia/Manila')::date
       > (now() at time zone 'Asia/Manila')::date;" 6
expect_eq "past-dated appointments" \
  "select count(*) from public.appointments
   where (scheduled_at at time zone 'Asia/Manila')::date
       < (now() at time zone 'Asia/Manila')::date;" 4
expect_eq "completed appointments" "select count(*) from public.appointments where status='completed';" 5
expect_eq "09:00 Manila == 01:00 UTC" \
  "select to_char(scheduled_at at time zone 'UTC','HH24:MI')
   from public.appointments where id='40000000-0000-0000-0000-000000000001';" "01:00"
expect_eq "every appointment's doctor is in its clinic" \
  "select count(*) from public.appointments a join public.doctors d on d.id=a.doctor_id
   where d.clinic_id <> a.clinic_id;" 0

print "\n── Declarative integrity ──────────────────────────────────────"
expect_err "double-booking a doctor is rejected" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   select clinic_id,'$PT_JUAN',doctor_id,'Teeth Cleaning',scheduled_at
   from public.appointments where id='40000000-0000-0000-0000-000000000001';"
expect_ok "rebooking a CANCELLED slot is allowed" \
  "begin;
   update public.appointments set status='cancelled' where id='$A2';
   insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Dental Filling',
           (select scheduled_at from public.appointments where id='$A2'));
   rollback;"
expect_err "doctor from another clinic is rejected" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$OPTO','$PT_JUAN','$DR_SANTOS','Eye Examination', now()+interval '40 days');"
expect_err "service from another clinic is rejected" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS',
           (select s.id from public.services s
              join public.clinics c on c.id = s.clinic_id
             where c.type='optometry' and s.name='Retinal Exam'),
           'Retinal Exam', now()+interval '41 days');"
expect_err "invalid weekday (8) is rejected" \
  "insert into public.doctors (clinic_id,full_name,specialty,available_weekdays)
   values ('$DENTAL','Test Doc','Testing','{1,8}');"
expect_err "zero-length service duration is rejected" \
  "insert into public.services (clinic_id,name,duration_minutes) values ('$DENTAL','Bogus',0);"

print "\n── Auth bridge ────────────────────────────────────────────────"
expect_ok "create three auth users" \
  "insert into auth.users (id,email,raw_user_meta_data) values
     ('$JUAN_AUTH','juan@email.com','{\"full_name\":\"Juan dela Cruz\",\"role\":\"admin\"}'),
     ('$DOC_AUTH','santos@clinic.ph','{\"full_name\":\"Maria Santos\"}'),
     ('$ASST_AUTH','front@clinic.ph','{}');"
expect_eq "profiles auto-created by trigger" "select count(*) from public.profiles;" 3
expect_eq "client-supplied 'admin' role in metadata was IGNORED" \
  "select role from public.profiles where id='$JUAN_AUTH';" "patient"
expect_eq "full_name carried over from metadata" \
  "select full_name from public.profiles where id='$DOC_AUTH';" "Maria Santos"
expect_eq "empty metadata falls back to the email local-part" \
  "select full_name from public.profiles where id='$ASST_AUTH';" "front"
expect_ok "link Juan's account to his patient record" \
  "update public.patients set profile_id='$JUAN_AUTH' where id='$PT_JUAN';"
expect_ok "promote Dr Santos to doctor + link (service role)" \
  "update public.profiles set role='doctor' where id='$DOC_AUTH';
   update public.doctors set profile_id='$DOC_AUTH' where id='$DR_SANTOS';
   insert into public.clinic_memberships (profile_id,clinic_id) values ('$DOC_AUTH','$DENTAL');"
expect_ok "promote front desk to assistant at dental" \
  "update public.profiles set role='assistant' where id='$ASST_AUTH';
   insert into public.clinic_memberships (profile_id,clinic_id) values ('$ASST_AUTH','$DENTAL');"

# `set` (not `select set_config`) keeps scalar output clean.
juan="set role authenticated; set request.jwt.claim.sub = '$JUAN_AUTH';"
doc="set role authenticated;  set request.jwt.claim.sub = '$DOC_AUTH';"
asst="set role authenticated; set request.jwt.claim.sub = '$ASST_AUTH';"
anon="set role anon;"

print "\n── RLS · patient (Juan) ───────────────────────────────────────"
expect_eq "sees only his own 6 appointments"    "$juan select count(*) from public.appointments;" 6
expect_eq "…spanning all three clinics"         "$juan select count(distinct clinic_id) from public.appointments;" 3
expect_eq "sees only his own patient record"    "$juan select count(*) from public.patients;" 1
expect_eq "can browse the full doctor roster"   "$juan select count(*) from public.doctors;" 9
expect_eq "can browse all services"             "$juan select count(*) from public.services;" 23
expect_eq "cannot see other patients"           "$juan select count(*) from public.patients where id<>'$PT_JUAN';" 0
expect_eq "cannot see other patients' profiles" "$juan select count(*) from public.profiles;" 1
expect_dml "CAN cancel his own appointment" "$juan" \
  "update public.appointments set status='cancelled' where id='$A4' returning id" 1
expect_err "cannot CONFIRM his own appointment" \
  "$juan update public.appointments set status='confirmed' where id='$A4';"
expect_err "cannot escalate his own role" \
  "$juan update public.profiles set role='admin' where id='$JUAN_AUTH';"
expect_dml "CAN update his own phone" "$juan" \
  "update public.patients set phone='09990000000' where id='$PT_JUAN' returning id" 1
expect_dml "cannot touch another patient's record" "$juan" \
  "update public.patients set medical_notes='x' where id='$PT_MARIA' returning id" 0
expect_dml "cannot cancel someone else's appointment" "$juan" \
  "update public.appointments set status='cancelled' where id='$A2' returning id" 0
expect_dml "CAN book a pending appointment for himself" "$juan" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal',now()+interval '61 days','pending') returning id" 1
expect_err "cannot book a pre-CONFIRMED appointment" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal',now()+interval '60 days','confirmed');"
expect_err "cannot book on behalf of another patient" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Root Canal',now()+interval '62 days','pending');"
expect_dml "cannot delete his own appointment" "$juan" \
  "delete from public.appointments where id='$A4' returning id" 0
expect_dml "cannot edit a doctor's availability" "$juan" \
  "update public.doctors set available_weekdays='{1}' where id='$DR_SANTOS' returning id" 0
expect_dml "cannot edit a service" "$juan" \
  "update public.services set duration_minutes=999
   where clinic_id='$DENTAL' and name='Root Canal' returning id" 0

print "\n── RLS · doctor (Dr Santos, dental) ───────────────────────────"
expect_eq "sees the dental clinic's 7 appointments" "$doc select count(*) from public.appointments;" 7
expect_eq "…and nothing outside dental"             "$doc select count(distinct clinic_id) from public.appointments;" 1
expect_eq "sees the 4 patients treated at dental"   "$doc select count(*) from public.patients;" 4
expect_dml "CAN confirm a pending appointment" "$doc" \
  "update public.appointments set status='confirmed' where id='$A2' returning id" 1
expect_dml "CAN write consultation notes" "$doc" \
  "update public.appointments set notes='Reviewed x-ray.' where id='$A2' returning id" 1
expect_dml "CAN maintain their own availability" "$doc" \
  "update public.doctors set available_weekdays='{1,2,3}' where id='$DR_SANTOS' returning id" 1
expect_dml "cannot edit another doctor's availability" "$doc" \
  "update public.doctors set available_weekdays='{1}' where id='$DR_BAUTISTA' returning id" 0
expect_dml "cannot delete an appointment (admin only)" "$doc" \
  "delete from public.appointments where id='$A2' returning id" 0
# A denied INSERT raises (WITH CHECK) rather than matching zero rows.
expect_err "cannot add a service (admin only)" \
  "$doc insert into public.services (clinic_id,name) values ('$DENTAL','Sneaky');"

print "\n── RLS · assistant (front desk, dental) ───────────────────────"
expect_eq "sees the dental clinic's 7 appointments" "$asst select count(*) from public.appointments;" 7
expect_eq "sees the dental roster + referred-in patients" "$asst select count(*) from public.patients;" 4
# The walk-in round-trip: register, read back, then book. This is the flow in
# assistant_app/lib/features/booking/walkin_booking_screen.dart, and the reason
# patients.registered_clinic_id exists.
expect_dml "CAN register a walk-in and read the row back (.insert().select())" "$asst" \
  "insert into public.patients (registered_clinic_id,full_name,phone)
   values ('$DENTAL','Walk-in Test','09171110000') returning id" 1
expect_ok "CAN register a walk-in then immediately book them" \
  "begin;
   $asst
   with p as (
     insert into public.patients (registered_clinic_id,full_name,phone)
     values ('$DENTAL','Walk-in Two','09171110001') returning id
   )
   insert into public.appointments
     (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   select '$DENTAL', p.id, '$DR_SANTOS', 'Teeth Cleaning',
          now()+interval '71 days', 'confirmed'
   from p;
   rollback;"
expect_err "cannot register a walk-in at a clinic they do not staff" \
  "$asst insert into public.patients (registered_clinic_id,full_name,phone)
   values ('$OPTO','Wrong Clinic','09171110002');"
expect_err "cannot register an orphan patient with no clinic" \
  "$asst insert into public.patients (full_name,phone) values ('Orphan','09171110003');"
expect_dml "CAN book a walk-in appointment" "$asst" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Teeth Cleaning',now()+interval '70 days','confirmed') returning id" 1
expect_dml "cannot delete an appointment (admin only)" "$asst" \
  "delete from public.appointments where id='$A2' returning id" 0

print "\n── book_walk_in (atomicity) ───────────────────────────────────"
expect_dml "books patient + appointment in one call" "$asst" \
  "select public.book_walk_in(
     '$DENTAL', 'Atomic One', '09171112221',
     '$DR_SANTOS', 'Teeth Cleaning', now() + interval '90 days') as id" 1
# The point of the function: a losing race must leave no orphan chart behind.
expect_err "double-booked slot is rejected" \
  "begin;
   $asst
   select public.book_walk_in(
     '$DENTAL', 'Atomic Two', '09171112222', '$DR_SANTOS', 'Teeth Cleaning',
     (select scheduled_at from public.appointments where id = '$A2'));
   rollback;"
expect_eq "…and rolled the patient row back with it" \
  "select count(*) from public.patients where full_name = 'Atomic Two';" 0
expect_err "blank name is rejected before any write" \
  "$asst select public.book_walk_in('$DENTAL','   ','09171112223',
     '$DR_SANTOS','Teeth Cleaning', now() + interval '91 days');"
expect_eq "…leaving no partial row" \
  "select count(*) from public.patients where phone = '09171112223';" 0
# SECURITY INVOKER means the caller's own RLS still applies inside the body.
expect_err "assistant cannot book into a clinic they do not staff" \
  "$asst select public.book_walk_in('$OPTO','Wrong Clinic','09171112224',
     '$DR_BAUTISTA','Eye Examination', now() + interval '92 days');"
expect_eq "…and created no patient there either" \
  "select count(*) from public.patients where full_name = 'Wrong Clinic';" 0
expect_err "a patient cannot call it at all" \
  "$juan select public.book_walk_in('$DENTAL','Sneaky','09171112225',
     '$DR_SANTOS','Teeth Cleaning', now() + interval '93 days');"

print "\n── RLS · cross-clinic isolation ───────────────────────────────"
expect_eq "dental staff cannot see the pedia-only patient Lisa" \
  "$asst select count(*) from public.patients
   where id='30000000-0000-0000-0000-000000000006';" 0
expect_eq "optometry appointments are invisible to dental staff" \
  "$asst select count(*) from public.appointments where clinic_id='$OPTO';" 0

print "\n── RLS · anonymous ────────────────────────────────────────────"
expect_eq "anon sees no appointments" "$anon select count(*) from public.appointments;" 0
expect_eq "anon sees no clinics"      "$anon select count(*) from public.clinics;" 0
expect_eq "anon sees no doctors"      "$anon select count(*) from public.doctors;" 0
expect_eq "anon sees no patients"     "$anon select count(*) from public.patients;" 0
expect_err "anon cannot insert an appointment" \
  "$anon insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal',now()+interval '80 days');"

print "\n── RLS coverage ───────────────────────────────────────────────"
expect_eq "no public table left without RLS" \
  "select count(*) from pg_tables t
   where t.schemaname='public'
     and not exists (select 1 from pg_class c
                     join pg_namespace n on n.oid=c.relnamespace
                     where n.nspname='public' and c.relname=t.tablename
                       and c.relrowsecurity);" 0

print "\n══════════════════════════════════════════════════════════════"
print "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
