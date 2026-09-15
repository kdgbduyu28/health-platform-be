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
  # First line of the error. Not ${${(f)out}[1]}: when the output is a single
  # line zsh treats that as a scalar, and [1] prints only its first character.
  else local first=${out%%$'\n'*}; print "PASS  $1  [$first]"; ((pass++)); fi }

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
DT_ADMIN_AUTH='aaaaaaaa-0000-0000-0000-000000000004'
BRIGHT_ADMIN_AUTH='aaaaaaaa-0000-0000-0000-000000000005'
NEWBIE_AUTH='aaaaaaaa-0000-0000-0000-000000000006'
DENTAL='10000000-0000-0000-0000-000000000001'   # D-Touch
OPTO='10000000-0000-0000-0000-000000000002'
PEDIA='10000000-0000-0000-0000-000000000003'
BRIGHT='10000000-0000-0000-0000-000000000004'   # BrightSmile: a second, unrelated dental tenant
DR_SANTOS='20000000-0000-0000-0000-000000000001'
DR_BAUTISTA='20000000-0000-0000-0000-000000000004'
PERSON_JUAN='50000000-0000-0000-0000-000000000001'
PERSON_MARIA='50000000-0000-0000-0000-000000000002'
PERSON_LISA='50000000-0000-0000-0000-000000000006'
PT_JUAN='30000000-0000-0000-0000-000000000001'          # Juan's chart at D-Touch
PT_JUAN_OPTO='30000000-0000-0000-0000-000000000007'     # …and at ClearVision
PT_MARIA='30000000-0000-0000-0000-000000000002'         # Maria's chart at D-Touch
PT_MARIA_BRIGHT='30000000-0000-0000-0000-00000000000d'  # …and at BrightSmile
PT_LISA='30000000-0000-0000-0000-000000000006'          # Little Stars only
A2='40000000-0000-0000-0000-000000000002'
A4='40000000-0000-0000-0000-000000000004'
A_BRIGHT='40000000-0000-0000-0000-000000000013'
WALKIN='5eeeeeee-0000-0000-0000-000000000001'

print "\n── Seed integrity ─────────────────────────────────────────────"
expect_eq "4 clinics"       "select count(*) from public.clinics;" 4
expect_eq "…two of them dental, as separate tenants" \
  "select count(*) from public.clinics where type='dental';" 2
expect_eq "10 doctors"      "select count(*) from public.doctors;" 10
expect_eq "6 persons"       "select count(*) from public.persons;" 6
expect_eq "13 charts"       "select count(*) from public.patients;" 13
expect_eq "19 appointments" "select count(*) from public.appointments;" 19
expect_eq "26 services"     "select count(*) from public.services;" 26
expect_eq "every appt resolved to a real service row" \
  "select count(*) from public.appointments where service_id is null;" 0
expect_eq "appointments today (Manila)" \
  "select count(*) from public.appointments
   where (scheduled_at at time zone 'Asia/Manila')::date
       = (now() at time zone 'Asia/Manila')::date;" 8
# Compare DATES in Manila, never `scheduled_at > now()`: eight of the seeded
# appointments are today at 08:00–15:00, so a wall-clock comparison flips
# depending on what time of day the suite runs.
expect_eq "future-dated appointments" \
  "select count(*) from public.appointments
   where (scheduled_at at time zone 'Asia/Manila')::date
       > (now() at time zone 'Asia/Manila')::date;" 7
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
expect_eq "every appointment's chart is in its clinic" \
  "select count(*) from public.appointments a join public.patients p on p.id=a.patient_id
   where p.clinic_id <> a.clinic_id;" 0
expect_eq "Juan holds one chart per clinic he has visited" \
  "select count(*) from public.patients where person_id='$PERSON_JUAN';" 3

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
   values ('$OPTO','$PT_JUAN_OPTO','$DR_SANTOS','Eye Examination', now()+interval '40 days');"
expect_err "service from another clinic is rejected" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS',
           (select s.id from public.services s
              join public.clinics c on c.id = s.clinic_id
             where c.type='optometry' and s.name='Retinal Exam'),
           'Retinal Exam', now()+interval '41 days');"
expect_err "a chart from another clinic is rejected" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_LISA','$DR_SANTOS','Teeth Cleaning', now()+interval '42 days');"
expect_err "a person holds at most one chart per clinic" \
  "insert into public.patients (person_id,clinic_id) values ('$PERSON_JUAN','$DENTAL');"
expect_err "a signed-in caller cannot move a chart to another clinic" \
  "set request.jwt.claim.sub = '$ASST_AUTH';
   update public.patients set clinic_id='$BRIGHT' where id='$PT_MARIA';"
expect_err "invalid weekday (8) is rejected" \
  "insert into public.doctors (clinic_id,full_name,specialty,available_weekdays)
   values ('$DENTAL','Test Doc','Testing','{1,8}');"
expect_err "zero-length service duration is rejected" \
  "insert into public.services (clinic_id,name,duration_minutes) values ('$DENTAL','Bogus',0);"
expect_ok "a new vertical is rows, not a migration" \
  "begin;
   insert into public.clinic_types (slug,display_name,icon_name) values ('derma','Dermatology','face');
   insert into public.clinics (type,name,slug) values ('derma','Test Derma Clinic','test-derma');
   rollback;"
expect_err "a clinic of an unknown type is rejected" \
  "insert into public.clinics (type,name,slug) values ('astrology','Stars','stars');"
expect_err "a clinic slug must be URL-safe" \
  "insert into public.clinics (type,name,slug) values ('dental','Bad Slug','Bad Slug!');"
expect_dml "a new clinic gets a well-formed join code generated" "" \
  "insert into public.clinics (type,name,slug) values ('dental','Code Test','code-test')
   returning join_code" 1

print "\n── Auth bridge ────────────────────────────────────────────────"
expect_ok "create six auth users" \
  "insert into auth.users (id,email,raw_user_meta_data) values
     ('$JUAN_AUTH','juan@email.com','{\"full_name\":\"Juan dela Cruz\",\"role\":\"admin\"}'),
     ('$DOC_AUTH','santos@clinic.ph','{\"full_name\":\"Maria Santos\"}'),
     ('$ASST_AUTH','front@clinic.ph','{}'),
     ('$DT_ADMIN_AUTH','admin@dtouch.ph','{\"full_name\":\"D-Touch Admin\"}'),
     ('$BRIGHT_ADMIN_AUTH','admin@brightsmile.ph','{\"full_name\":\"BrightSmile Admin\"}'),
     ('$NEWBIE_AUTH','newbie@mail.com','{\"full_name\":\"New Patient\"}');"
expect_eq "profiles auto-created by trigger" "select count(*) from public.profiles;" 6
expect_eq "a client-supplied 'admin' role in metadata granted NOTHING" \
  "select count(*) from public.clinic_memberships where profile_id='$JUAN_AUTH';" 0
expect_eq "full_name carried over from metadata" \
  "select full_name from public.profiles where id='$DOC_AUTH';" "Maria Santos"
expect_eq "empty metadata falls back to the email local-part" \
  "select full_name from public.profiles where id='$ASST_AUTH';" "front"
expect_ok "link Juan's account to his person record (service role)" \
  "update public.persons set profile_id='$JUAN_AUTH' where id='$PERSON_JUAN';"
expect_ok "Dr Santos: doctor at D-Touch, linked to the roster row" \
  "insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$DOC_AUTH','$DENTAL','doctor');
   update public.doctors set profile_id='$DOC_AUTH' where id='$DR_SANTOS';"
expect_ok "front desk: assistant at D-Touch" \
  "insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$ASST_AUTH','$DENTAL','assistant');"
expect_ok "D-Touch admin" \
  "insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$DT_ADMIN_AUTH','$DENTAL','admin');"
expect_ok "BrightSmile admin" \
  "insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$BRIGHT_ADMIN_AUTH','$BRIGHT','admin');"
expect_err "a membership cannot carry the patient role" \
  "insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$NEWBIE_AUTH','$DENTAL','patient');"
expect_ok "one account may sit on the rosters of two clinics" \
  "begin;
   insert into public.doctors (clinic_id,profile_id,full_name,specialty)
   values ('$BRIGHT','$DOC_AUTH','Maria Santos','General Dentistry');
   rollback;"

# `set` (not `select set_config`) keeps scalar output clean.
juan="set role authenticated;    set request.jwt.claim.sub = '$JUAN_AUTH';"
doc="set role authenticated;     set request.jwt.claim.sub = '$DOC_AUTH';"
asst="set role authenticated;    set request.jwt.claim.sub = '$ASST_AUTH';"
dtadmin="set role authenticated; set request.jwt.claim.sub = '$DT_ADMIN_AUTH';"
bright="set role authenticated;  set request.jwt.claim.sub = '$BRIGHT_ADMIN_AUTH';"
newbie="set role authenticated;  set request.jwt.claim.sub = '$NEWBIE_AUTH';"
anon="set role anon;"

print "\n── RLS · patient (Juan) ───────────────────────────────────────"
expect_eq "sees only his own 6 appointments"    "$juan select count(*) from public.appointments;" 6
expect_eq "…spanning the three clinics he has charts at" \
  "$juan select count(distinct clinic_id) from public.appointments;" 3
expect_eq "sees his own 3 charts"               "$juan select count(*) from public.patients;" 3
expect_eq "sees only his own person record"     "$juan select count(*) from public.persons;" 1
expect_eq "sees only the 3 clinics he belongs to" "$juan select count(*) from public.clinics;" 3
expect_eq "sees the rosters of those clinics only"  "$juan select count(*) from public.doctors;" 9
expect_eq "sees the services of those clinics only" "$juan select count(*) from public.services;" 23
expect_eq "cannot see BrightSmile, where he has never been" \
  "$juan select count(*) from public.clinics where id='$BRIGHT';" 0
expect_eq "cannot see other people's charts" \
  "$juan select count(*) from public.patients where person_id<>'$PERSON_JUAN';" 0
expect_eq "cannot see other patients' profiles" "$juan select count(*) from public.profiles;" 1
expect_dml "CAN cancel his own appointment" "$juan" \
  "update public.appointments set status='cancelled' where id='$A4' returning id" 1
expect_err "cannot CONFIRM his own appointment" \
  "$juan update public.appointments set status='confirmed' where id='$A4';"
expect_err "cannot grant himself a staff membership" \
  "$juan insert into public.clinic_memberships (profile_id,clinic_id,role)
   values ('$JUAN_AUTH','$DENTAL','admin');"
expect_dml "CAN update his own phone" "$juan" \
  "update public.persons set phone='09990000000' where id='$PERSON_JUAN' returning id" 1
expect_err "cannot re-point his person record at another account" \
  "$juan update public.persons set profile_id='$NEWBIE_AUTH' where id='$PERSON_JUAN';"
expect_dml "cannot write clinical notes on his own chart" "$juan" \
  "update public.patients set medical_notes='self-diagnosed' where id='$PT_JUAN' returning id" 0
expect_dml "cannot touch another patient's chart" "$juan" \
  "update public.patients set medical_notes='x' where id='$PT_MARIA' returning id" 0
expect_dml "cannot touch another person's details" "$juan" \
  "update public.persons set phone='x' where id='$PERSON_MARIA' returning id" 0
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
expect_err "cannot book at D-Touch on his ClearVision chart" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN_OPTO','$DR_SANTOS','Root Canal',now()+interval '63 days','pending');"
expect_err "cannot open himself a chart at a clinic (only join_clinic can)" \
  "$juan insert into public.patients (person_id,clinic_id) values ('$PERSON_JUAN','$BRIGHT');"
expect_dml "cannot delete his own appointment" "$juan" \
  "delete from public.appointments where id='$A4' returning id" 0
expect_dml "cannot edit a doctor's availability" "$juan" \
  "update public.doctors set available_weekdays='{1}' where id='$DR_SANTOS' returning id" 0
expect_dml "cannot edit a service" "$juan" \
  "update public.services set duration_minutes=999
   where clinic_id='$DENTAL' and name='Root Canal' returning id" 0

print "\n── RLS · doctor (Dr Santos, D-Touch) ──────────────────────────"
expect_eq "sees D-Touch's 7 appointments"   "$doc select count(*) from public.appointments;" 7
expect_eq "…and nothing outside D-Touch"    "$doc select count(distinct clinic_id) from public.appointments;" 1
expect_eq "sees the 4 charts held at D-Touch" "$doc select count(*) from public.patients;" 4
expect_eq "…and those 4 people's details" "$doc select count(*) from public.persons;" 4
expect_eq "reads D-Touch's notes on Maria" \
  "$doc select medical_notes from public.patients where id='$PT_MARIA';" "Allergic to latex."
expect_eq "cannot see Maria's BrightSmile chart" \
  "$doc select count(*) from public.patients where id='$PT_MARIA_BRIGHT';" 0
expect_eq "cannot see BrightSmile's roster" \
  "$doc select count(*) from public.doctors where clinic_id='$BRIGHT';" 0
expect_eq "cannot see BrightSmile's services" \
  "$doc select count(*) from public.services where clinic_id='$BRIGHT';" 0
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
expect_err "cannot register a walk-in (assistants and admins only)" \
  "$doc select public.book_walk_in('$DENTAL','Doc Walk-in','09171119999',
     '$DR_SANTOS','Teeth Cleaning', now() + interval '95 days');"

print "\n── RLS · assistant (front desk, D-Touch) ──────────────────────"
expect_eq "sees D-Touch's 7 appointments" "$asst select count(*) from public.appointments;" 7
expect_eq "sees D-Touch's 4 charts"       "$asst select count(*) from public.patients;" 4
# The walk-in flow by hand: person first (no RETURNING), then the chart.
expect_dml "CAN register a walk-in (person + chart) and read the chart back" \
  "$asst insert into public.persons (id,full_name,phone) values ('$WALKIN','Walk-in Test','09171110000');" \
  "insert into public.patients (person_id,clinic_id) values ('$WALKIN','$DENTAL') returning id" 1
expect_dml "…and read the person back once the chart exists" \
  "$asst insert into public.persons (id,full_name,phone) values ('$WALKIN','Walk-in Test','09171110000');
   insert into public.patients (person_id,clinic_id) values ('$WALKIN','$DENTAL');" \
  "select id from public.persons where id='$WALKIN'" 1
# Why book_walk_in generates ids instead of using RETURNING.
expect_err "cannot read back a person who holds no chart yet" \
  "$asst insert into public.persons (full_name,phone) values ('No Chart Yet','09171110004') returning id;"
expect_err "cannot register a chart at a clinic they do not staff" \
  "begin;
   $asst
   insert into public.persons (id,full_name,phone) values ('$WALKIN','Wrong Clinic','09171110002');
   insert into public.patients (person_id,clinic_id) values ('$WALKIN','$OPTO');
   rollback;"
expect_err "cannot attach a chart to someone who belongs to other clinics" \
  "$asst insert into public.patients (person_id,clinic_id) values ('$PERSON_LISA','$DENTAL');"
expect_err "cannot bind a new person to someone's account" \
  "$asst insert into public.persons (profile_id,full_name) values ('$NEWBIE_AUTH','Hijack');"
expect_dml "CAN book a walk-in appointment" "$asst" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Teeth Cleaning',now()+interval '70 days','confirmed') returning id" 1
expect_dml "cannot delete an appointment (admin only)" "$asst" \
  "delete from public.appointments where id='$A2' returning id" 0

print "\n── book_walk_in (atomicity) ───────────────────────────────────"
expect_dml "books person + chart + appointment in one call" "$asst" \
  "select public.book_walk_in(
     '$DENTAL', 'Atomic One', '09171112221',
     '$DR_SANTOS', 'Teeth Cleaning', now() + interval '90 days') as id" 1
# The point of the function: a losing race must leave no orphan behind.
expect_err "double-booked slot is rejected" \
  "begin;
   $asst
   select public.book_walk_in(
     '$DENTAL', 'Atomic Two', '09171112222', '$DR_SANTOS', 'Teeth Cleaning',
     (select scheduled_at from public.appointments where id = '$A2'));
   rollback;"
expect_eq "…and rolled the person back with it" \
  "select count(*) from public.persons where full_name = 'Atomic Two';" 0
expect_err "blank name is rejected before any write" \
  "$asst select public.book_walk_in('$DENTAL','   ','09171112223',
     '$DR_SANTOS','Teeth Cleaning', now() + interval '91 days');"
expect_eq "…leaving no partial row" \
  "select count(*) from public.persons where phone = '09171112223';" 0
# SECURITY INVOKER means the caller's own RLS still applies inside the body.
expect_err "assistant cannot book into a clinic they do not staff" \
  "$asst select public.book_walk_in('$OPTO','Wrong Clinic','09171112224',
     '$DR_BAUTISTA','Eye Examination', now() + interval '92 days');"
expect_eq "…and created no person there either" \
  "select count(*) from public.persons where full_name = 'Wrong Clinic';" 0
expect_err "a patient cannot call it at all" \
  "$juan select public.book_walk_in('$DENTAL','Sneaky','09171112225',
     '$DR_SANTOS','Teeth Cleaning', now() + interval '93 days');"

print "\n── RLS · admin (D-Touch) ──────────────────────────────────────"
expect_dml "CAN delete a D-Touch appointment" "$dtadmin" \
  "delete from public.appointments where id='$A2' returning id" 1
expect_dml "cannot delete one at BrightSmile" "$dtadmin" \
  "delete from public.appointments where id='$A_BRIGHT' returning id" 0
expect_dml "cannot edit BrightSmile's catalogue" "$dtadmin" \
  "update public.services set duration_minutes=999 where clinic_id='$BRIGHT' returning id" 0

print "\n── RLS · two dental tenants (D-Touch vs BrightSmile) ──────────"
expect_eq "BrightSmile's admin sees only their own clinic" "$bright select count(*) from public.clinics;" 1
expect_eq "…their own 1 appointment" "$bright select count(*) from public.appointments;" 1
expect_eq "…their own 1 doctor"      "$bright select count(*) from public.doctors;" 1
expect_eq "…their own 3 services"    "$bright select count(*) from public.services;" 3
expect_eq "…and only Maria's BrightSmile chart" "$bright select count(*) from public.patients;" 1
expect_eq "reads BrightSmile's notes on Maria" \
  "$bright select medical_notes from public.patients where id='$PT_MARIA_BRIGHT';" \
  "Considering implants; wants a second opinion."
expect_eq "cannot read D-Touch's chart on the same person" \
  "$bright select count(*) from public.patients where id='$PT_MARIA';" 0
expect_eq "does see Maria's shared identity row (by design)" \
  "$bright select count(*) from public.persons where id='$PERSON_MARIA';" 1
expect_eq "D-Touch's front desk cannot see BrightSmile's appointment" \
  "$asst select count(*) from public.appointments where clinic_id='$BRIGHT';" 0
expect_eq "D-Touch staff cannot see the Little Stars-only patient Lisa" \
  "$asst select count(*) from public.persons where id='$PERSON_LISA';" 0
expect_eq "ClearVision appointments are invisible to D-Touch staff" \
  "$asst select count(*) from public.appointments where clinic_id='$OPTO';" 0
# The escalation the per-clinic role closes: an admin grant from one tenant
# must not carry over to another tenant the same account belongs to.
expect_dml "an admin role granted by BrightSmile gives nothing at D-Touch" \
  "$bright do \$\$ begin perform public.invite_staff('$BRIGHT','front@clinic.ph','admin'); end \$\$;
   set request.jwt.claim.sub = '$ASST_AUTH';" \
  "delete from public.appointments where id='$A2' returning id" 0
expect_dml "…while it does apply at BrightSmile" \
  "$bright do \$\$ begin perform public.invite_staff('$BRIGHT','front@clinic.ph','admin'); end \$\$;
   set request.jwt.claim.sub = '$ASST_AUTH';" \
  "delete from public.appointments where id='$A_BRIGHT' returning id" 1

print "\n── Onboarding · join_clinic ───────────────────────────────────"
expect_eq "a fresh signup sees no clinics" "$newbie select count(*) from public.clinics;" 0
expect_eq "…no doctors"                    "$newbie select count(*) from public.doctors;" 0
expect_eq "…no services"                   "$newbie select count(*) from public.services;" 0
expect_eq "…and no charts"                 "$newbie select count(*) from public.patients;" 0
expect_err "a wrong code is rejected" "$newbie select public.join_clinic('NOPE2345');"
expect_err "an inactive clinic cannot be joined" \
  "begin;
   update public.clinics set is_active=false where id='$BRIGHT';
   $newbie
   select public.join_clinic('BRIGHT26');
   rollback;"
expect_err "a clinic with self-service joins switched off cannot be joined" \
  "begin;
   update public.clinics set join_code=null where id='$BRIGHT';
   $newbie
   select public.join_clinic('BRIGHT26');
   rollback;"
expect_eq "joining with a code attaches them, normalising case and spaces" \
  "$newbie select public.join_clinic('  dtouch26 ');" "$DENTAL"
expect_eq "…creating their person and exactly one chart" \
  "select count(*) from public.patients pt join public.persons pe on pe.id=pt.person_id
   where pe.profile_id='$NEWBIE_AUTH';" 1
expect_eq "re-joining is idempotent" "$newbie select public.join_clinic('DTOUCH26');" "$DENTAL"
expect_eq "…still one chart" \
  "select count(*) from public.patients pt join public.persons pe on pe.id=pt.person_id
   where pe.profile_id='$NEWBIE_AUTH';" 1
expect_eq "now sees D-Touch and nothing else" "$newbie select count(*) from public.clinics;" 1
expect_eq "…and its roster"                   "$newbie select count(*) from public.doctors;" 3
expect_eq "…but none of its other patients"   "$newbie select count(*) from public.persons;" 1
expect_dml "CAN book there, as pending" "$newbie" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   select '$DENTAL', pt.id, '$DR_SANTOS', 'Teeth Cleaning', now()+interval '100 days'
   from public.patients pt returning id" 1

print "\n── Onboarding · invite_staff / remove_staff ───────────────────"
expect_err "an assistant cannot invite staff" \
  "$asst select public.invite_staff('$DENTAL','newbie@mail.com','assistant');"
expect_err "a patient cannot invite staff" \
  "$juan select public.invite_staff('$DENTAL','newbie@mail.com','assistant');"
expect_err "BrightSmile's admin cannot invite into D-Touch" \
  "$bright select public.invite_staff('$DENTAL','newbie@mail.com','admin');"
expect_dml "D-Touch's admin CAN invite an existing account" "$dtadmin" \
  "select public.invite_staff('$DENTAL','NewBie@Mail.com','assistant') as id" 1
expect_dml "…which gives them D-Touch's appointments and nothing more" \
  "$dtadmin do \$\$ begin perform public.invite_staff('$DENTAL','newbie@mail.com','assistant'); end \$\$;
   set request.jwt.claim.sub = '$NEWBIE_AUTH';" \
  "select id from public.appointments" 7
expect_err "the patient role cannot be granted" \
  "$dtadmin select public.invite_staff('$DENTAL','newbie@mail.com','patient');"
expect_err "an email with no account is rejected" \
  "$dtadmin select public.invite_staff('$DENTAL','nobody@nowhere.ph','assistant');"
expect_err "the last admin cannot demote themselves" \
  "$dtadmin select public.invite_staff('$DENTAL','admin@dtouch.ph','assistant');"
expect_err "the last admin cannot remove themselves" \
  "$dtadmin select public.remove_staff('$DENTAL','$DT_ADMIN_AUTH');"
expect_err "an assistant cannot remove staff" \
  "$asst select public.remove_staff('$DENTAL','$DOC_AUTH');"
expect_dml "an admin CAN remove a doctor, which unlinks their roster row" \
  "$dtadmin do \$\$ begin perform public.remove_staff('$DENTAL','$DOC_AUTH'); end \$\$;" \
  "select id from public.doctors where profile_id='$DOC_AUTH'" 0

print "\n── Clinic self-service (admin) ────────────────────────────────"
expect_dml "an admin CAN rename their clinic" "$dtadmin" \
  "update public.clinics set name='D-Touch Dental' where id='$DENTAL' returning id" 1
expect_dml "…and set its brand colour and logo" "$dtadmin" \
  "update public.clinics set seed_color='#123456', logo_url='https://example.com/logo.png'
   where id='$DENTAL' returning id" 1
expect_dml "…but not another clinic's" "$dtadmin" \
  "update public.clinics set name='Hijacked' where id='$BRIGHT' returning id" 0
expect_dml "an assistant cannot edit the clinic" "$asst" \
  "update public.clinics set name='Front Desk Clinic' where id='$DENTAL' returning id" 0
expect_err "an admin cannot suspend or reactivate their clinic (operator-only)" \
  "$dtadmin update public.clinics set is_active=false where id='$DENTAL';"
expect_err "an admin cannot change their clinic's type" \
  "$dtadmin update public.clinics set type='optometry' where id='$DENTAL';"
expect_err "an admin cannot change their clinic's slug" \
  "$dtadmin update public.clinics set slug='renamed' where id='$DENTAL';"
expect_dml "an admin CAN switch off self-service joins" "$dtadmin" \
  "update public.clinics set join_code=null where id='$DENTAL' returning id" 1
expect_dml "an admin CAN rotate the join code" "$dtadmin" \
  "select public.rotate_join_code('$DENTAL') as code" 1
expect_err "…after which the old code no longer works" \
  "begin;
   $dtadmin
   do \$\$ begin perform public.rotate_join_code('$DENTAL'); end \$\$;
   set request.jwt.claim.sub = '$BRIGHT_ADMIN_AUTH';
   select public.join_clinic('DTOUCH26');
   rollback;"
expect_err "an assistant cannot rotate the join code" \
  "$asst select public.rotate_join_code('$DENTAL');"
expect_err "BrightSmile's admin cannot rotate D-Touch's code" \
  "$bright select public.rotate_join_code('$DENTAL');"

print "\n── RLS · anonymous ────────────────────────────────────────────"
expect_eq "anon sees no appointments" "$anon select count(*) from public.appointments;" 0
expect_eq "anon sees no clinics"      "$anon select count(*) from public.clinics;" 0
expect_eq "anon sees no doctors"      "$anon select count(*) from public.doctors;" 0
expect_eq "anon sees no persons"      "$anon select count(*) from public.persons;" 0
expect_eq "anon sees no patients"     "$anon select count(*) from public.patients;" 0
expect_err "anon cannot insert an appointment" \
  "$anon insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal',now()+interval '80 days');"
expect_err "anon cannot call join_clinic" "$anon select public.join_clinic('DTOUCH26');"
expect_err "anon cannot call invite_staff" \
  "$anon select public.invite_staff('$DENTAL','newbie@mail.com','admin');"

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
