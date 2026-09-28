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

# expect_err_msg <label> <sql> <substring>  — must raise, with that message.
# For rejections where WHICH rule refused matters: a booking guard firing
# first would otherwise make an RLS check pass for the wrong reason.
expect_err_msg() { local out
  if out=$(psql $CONN -c "$2" 2>&1); then
    print "FAIL  $1 (expected rejection, but it succeeded)"; ((fail++))
  else local first=${out%%$'\n'*}
    if [[ "$first" == *"$3"* ]]; then print "PASS  $1  [$first]"; ((pass++))
    else print "FAIL  $1  expected an error containing '$3', got '$first'"; ((fail++)); fi
  fi }

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
A6='40000000-0000-0000-0000-000000000006'   # Juan, completed, carries a note to him
A7='40000000-0000-0000-0000-000000000007'   # Maria, completed, has a visit note
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
expect_eq "2 medical notes" "select count(*) from public.chart_notes;" 2
expect_eq "4 visit notes"   "select count(*) from public.visit_notes;" 4
expect_eq "no clinical text left on rows the front desk and patients read" \
  "select count(*) from information_schema.columns
   where table_schema='public'
     and ((table_name='patients' and column_name='medical_notes')
       or (table_name='appointments' and column_name='notes'));" 0

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

# A time a patient may actually book with Dr Santos: patients are held to
# public.available_slots. Asked as Juan, a D-Touch patient. Bookings below
# roll back, so one slot serves them all.
SLOT=$(trim "$(psql $CONN -c "$juan select s from generate_series(current_date + 60, current_date + 75, interval '1 day') d,
  lateral public.available_slots('$DR_SANTOS', d::date) s order by s limit 1;")")

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
expect_eq "cannot read the medical note on his own chart" \
  "$juan select count(*) from public.chart_notes;" 0
expect_eq "cannot read the consultation notes on his own visits" \
  "$juan select count(*) from public.visit_notes;" 0
expect_eq "CAN read the note his doctor left for him" \
  "$juan select patient_note from public.appointments where id='$A6';" \
  "Brush twice daily and floss. See you in 6 months."
expect_err "cannot write a medical note on his own chart" \
  "$juan insert into public.chart_notes (patient_id,clinic_id,body) values ('$PT_JUAN','$DENTAL','self-diagnosed');"
expect_dml "cannot touch another patient's medical note" "$juan" \
  "update public.chart_notes set body='x' where patient_id='$PT_MARIA' returning patient_id" 0
# Cancelling passes his RLS, so only the guard trigger stands in the way here.
expect_err "cannot write himself a note from the doctor" \
  "$juan update public.appointments set status='cancelled', patient_note='no charge' where id='$A4';"
expect_err_msg "…nor book with one attached" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status,patient_note)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal','$SLOT','pending','VIP');" "note to the patient"
expect_dml "cannot touch another person's details" "$juan" \
  "update public.persons set phone='x' where id='$PERSON_MARIA' returning id" 0
expect_dml "cannot cancel someone else's appointment" "$juan" \
  "update public.appointments set status='cancelled' where id='$A2' returning id" 0
expect_dml "CAN book a pending appointment for himself" "$juan" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal','$SLOT','pending') returning id" 1
expect_err_msg "cannot book a pre-CONFIRMED appointment" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal','$SLOT','confirmed');" "row-level security"
expect_err_msg "cannot book on behalf of another patient" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Root Canal','$SLOT','pending');" "row-level security"
expect_err_msg "cannot book at D-Touch on his ClearVision chart" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN_OPTO','$DR_SANTOS','Root Canal','$SLOT','pending');" "patient_matches_clinic"
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
expect_eq "reads D-Touch's medical note on Maria" \
  "$doc select body from public.chart_notes where patient_id='$PT_MARIA';" "Allergic to latex."
expect_eq "reads D-Touch's 2 visit notes and no others" \
  "$doc select count(*) from public.visit_notes;" 2
expect_eq "cannot read BrightSmile's medical note on the same person" \
  "$doc select count(*) from public.chart_notes where patient_id='$PT_MARIA_BRIGHT';" 0
expect_eq "cannot see Maria's BrightSmile chart" \
  "$doc select count(*) from public.patients where id='$PT_MARIA_BRIGHT';" 0
expect_eq "cannot see BrightSmile's roster" \
  "$doc select count(*) from public.doctors where clinic_id='$BRIGHT';" 0
expect_eq "cannot see BrightSmile's services" \
  "$doc select count(*) from public.services where clinic_id='$BRIGHT';" 0
expect_dml "CAN confirm a pending appointment" "$doc" \
  "update public.appointments set status='confirmed' where id='$A2' returning id" 1
expect_dml "CAN write consultation notes" "$doc" \
  "insert into public.visit_notes (appointment_id,clinic_id,body)
   values ('$A2','$DENTAL','Reviewed x-ray.') returning appointment_id" 1
expect_dml "CAN revise one (upsert)" "$doc" \
  "insert into public.visit_notes (appointment_id,clinic_id,body) values ('$A7','$DENTAL','Revised.')
   on conflict (appointment_id) do update set body=excluded.body returning appointment_id" 1
expect_dml "…and the write is stamped with its author, not a client value" \
  "$doc insert into public.visit_notes (appointment_id,clinic_id,body,updated_by)
   values ('$A2','$DENTAL','x','$ASST_AUTH');" \
  "select 1 from public.visit_notes where appointment_id='$A2' and updated_by='$DOC_AUTH'" 1
expect_dml "CAN keep a patient's medical note" "$doc" \
  "insert into public.chart_notes (patient_id,clinic_id,body)
   values ('$PT_JUAN','$DENTAL','Sensitive gums.') returning patient_id" 1
expect_dml "CAN leave the patient a note" "$doc" \
  "update public.appointments set patient_note='Avoid hot drinks for 24h.' where id='$A2' returning id" 1
expect_err "cannot file a note on another clinic's appointment" \
  "$doc insert into public.visit_notes (appointment_id,clinic_id,body) values ('$A_BRIGHT','$BRIGHT','x');"
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
expect_eq "cannot read the medical notes on those charts" \
  "$asst select count(*) from public.chart_notes;" 0
expect_eq "cannot read consultation notes" "$asst select count(*) from public.visit_notes;" 0
expect_err "cannot write a consultation note" \
  "$asst insert into public.visit_notes (appointment_id,clinic_id,body) values ('$A2','$DENTAL','x');"
expect_dml "cannot overwrite a medical note" "$asst" \
  "update public.chart_notes set body='x' where patient_id='$PT_MARIA' returning patient_id" 0
expect_err "cannot write the patient a note from the doctor" \
  "$asst update public.appointments set patient_note='x' where id='$A2';"
# The guard fires on a CHANGE to the note, not on its presence.
expect_dml "CAN still update a visit that carries a doctor's note" "$asst" \
  "update public.appointments set service_name=service_name where id='$A6' returning id" 1
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
expect_eq "reads D-Touch's visit notes" "$dtadmin select count(*) from public.visit_notes;" 2
expect_dml "…and CAN write a medical note" "$dtadmin" \
  "insert into public.chart_notes (patient_id,clinic_id,body)
   values ('$PT_JUAN','$DENTAL','Anxious patient.') returning patient_id" 1

print "\n── RLS · two dental tenants (D-Touch vs BrightSmile) ──────────"
expect_eq "BrightSmile's admin sees only their own clinic" "$bright select count(*) from public.clinics;" 1
expect_eq "…their own 1 appointment" "$bright select count(*) from public.appointments;" 1
expect_eq "…their own 1 doctor"      "$bright select count(*) from public.doctors;" 1
expect_eq "…their own 3 services"    "$bright select count(*) from public.services;" 3
expect_eq "…and only Maria's BrightSmile chart" "$bright select count(*) from public.patients;" 1
expect_eq "reads BrightSmile's medical note on Maria" \
  "$bright select body from public.chart_notes where patient_id='$PT_MARIA_BRIGHT';" \
  "Considering implants; wants a second opinion."
expect_eq "cannot read D-Touch's chart on the same person" \
  "$bright select count(*) from public.patients where id='$PT_MARIA';" 0
expect_eq "…nor D-Touch's medical note on her" \
  "$bright select count(*) from public.chart_notes where patient_id='$PT_MARIA';" 0
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
   select '$DENTAL', pt.id, '$DR_SANTOS', 'Teeth Cleaning', '$SLOT'
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
expect_dml "…and ends their access to D-Touch's clinical notes" \
  "$dtadmin do \$\$ begin perform public.remove_staff('$DENTAL','$DOC_AUTH'); end \$\$;
   set request.jwt.claim.sub = '$DOC_AUTH';" \
  "select appointment_id from public.visit_notes" 0

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

print "\n── Branch admins ──────────────────────────────────────────────"
# From here on the checks commit, like the join_clinic ones above: an applicant
# only gets as far as approval by going through each step for real.
BRANCH_AUTH='aaaaaaaa-0000-0000-0000-000000000007'
APPLICANT_AUTH='aaaaaaaa-0000-0000-0000-000000000008'
APPLICANT2_AUTH='aaaaaaaa-0000-0000-0000-000000000009'
expect_ok "create a branch admin and two applicants" \
  "insert into auth.users (id,email,raw_user_meta_data) values
     ('$BRANCH_AUTH','branch@dtouch.ph','{\"full_name\":\"Branch Admin\"}'),
     ('$APPLICANT_AUTH','reyes@mail.com','{\"full_name\":\"Ana Reyes\"}'),
     ('$APPLICANT2_AUTH','nurse@mail.com','{\"full_name\":\"Nora Cruz\"}');"
branch="set role authenticated;    set request.jwt.claim.sub = '$BRANCH_AUTH';"
applicant="set role authenticated; set request.jwt.claim.sub = '$APPLICANT_AUTH';"
applicant2="set role authenticated; set request.jwt.claim.sub = '$APPLICANT2_AUTH';"

expect_eq "a full admin CAN appoint a branch admin" \
  "$dtadmin select public.invite_staff('$DENTAL','branch@dtouch.ph','admin',true);" "$BRANCH_AUTH"
expect_eq "…whose membership is locked to the branch" \
  "select branch_locked from public.clinic_memberships where profile_id='$BRANCH_AUTH';" "t"
expect_err "only admins can carry the branch lock" \
  "update public.clinic_memberships set branch_locked=true where profile_id='$ASST_AUTH';"
expect_eq "a branch admin sees their branch's appointments" \
  "$branch select count(*) from public.appointments;" 7
expect_eq "…reads its clinical notes like any admin" \
  "$branch select count(*) from public.visit_notes;" 2
expect_eq "…and sees no other clinic" "$branch select count(*) from public.clinics;" 1
expect_dml "a branch admin CAN edit their branch's details" "$branch" \
  "update public.clinics set contact_phone='0917 000 0000' where id='$DENTAL' returning id" 1
expect_err "a branch admin cannot make anyone an admin" \
  "$branch select public.invite_staff('$DENTAL','front@clinic.ph','admin');"
expect_err "…nor another branch admin" \
  "$branch select public.invite_staff('$DENTAL','front@clinic.ph','admin',true);"
expect_err "…nor demote the full admin" \
  "$branch select public.invite_staff('$DENTAL','admin@dtouch.ph','assistant');"
expect_err "…nor remove them" \
  "$branch select public.remove_staff('$DENTAL','$DT_ADMIN_AUTH');"
expect_dml "a branch admin CAN change a doctor to an assistant" "$branch" \
  "select public.invite_staff('$DENTAL','santos@clinic.ph','assistant') as id" 1
expect_err "the last FULL admin cannot lock themselves to the branch" \
  "$dtadmin select public.invite_staff('$DENTAL','admin@dtouch.ph','admin',true);"
expect_err "another tenant cannot make the branch admin their admin too" \
  "$bright select public.invite_staff('$BRIGHT','branch@dtouch.ph','admin');"
expect_err "…nor can the service role, since the lock is on the table" \
  "insert into public.clinic_memberships (profile_id,clinic_id,role)
   values ('$BRANCH_AUTH','$OPTO','admin');"
expect_ok "…though they may still be a doctor elsewhere" \
  "begin;
   insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$BRANCH_AUTH','$OPTO','doctor');
   rollback;"
expect_err "an admin elsewhere cannot be branch-locked here" \
  "begin;
   insert into public.clinic_memberships (profile_id,clinic_id,role) values ('$BRIGHT_ADMIN_AUTH','$DENTAL','admin');
   update public.clinic_memberships set branch_locked=true
    where profile_id='$BRIGHT_ADMIN_AUTH' and clinic_id='$DENTAL';
   rollback;"

print "\n── Staff codes · issue ────────────────────────────────────────"
code_re='^[A-Z2-9]{8}$'
expect_err "an assistant cannot issue a staff code" \
  "$asst select public.create_staff_invite('$DENTAL','assistant');"
expect_err "a doctor cannot issue a staff code" \
  "$doc select public.create_staff_invite('$DENTAL','doctor');"
expect_err "BrightSmile's admin cannot issue a D-Touch code" \
  "$bright select public.create_staff_invite('$DENTAL','doctor');"
expect_err "staff codes cannot grant admin" \
  "$dtadmin select public.create_staff_invite('$DENTAL','admin');"
expect_err "…nor patient" \
  "$dtadmin select public.create_staff_invite('$DENTAL','patient');"
expect_err "validity is capped at 30 days" \
  "$dtadmin select public.create_staff_invite('$DENTAL','doctor',null,31);"
DOC_CODE=$(trim "$(psql $CONN -c "$branch select code from public.create_staff_invite('$DENTAL','doctor','Dr Reyes');")")
ASST_CODE=$(trim "$(psql $CONN -c "$dtadmin select code from public.create_staff_invite('$DENTAL','assistant');")")
expect_eq "a branch admin CAN issue a doctor code" \
  "select '$DOC_CODE' ~ '$code_re';" "t"
expect_eq "a full admin CAN issue an assistant code" \
  "select '$ASST_CODE' ~ '$code_re' and '$ASST_CODE' <> '$DOC_CODE';" "t"
expect_eq "D-Touch's admins see both open codes" \
  "$dtadmin select count(*) from public.staff_invites where status='open';" 2
expect_eq "…the branch admin too" \
  "$branch select count(*) from public.staff_invites;" 2
expect_eq "the front desk sees none" "$asst select count(*) from public.staff_invites;" 0
expect_eq "another tenant's admin sees none" "$bright select count(*) from public.staff_invites;" 0
expect_err "nobody writes invites directly" \
  "$dtadmin insert into public.staff_invites (clinic_id,role) values ('$DENTAL','doctor');"
DOC_INV=$(trim "$(psql $CONN -c "select id from public.staff_invites where code='$DOC_CODE';")")
ASST_INV=$(trim "$(psql $CONN -c "select id from public.staff_invites where code='$ASST_CODE';")")

print "\n── Staff codes · redeem ───────────────────────────────────────"
expect_eq "an applicant starts with no requests" \
  "$applicant select count(*) from public.my_staff_requests();" 0
expect_err "a wrong code is rejected" \
  "$applicant select public.redeem_staff_invite('NOTACODE','doctor');"
expect_err "the patient join code is not a staff code" \
  "$applicant select public.redeem_staff_invite('DTOUCH26','doctor');"
expect_err "a doctor code cannot be used in the assistant app" \
  "$applicant select public.redeem_staff_invite('$DOC_CODE','assistant');"
expect_err "existing staff cannot redeem a code at their own clinic" \
  "$asst select public.redeem_staff_invite('$ASST_CODE','assistant');"
expect_eq "an applicant CAN redeem a doctor code" \
  "$applicant select public.redeem_staff_invite(lower('$DOC_CODE'),'doctor');" "$DOC_INV"
expect_eq "…which files a pending request under their name" \
  "select status||' '||redeemer_name||' '||redeemer_email from public.staff_invites where id='$DOC_INV';" \
  "pending Ana Reyes reyes@mail.com"
expect_eq "…that they can see, with the clinic's name" \
  "$applicant select clinic_name||' '||status from public.my_staff_requests();" \
  "D-Touch Dental Clinic pending"
expect_eq "…and grants no membership" \
  "$applicant select count(*) from public.clinic_memberships;" 0
expect_eq "…no clinic" "$applicant select count(*) from public.clinics;" 0
expect_eq "…and no appointments" "$applicant select count(*) from public.appointments;" 0
expect_err "a code works once" \
  "$applicant2 select public.redeem_staff_invite('$DOC_CODE','doctor');"
expect_eq "another applicant's requests stay private" \
  "$applicant2 select count(*) from public.my_staff_requests();" 0
expect_err "anon cannot redeem a code" \
  "$anon select public.redeem_staff_invite('$ASST_CODE','assistant');"
expect_ok "expire a fresh code" \
  "insert into public.staff_invites (clinic_id,role,code,expires_at)
   values ('$DENTAL','assistant','EXPIRED2',now()-interval '1 minute');"
expect_err "an expired code is rejected" \
  "$applicant2 select public.redeem_staff_invite('EXPIRED2','assistant');"

print "\n── Staff codes · approve / reject / revoke ────────────────────"
BRIGHT_DOC=$(trim "$(psql $CONN -c "select id from public.doctors where clinic_id='$BRIGHT' order by id limit 1;")")
UNLINKED_DOC=$(trim "$(psql $CONN -c "select id from public.doctors where clinic_id='$DENTAL' and profile_id is null order by id limit 1;")")
expect_err "an assistant cannot approve" \
  "$asst select public.decide_staff_request('$DOC_INV',true,null,'Orthodontics');"
expect_err "the applicant cannot approve themselves" \
  "$applicant select public.decide_staff_request('$DOC_INV',true,null,'Orthodontics');"
expect_err "BrightSmile's admin cannot approve a D-Touch request" \
  "$bright select public.decide_staff_request('$DOC_INV',true,null,'Orthodontics');"
expect_err "approving a doctor needs a specialty or a roster entry" \
  "$branch select public.decide_staff_request('$DOC_INV',true);"
expect_err "…and the roster entry must be this clinic's" \
  "$branch select public.decide_staff_request('$DOC_INV',true,'$BRIGHT_DOC');"
expect_err "…and not already linked to someone" \
  "$branch select public.decide_staff_request('$DOC_INV',true,'$DR_SANTOS');"
expect_dml "a branch admin CAN approve by linking an existing roster entry" \
  "$branch do \$\$ begin perform public.decide_staff_request('$DOC_INV',true,'$UNLINKED_DOC'); end \$\$;" \
  "select id from public.doctors where id='$UNLINKED_DOC' and profile_id='$APPLICANT_AUTH'" 1
expect_ok "a branch admin CAN approve by creating a roster entry" \
  "$branch select public.decide_staff_request('$DOC_INV',true,null,'Orthodontics');"
expect_eq "…which makes them a doctor at D-Touch" \
  "$applicant select role from public.clinic_memberships;" "doctor"
expect_eq "…on the roster under their own name" \
  "select full_name||' / '||specialty from public.doctors where profile_id='$APPLICANT_AUTH';" \
  "Ana Reyes / Orthodontics"
expect_eq "…with the request recording who approved and which row" \
  "select status||' '||(decided_by='$BRANCH_AUTH')||' '||(doctor_id is not null)
   from public.staff_invites where id='$DOC_INV';" "approved true true"
expect_eq "…so they now see D-Touch" "$applicant select count(*) from public.clinics;" 1
expect_eq "…and its appointments" "$applicant select count(*) from public.appointments;" 7
expect_err "a request cannot be decided twice" \
  "$dtadmin select public.decide_staff_request('$DOC_INV',false);"
expect_ok "a second applicant redeems the assistant code" \
  "$applicant2 select public.redeem_staff_invite('$ASST_CODE','assistant');"
expect_ok "an admin CAN reject the request" \
  "$dtadmin select public.decide_staff_request('$ASST_INV',false);"
expect_eq "…which grants nothing" \
  "$applicant2 select count(*) from public.clinic_memberships;" 0
expect_eq "…and the applicant sees it was rejected" \
  "$applicant2 select status from public.my_staff_requests();" "rejected"
REV_CODE=$(trim "$(psql $CONN -c "$dtadmin select code from public.create_staff_invite('$DENTAL','assistant');")")
REV_INV=$(trim "$(psql $CONN -c "select id from public.staff_invites where code='$REV_CODE';")")
expect_err "an assistant cannot revoke a code" \
  "$asst select public.revoke_staff_invite('$REV_INV');"
expect_ok "an admin CAN revoke an open code" \
  "$dtadmin select public.revoke_staff_invite('$REV_INV');"
expect_err "…after which it cannot be redeemed" \
  "$applicant2 select public.redeem_staff_invite('$REV_CODE','assistant');"
expect_err "a decided request cannot be revoked" \
  "$dtadmin select public.revoke_staff_invite('$DOC_INV');"
expect_dml "a branch admin CAN remove the doctor they approved" \
  "$branch do \$\$ begin perform public.remove_staff('$DENTAL','$APPLICANT_AUTH'); end \$\$;" \
  "select profile_id from public.clinic_memberships where profile_id='$APPLICANT_AUTH'" 0

print "\n── Visit times and overlaps ───────────────────────────────────"
# A Monday two months out, clear of every seeded visit. Dr Santos works
# Mon–Fri, 08:00–11:30 in half hours; Dr Reyes Mon/Wed/Fri afternoons.
MON=$(trim "$(psql $CONN -c "select d::date from generate_series(current_date + 60, current_date + 66, interval '1 day') d where extract(isodow from d) = 1;")")
SAT=$(trim "$(psql $CONN -c "select '$MON'::date + 5;")")
DR_REYES='20000000-0000-0000-0000-000000000002'
V1='7a000000-0000-0000-0000-000000000001'
V2='7a000000-0000-0000-0000-000000000002'
at() { print -r -- "(('$MON'::date + time '$1') at time zone 'Asia/Manila')" }
ROOT_CANAL="(select id from public.services where clinic_id='$DENTAL' and name='Root Canal')"
# Juan, Root Canal (90 min) with Dr Santos, Monday 09:00–10:30, confirmed.
NEWV="insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_id,service_name,scheduled_at,status)
      values ('$V1','$DENTAL','$PT_JUAN','$DR_SANTOS',$ROOT_CANAL,'Root Canal',$(at 09:00),'confirmed');"
# Same, but six weeks ago at an hour nothing else uses.
PASTV="insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
       values ('$V2','$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',
               ((current_date - 42 + time '19:17') at time zone 'Asia/Manila'),'confirmed');"

expect_eq "a visit lasts as long as its service (Root Canal: 90 min)" \
  "begin; $NEWV select (extract(epoch from ends_at - scheduled_at) / 60)::int from public.appointments where id='$V1'; rollback;" 90
expect_eq "…and the client cannot say otherwise" \
  "begin; insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_id,service_name,scheduled_at,ends_at,duration_minutes,status)
   values ('$V1','$DENTAL','$PT_JUAN','$DR_SANTOS',$ROOT_CANAL,'Root Canal',$(at 09:00),$(at 09:05),5,'confirmed');
   select (extract(epoch from ends_at - scheduled_at) / 60)::int from public.appointments where id='$V1'; rollback;" 90
expect_err_msg "a 90-minute visit at 09:00 blocks 10:00 for that doctor" \
  "begin; $NEWV insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 10:00),'confirmed');" "already has a visit"
expect_ok "…but 10:30, when it ends, is free" \
  "begin; $NEWV insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 10:30),'confirmed'); rollback;"
expect_ok "…and another doctor is free at 10:00" \
  "begin; $NEWV insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_REYES','Check-up',$(at 10:00),'confirmed'); rollback;"
expect_ok "cancelling a visit frees its time" \
  "begin; $NEWV update public.appointments set status='cancelled' where id='$V1';
   insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 09:30),'confirmed'); rollback;"
expect_err "…and reinstating it cannot land on the visit that took its place" \
  "begin; $NEWV update public.appointments set status='cancelled' where id='$V1';
   insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 09:30),'confirmed');
   update public.appointments set status='confirmed' where id='$V1';"

print "\n── One patient, one visit at a time ───────────────────────────"
# Juan with Dr Reyes at 09:00 — off Reyes's grid, which staff may do.
REYESV="insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
        values ('$DENTAL','$PT_JUAN','$DR_REYES','Check-up',$(at 09:00),'confirmed');"
expect_err_msg "the front desk cannot book a patient with two doctors at once" \
  "begin; $NEWV $asst $REYESV" "This patient already has a visit"
expect_err_msg "…nor overlap the tail of a longer visit (Root Canal ends 10:30)" \
  "begin; $NEWV $asst insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_REYES','Check-up',$(at 10:00),'confirmed');" "This patient already has a visit"
expect_ok "…but 10:30, when it ends, is free" \
  "begin; $NEWV $asst insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_REYES','Check-up',$(at 10:30),'confirmed'); rollback;"
expect_ok "a cancelled visit holds none of the patient's time" \
  "begin; $NEWV update public.appointments set status='cancelled' where id='$V1'; $asst $REYESV rollback;"
expect_err_msg "moving another visit onto the patient's time is refused" \
  "begin; $NEWV $asst insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$V2','$DENTAL','$PT_JUAN','$DR_REYES','Check-up',$(at 14:00),'confirmed');
   update public.appointments set scheduled_at=$(at 09:30) where id='$V2';" "This patient already has a visit"
expect_err_msg "…and so is handing a visit to a patient who is busy then" \
  "begin; $NEWV $asst insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$V2','$DENTAL','$PT_MARIA','$DR_REYES','Check-up',$(at 09:00),'confirmed');
   update public.appointments set patient_id='$PT_JUAN' where id='$V2';" "This patient already has a visit"
expect_err_msg "the constraint refuses it even when the readable check is bypassed" \
  "begin; $NEWV alter table public.appointments disable trigger appointments_set_times;
   insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,ends_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_REYES','Check-up',$(at 09:00),$(at 09:30),'confirmed');" "appointments_no_patient_overlap"
expect_ok "a person's chart at another clinic is a separate calendar" \
  "begin; $NEWV insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$OPTO','$PT_JUAN_OPTO',(select id from public.doctors where clinic_id='$OPTO' limit 1),
           'Eye Exam',$(at 09:00),'confirmed'); rollback;"
expect_eq "a patient is not offered a time they are booked elsewhere (09:00 with Reyes)" \
  "begin; $REYESV $juan select count(*) from public.available_slots('$DR_SANTOS','$MON'); rollback;" 7
expect_eq "…while the front desk still sees the doctor's free times" \
  "begin; $REYESV $asst select count(*) from public.available_slots('$DR_SANTOS','$MON'); rollback;" 8
expect_eq "…and moving that very visit does not count against itself" \
  "begin; $REYESV $juan select count(*) from public.available_slots('$DR_SANTOS','$MON',null,
     (select id from public.appointments where patient_id='$PT_JUAN' and doctor_id='$DR_REYES' and scheduled_at=$(at 09:00))); rollback;" 8
expect_err_msg "a patient booking over their own visit is refused" \
  "begin; $REYESV $juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',$(at 09:00),'pending');" "not available"

print "\n── Visit flow ─────────────────────────────────────────────────"
expect_dml "the front desk checks a patient in: confirmed → arrived" "$NEWV $asst" \
  "update public.appointments set status='arrived' where id='$V1' returning id" 1
expect_eq "…which stamps the arrival" \
  "begin; $NEWV $asst update public.appointments set status='arrived' where id='$V1';
   select arrived_at is not null from public.appointments where id='$V1'; rollback;" "t"
expect_err_msg "checking in no longer completes the visit" \
  "begin; $NEWV $asst update public.appointments set status='completed' where id='$V1';" "cannot become completed"
expect_err_msg "the front desk cannot start a consultation" \
  "begin; $NEWV $asst update public.appointments set status='arrived' where id='$V1';
   update public.appointments set status='in_consultation' where id='$V1';" "Only a doctor or admin"
expect_eq "a doctor starts it and completes it, and each step is stamped" \
  "begin; $NEWV $doc update public.appointments set status='in_consultation' where id='$V1';
   update public.appointments set status='completed' where id='$V1';
   select arrived_at is not null and started_at is not null and completed_at is not null
   from public.appointments where id='$V1'; rollback;" "t"
expect_err_msg "a completed visit is final for the front desk" \
  "begin; $NEWV update public.appointments set status='completed' where id='$V1';
   $asst update public.appointments set status='confirmed' where id='$V1';" "cannot become confirmed"
expect_dml "…but an admin may correct it" \
  "$NEWV update public.appointments set status='completed' where id='$V1'; $dtadmin" \
  "update public.appointments set status='confirmed' where id='$V1' returning id" 1
expect_err_msg "a visit still to come cannot be a no-show" \
  "begin; $NEWV $asst update public.appointments set status='no_show' where id='$V1';" "only once its time has come"
expect_dml "…one whose time has passed can" "$PASTV $asst" \
  "update public.appointments set status='no_show' where id='$V2' returning id" 1
expect_ok "…and a no-show frees the time it held" \
  "begin; $PASTV update public.appointments set status='no_show' where id='$V2';
   insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',
           ((current_date - 42 + time '19:17') at time zone 'Asia/Manila'),'confirmed'); rollback;"
expect_err_msg "staff cannot create a visit that is already completed" \
  "$asst insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 18:00),'completed');" "starts as pending"
expect_err_msg "a patient cannot cancel once they have arrived" \
  "begin; $NEWV update public.appointments set status='arrived' where id='$V1';
   $juan update public.appointments set status='cancelled' where id='$V1';" "no longer be cancelled"
expect_dml "…but can cancel a confirmed visit" "$NEWV $juan" \
  "update public.appointments set status='cancelled' where id='$V1' returning id" 1

print "\n── Availability ───────────────────────────────────────────────"
expect_eq "a free Monday offers all 8 of Dr Santos's times" \
  "$juan select count(*) from public.available_slots('$DR_SANTOS','$MON');" 8
expect_eq "…in the clinic's time zone" \
  "$juan select to_char(min(s) at time zone 'Asia/Manila','HH24:MI') from public.available_slots('$DR_SANTOS','$MON') s;" "08:00"
expect_eq "a 09:00–10:30 visit takes 09:00, 09:30 and 10:00 off a 30-minute list" \
  "begin; $NEWV $juan select count(*) from public.available_slots('$DR_SANTOS','$MON'); rollback;" 5
expect_eq "…and leaves a 90-minute service only the times it fits (10:30, 11:00, 11:30)" \
  "begin; $NEWV $juan select count(*) from public.available_slots('$DR_SANTOS','$MON',$ROOT_CANAL); rollback;" 3
expect_eq "a clinic closure empties the day" \
  "begin; insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON','$MON');
   $juan select count(*) from public.available_slots('$DR_SANTOS','$MON'); rollback;" 0
expect_eq "a doctor's leave empties only their day" \
  "begin; insert into public.doctor_time_off (clinic_id,doctor_id,starts_on,ends_on) values ('$DENTAL','$DR_SANTOS','$MON','$MON');
   $juan select (select count(*) from public.available_slots('$DR_SANTOS','$MON')) || '/'
             || (select count(*) from public.available_slots('$DR_REYES','$MON')); rollback;" "0/8"
expect_eq "nothing on a day the doctor does not work" \
  "$juan select count(*) from public.available_slots('$DR_SANTOS','$SAT');" 0
expect_eq "nothing for an account outside the clinic" \
  "set role authenticated; set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-0000000000ff';
   select count(*) from public.available_slots('$DR_SANTOS','$MON');" 0
expect_err "anon cannot ask" "$anon select public.available_slots('$DR_SANTOS','$MON');"
expect_err_msg "a patient cannot book off the grid" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',$(at 09:10));" "not available"
expect_dml "…the front desk can squeeze one in" "$asst" \
  "insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',$(at 09:10),'confirmed') returning id" 1
expect_err_msg "a patient cannot book into a closure" \
  "begin; insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON','$MON');
   $juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',$(at 09:00));" "not available"
expect_err_msg "…nor into the past" \
  "$juan insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',
           ((current_date - 7 + time '09:00') at time zone 'Asia/Manila'));" "not available"

print "\n── Time off ───────────────────────────────────────────────────"
expect_dml "the front desk can see time off" \
  "insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON','$MON'); $asst" \
  "select id from public.doctor_time_off" 1
expect_err "…but not book any" \
  "$asst insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON','$MON');"
expect_eq "patients cannot see it" \
  "begin; insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON','$MON');
   $juan select count(*) from public.doctor_time_off; rollback;" 0
expect_dml "a doctor can book their own leave" "$doc" \
  "insert into public.doctor_time_off (clinic_id,doctor_id,starts_on,ends_on,reason)
   values ('$DENTAL','$DR_SANTOS','$MON','$MON','Conference') returning id" 1
expect_err "…not a colleague's" \
  "$doc insert into public.doctor_time_off (clinic_id,doctor_id,starts_on,ends_on) values ('$DENTAL','$DR_REYES','$MON','$MON');"
expect_dml "an admin can close the clinic for a holiday" "$dtadmin" \
  "insert into public.doctor_time_off (clinic_id,starts_on,ends_on,reason)
   values ('$DENTAL','$MON','$MON','Holiday') returning id" 1
expect_err "leave cannot end before it starts" \
  "insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON','$MON'::date - 1);"
expect_err "a doctor's leave must be at the doctor's own clinic" \
  "insert into public.doctor_time_off (clinic_id,doctor_id,starts_on,ends_on) values ('$BRIGHT','$DR_SANTOS','$MON','$MON');"

print "\n── Doctors and services ───────────────────────────────────────"
expect_dml "a doctor can change their own working days" "$doc" \
  "update public.doctors set available_weekdays='{1,2}' where id='$DR_SANTOS' returning id" 1
expect_err_msg "…but cannot deactivate themselves" \
  "$doc update public.doctors set is_active=false where id='$DR_SANTOS';" "ask an admin"
expect_err_msg "…nor move to another clinic's roster" \
  "$doc update public.doctors set clinic_id='$BRIGHT' where id='$DR_SANTOS';" "ask an admin"
expect_dml "an admin can change a doctor's specialty" "$dtadmin" \
  "update public.doctors set specialty='Endodontics' where id='$DR_SANTOS' returning id" 1
expect_err "a time slot must be HH:MM" \
  "update public.doctors set available_time_slots='{9am}' where id='$DR_SANTOS';"
expect_err "a price cannot be negative" \
  "update public.services set price=-1 where clinic_id='$DENTAL' and name='Root Canal';"
expect_eq "the public page shows a service's price" \
  "begin; update public.services set price=1500 where clinic_id='$DENTAL' and name='Root Canal';
   $anon select s->>'price' from jsonb_array_elements(public.clinic_by_slug('dtouchdental')->'services') s
   where s->>'name'='Root Canal'; rollback;" "1500.00"

print "\n── Rescheduling ───────────────────────────────────────────────"
expect_eq "a patient moves their visit to an offered time; the clinic confirms it again" \
  "begin; $NEWV $juan do \$\$ begin perform public.reschedule_appointment('$V1', $(at 10:30)); end \$\$;
   select status || '/' || reschedule_count || '/' || (rescheduled_from = $(at 09:00))
   from public.appointments where id='$V1'; rollback;" "pending/1/true"
expect_ok "…even by half an hour, overlapping the time it is leaving" \
  "begin; $NEWV $juan select public.reschedule_appointment('$V1', $(at 09:30)); rollback;"
expect_eq "availability can leave the visit being moved out of the reckoning" \
  "begin; $NEWV $juan select (select count(*) from public.available_slots('$DR_SANTOS','$MON',$ROOT_CANAL)) || '/'
   || (select count(*) from public.available_slots('$DR_SANTOS','$MON',$ROOT_CANAL,'$V1')); rollback;" "3/8"
expect_err_msg "a patient cannot move off the grid" \
  "begin; $NEWV $juan select public.reschedule_appointment('$V1', $(at 09:10));" "not available"
expect_err_msg "…nor onto a closure" \
  "begin; $NEWV insert into public.doctor_time_off (clinic_id,starts_on,ends_on) values ('$DENTAL','$MON'::date + 2,'$MON'::date + 2);
   $juan select public.reschedule_appointment('$V1', (('$MON'::date + 2 + time '09:00') at time zone 'Asia/Manila'));" "not available"
expect_err_msg "…nor move someone else's visit" \
  "begin; insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$V1','$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 09:00),'confirmed');
   $juan select public.reschedule_appointment('$V1', $(at 10:30));" "not found"
expect_err_msg "…nor one that has started" \
  "begin; $NEWV update public.appointments set status='arrived' where id='$V1';
   $juan select public.reschedule_appointment('$V1', $(at 10:30));" "has not started"
expect_err_msg "nobody moves a visit into the past" \
  "begin; $NEWV $asst select public.reschedule_appointment('$V1', now() - interval '1 hour');" "still to come"
expect_eq "the front desk moves a visit to another doctor, and it stays confirmed" \
  "begin; $NEWV $asst do \$\$ begin perform public.reschedule_appointment('$V1', $(at 14:10), '$DR_REYES'); end \$\$;
   select status || '/' || (doctor_id = '$DR_REYES') from public.appointments where id='$V1'; rollback;" "confirmed/true"
expect_err_msg "…but not on top of another visit" \
  "begin; $NEWV insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 11:00),'confirmed');
   $asst select public.reschedule_appointment('$V1', $(at 10:30));" "already has a visit"
expect_err_msg "another clinic cannot move it" \
  "begin; $NEWV $bright select public.reschedule_appointment('$V1', $(at 10:30));" "not found"
expect_err_msg "a patient's own update changes the status only" \
  "begin; $NEWV $juan update public.appointments set status='cancelled', scheduled_at=$(at 10:30) where id='$V1';" "cancel or reschedule"
expect_err "anon cannot move a visit" \
  "$anon select public.reschedule_appointment('$A2', now() + interval '70 days');"

print "\n── Billing ────────────────────────────────────────────────────"
# Root Canal at ₱1,500; Juan's visit V1 has arrived.
PRICED="update public.services set price=1500 where clinic_id='$DENTAL' and name='Root Canal';"
HERE_V="$PRICED $NEWV update public.appointments set status='arrived' where id='$V1';"
BILL="(select id from public.invoices where appointment_id='$V1' and status <> 'void')"
# DO blocks, so a function's return value does not land in the checked output.
MAKE_BILL="do \$\$ begin perform public.create_invoice_for_appointment('$V1'); end \$\$;"
ISSUED="$HERE_V $asst $MAKE_BILL do \$\$ begin perform public.issue_invoice($BILL); end \$\$;"
expect_eq "the front desk bills a visit: one line, at the catalogue price" \
  "begin; $HERE_V $asst $MAKE_BILL
   select v.subtotal || '/' || v.total || '/' || v.status || '/' || count(i.*)
   from public.invoices v join public.invoice_items i on i.invoice_id = v.id
   where v.appointment_id='$V1' group by v.id; rollback;" "1500.00/1500.00/draft/1"
expect_eq "asking twice gives the same bill" \
  "begin; $HERE_V $asst select public.create_invoice_for_appointment('$V1') = public.create_invoice_for_appointment('$V1'); rollback;" "t"
expect_err_msg "a visit still pending is not billed yet" \
  "begin; $PRICED $NEWV update public.appointments set status='pending' where id='$V1';
   $asst $MAKE_BILL" "once the patient is here"
expect_err "a doctor reads bills but does not write them" \
  "begin; $HERE_V $doc $MAKE_BILL"
expect_eq "a client cannot write the totals or the status" \
  "begin; $asst insert into public.invoices (clinic_id,patient_id,status,subtotal,amount_paid,number)
   values ('$DENTAL','$PT_JUAN','paid',5,5,'INV-999999')
   returning status || '/' || subtotal || '/' || coalesce(number,'-'); rollback;" "draft/0.00/-"
expect_err_msg "…nor mark a bill paid" \
  "begin; $HERE_V $asst $MAKE_BILL update public.invoices set status='paid' where appointment_id='$V1';" "with its buttons"
expect_eq "a senior citizen's 20% comes off the total" \
  "begin; $HERE_V $asst $MAKE_BILL
   update public.invoices set discount_amount=300, discount_reason='Senior citizen' where appointment_id='$V1';
   select total from public.invoices where appointment_id='$V1'; rollback;" "1200.00"
expect_err_msg "a discount cannot exceed the bill" \
  "begin; $HERE_V $asst $MAKE_BILL
   update public.invoices set discount_amount=2000 where appointment_id='$V1';" "more than the bill"
expect_eq "adding a line updates the total" \
  "begin; $HERE_V $asst $MAKE_BILL
   insert into public.invoice_items (invoice_id,clinic_id,description,quantity,unit_price)
   values ($BILL,'$DENTAL','X-ray',2,250);
   select subtotal from public.invoices where appointment_id='$V1'; rollback;" "2000.00"
expect_eq "issuing numbers the bill" \
  "begin; $ISSUED select number || '/' || status from public.invoices where appointment_id='$V1'; rollback;" "INV-000001/issued"
expect_err_msg "an issued bill's lines are locked" \
  "begin; $ISSUED insert into public.invoice_items (invoice_id,clinic_id,description,unit_price)
   values ($BILL,'$DENTAL','Extra',100);" "can no longer be changed"
expect_err_msg "…and so is its discount" \
  "begin; $ISSUED update public.invoices set discount_amount=100 where id=$BILL;" "can no longer be changed"
expect_err_msg "an empty bill cannot be issued" \
  "begin; $HERE_V $asst $MAKE_BILL delete from public.invoice_items where invoice_id=$BILL;
   select public.issue_invoice($BILL);" "at least one line"
expect_err_msg "no payment on a draft" \
  "begin; $HERE_V $asst $MAKE_BILL
   insert into public.payments (invoice_id,clinic_id,amount) values ($BILL,'$DENTAL',100);" "Issue the bill"
expect_eq "a part payment leaves a balance; the rest pays the bill" \
  "begin; $ISSUED
   insert into public.payments (invoice_id,clinic_id,amount,method) values ($BILL,'$DENTAL',500,'cash');
   select status || '/' || balance from public.invoices where id=$BILL; rollback;" "issued/1000.00"
expect_eq "…and the rest pays it" \
  "begin; $ISSUED
   insert into public.payments (invoice_id,clinic_id,amount,method) values ($BILL,'$DENTAL',500,'cash');
   insert into public.payments (invoice_id,clinic_id,amount,method,reference) values ($BILL,'$DENTAL',1000,'gcash','GC-123');
   select status || '/' || balance from public.invoices where id=$BILL; rollback;" "paid/0.00"
expect_err_msg "no paying more than is owed" \
  "begin; $ISSUED insert into public.payments (invoice_id,clinic_id,amount) values ($BILL,'$DENTAL',1500.01);" "more than the"
expect_eq "a payment cannot be backdated" \
  "begin; $ISSUED insert into public.payments (invoice_id,clinic_id,amount,received_at)
   values ($BILL,'$DENTAL',100,now() - interval '30 days') returning received_at > now() - interval '1 minute'; rollback;" "t"
# No UPDATE policy, so an edit matches nothing rather than raising.
expect_dml "a payment cannot be edited" \
  "$ISSUED insert into public.payments (invoice_id,clinic_id,amount) values ($BILL,'$DENTAL',100);" \
  "update public.payments set amount=1 where invoice_id=$BILL returning id" 0
PAID1500="$ISSUED insert into public.payments (invoice_id,clinic_id,amount) values ($BILL,'$DENTAL',1500);"
expect_err_msg "the front desk cannot void a payment" \
  "begin; $PAID1500 select public.void_payment((select id from public.payments where invoice_id=$BILL), 'typo');" "Only an admin"
expect_eq "an admin can, with a reason, and the bill is owed again" \
  "begin; $PAID1500 $dtadmin do \$\$ begin perform public.void_payment((select id from public.payments where invoice_id=$BILL), 'Wrong amount'); end \$\$;
   select status || '/' || balance from public.invoices where id=$BILL; rollback;" "issued/1500.00"
expect_err_msg "a paid bill cannot be voided while its payments stand" \
  "begin; $PAID1500 select public.void_invoice($BILL, 'Billed the wrong patient');" "void them first"
expect_err_msg "voiding needs a reason" \
  "begin; $ISSUED select public.void_invoice($BILL, '  ');" "Say why"
expect_eq "a voided bill keeps its number and frees the visit for a new one" \
  "begin; $ISSUED do \$\$ begin perform public.void_invoice($BILL, 'Wrong service'); end \$\$;
   do \$\$ begin perform public.create_invoice_for_appointment('$V1'); end \$\$;
   select string_agg(status::text || ':' || coalesce(number,'-'), ',' order by created_at, status)
   from public.invoices where appointment_id='$V1'; rollback;" "draft:-,void:INV-000001"
expect_dml "a draft can be deleted" "$HERE_V $asst $MAKE_BILL" \
  "delete from public.invoices where appointment_id='$V1' returning id" 1
expect_dml "…an issued bill cannot" "$ISSUED" \
  "delete from public.invoices where appointment_id='$V1' returning id" 0
expect_eq "a patient does not see a draft" \
  "begin; $HERE_V $asst $MAKE_BILL $juan select count(*) from public.invoices; rollback;" 0
expect_eq "…sees an issued bill, its lines and payments" \
  "begin; $PAID1500 $juan select (select count(*) from public.invoices) || '/'
   || (select count(*) from public.invoice_items) || '/' || (select count(*) from public.payments); rollback;" "1/1/1"
expect_err "…and cannot pay it from the app" \
  "begin; $ISSUED $juan insert into public.payments (invoice_id,clinic_id,amount) values ($BILL,'$DENTAL',1);"
expect_eq "a doctor at the clinic can read it" \
  "begin; $ISSUED $doc select count(*) from public.invoices; rollback;" 1
expect_eq "another clinic sees nothing" \
  "begin; $PAID1500 $bright select (select count(*) from public.invoices) + (select count(*) from public.payments); rollback;" 0
expect_eq "the day's takings, by method, and what is still owed" \
  "begin; $ISSUED insert into public.payments (invoice_id,clinic_id,amount,method) values ($BILL,'$DENTAL',500,'gcash');
   $dtadmin select s->>'collected' || '/' || (s->'by_method'->>'gcash') || '/' || (s->>'outstanding')
   from public.billing_summary('$DENTAL', current_date - 1, current_date + 1) s; rollback;" "500.00/500.00/1000.00"
expect_eq "…which another clinic's admin cannot read" \
  "begin; $ISSUED $bright select public.billing_summary('$DENTAL', current_date - 1, current_date + 1)->>'billed'; rollback;" "0"

print "\n── Marking a visit done, prices, expenses, ledger ─────────────"
CLEANING="(select id from public.services where clinic_id='$DENTAL' and name='Teeth Cleaning')"
PRICES="update public.services set price=1500 where id=$ROOT_CANAL; update public.services set price=800 where id=$CLEANING;"
# Root Canal once, Teeth Cleaning twice: ₱1,500 + 2 × ₱800.
DONE_WITH="jsonb_build_array(jsonb_build_object('service_id',$ROOT_CANAL),
                             jsonb_build_object('service_id',$CLEANING,'quantity',2))"
COMPLETE="do \$\$ begin perform public.complete_visit('$V1', $DONE_WITH); end \$\$;"
expect_dml "the front desk marks a checked-in visit done" \
  "$NEWV $asst update public.appointments set status='arrived' where id='$V1';" \
  "update public.appointments set status='completed' where id='$V1' returning id" 1
expect_err_msg "…but still cannot start a consultation" \
  "begin; $NEWV $asst update public.appointments set status='arrived' where id='$V1';
   update public.appointments set status='in_consultation' where id='$V1';" "Only a doctor or admin"
expect_eq "marking done with services checks the patient in, completes the visit and bills what was done" \
  "begin; $PRICES $NEWV $asst $COMPLETE
   select a.status || '/' || (a.arrived_at is not null) || '/' || v.status || '/' || v.subtotal || '/'
          || (select count(*) from public.invoice_items i where i.invoice_id = v.id)
   from public.appointments a join public.invoices v on v.appointment_id = a.id
   where a.id='$V1'; rollback;" "completed/true/draft/3100.00/2"
expect_eq "a doctor can do it too, though they cannot bill" \
  "begin; $PRICES $NEWV $doc $COMPLETE reset role;
   select total from public.invoices where appointment_id='$V1'; rollback;" "3100.00"
expect_eq "no services, no bill" \
  "begin; $NEWV $doc select public.complete_visit('$V1') is null; rollback;" "t"
expect_eq "doing it again corrects the service lines and keeps lines typed by hand" \
  "begin; $PRICES $NEWV $asst $COMPLETE
   insert into public.invoice_items (invoice_id,clinic_id,description,unit_price) values ($BILL,'$DENTAL','X-ray',300);
   do \$\$ begin perform public.complete_visit('$V1', jsonb_build_array(jsonb_build_object('service_id',$ROOT_CANAL))); end \$\$;
   select subtotal from public.invoices where id=$BILL; rollback;" "1800.00"
expect_eq "…but leaves an issued bill alone" \
  "begin; $PRICES $NEWV $asst $COMPLETE do \$\$ begin perform public.issue_invoice($BILL); end \$\$;
   do \$\$ begin perform public.complete_visit('$V1', '[]'); end \$\$;
   select status || '/' || total from public.invoices where id=$BILL; rollback;" "issued/3100.00"
expect_err_msg "a visit still pending cannot be marked done" \
  "begin; $NEWV update public.appointments set status='pending' where id='$V1'; $asst $COMPLETE" "cannot be marked as done"
expect_err_msg "another clinic's service is refused" \
  "begin; $NEWV $asst select public.complete_visit('$V1', jsonb_build_array(jsonb_build_object('service_id',
     (select id from public.services where clinic_id <> '$DENTAL' limit 1))));" "not offered here"
expect_err_msg "another clinic cannot mark it done" \
  "begin; $NEWV $bright $COMPLETE" "not found"
expect_err_msg "…nor can the patient" \
  "begin; $NEWV $juan $COMPLETE" "not found"
expect_eq "the front desk sets a price" \
  "begin; $asst do \$\$ begin perform public.set_service_price($ROOT_CANAL, 1750.5); end \$\$; reset role;
   select price from public.services where id=$ROOT_CANAL; rollback;" "1750.50"
expect_dml "…but changes nothing else about the service" "$asst" \
  "update public.services set name='Renamed' where id=$ROOT_CANAL returning id" 0
expect_err_msg "…and not below zero" \
  "begin; $asst select public.set_service_price($ROOT_CANAL, -1);" "from 0 up"
expect_err_msg "a doctor does not set prices" \
  "begin; $doc select public.set_service_price($ROOT_CANAL, 1);" "not found"
expect_err_msg "…nor does another clinic" \
  "begin; $bright select public.set_service_price($ROOT_CANAL, 1);" "not found"

SPEND="insert into public.expenses (clinic_id,category,amount,method) values ('$DENTAL','Supplies',200,'cash');"
expect_eq "the front desk records an expense, as themselves" \
  "begin; $asst $SPEND reset role; select category || '/' || amount || '/' || (created_by = '$ASST_AUTH')
   from public.expenses; rollback;" "Supplies/200.00/true"
expect_err_msg "not dated in the future" \
  "begin; $asst insert into public.expenses (clinic_id,category,amount,spent_on) values ('$DENTAL','Rent',1,current_date + 3);" "future"
expect_err "a doctor cannot record one" "begin; $doc $SPEND"
expect_eq "…nor see them" "begin; $asst $SPEND $doc select count(*) from public.expenses; rollback;" 0
expect_eq "another clinic sees none" "begin; $asst $SPEND $bright select count(*) from public.expenses; rollback;" 0
expect_dml "an expense cannot be edited" "$asst $SPEND" \
  "update public.expenses set amount=1 returning id" 0
expect_err_msg "the front desk cannot void one" \
  "begin; $asst $SPEND select public.void_expense((select id from public.expenses), 'typo');" "Only an admin"
expect_eq "an admin can, with a reason" \
  "begin; $asst $SPEND $dtadmin do \$\$ begin perform public.void_expense((select id from public.expenses), 'Duplicate'); end \$\$;
   select void_reason from public.expenses; rollback;" "Duplicate"

LEDGER_DAY="$ISSUED insert into public.payments (invoice_id,clinic_id,amount,method) values ($BILL,'$DENTAL',500,'bpi'); $SPEND"
expect_eq "the ledger: gross, paid, pending, expenses and net" \
  "begin; $LEDGER_DAY
   select s->>'gross' || '/' || (s->>'paid') || '/' || (s->>'pending') || '/' || (s->>'expenses') || '/'
          || (s->>'net') || '/' || (s->'by_method'->>'bpi') || '/' || (s->'by_category'->>'Supplies')
   from public.ledger_summary('$DENTAL', current_date - 1, current_date + 1) s; rollback;" \
  "1500.00/500.00/1000.00/200.00/300.00/500.00/200.00"
expect_eq "…with the payment and the expense behind it" \
  "begin; $LEDGER_DAY select string_agg(kind || ':' || amount, ',' order by kind)
   from public.ledger_entries('$DENTAL', current_date - 1, current_date + 1); rollback;" "expense:200.00,payment:500.00"
expect_eq "a voided expense leaves the totals" \
  "begin; $LEDGER_DAY $dtadmin do \$\$ begin perform public.void_expense((select id from public.expenses), 'x'); end \$\$;
   select public.ledger_summary('$DENTAL', current_date - 1, current_date + 1)->>'net'; rollback;" "500.00"
expect_err_msg "a doctor cannot read the ledger" \
  "begin; $doc select public.ledger_summary('$DENTAL', current_date, current_date);" "front desk and admins"
expect_err_msg "…nor another clinic's admin" \
  "begin; $bright select public.ledger_entries('$DENTAL', current_date, current_date);" "front desk and admins"

print "\n── Notifications ──────────────────────────────────────────────"
FRONT_DESK=$(trim "$(psql $CONN -c "select count(*) from public.clinic_memberships where clinic_id='$DENTAL' and role in ('assistant','admin');")")
N="public.notifications"
JUAN_BOOKS="$juan insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at)
            values ('$V1','$DENTAL','$PT_JUAN','$DR_SANTOS','Check-up',$(at 09:00));"
expect_eq "a patient's booking request reaches everyone at the front desk" \
  "begin; $JUAN_BOOKS reset role; select count(*) from $N where kind='booking_requested' and appointment_id='$V1'; rollback;" "$FRONT_DESK"
expect_eq "…each in their own app, opening where they would handle it" \
  "begin; $JUAN_BOOKS reset role; select string_agg(distinct app || ' ' || link, ',') from $N where kind='booking_requested';
   rollback;" "admin /dtouchdental/appointments/$V1,assistant /dtouchdental/check-in"
expect_eq "…and not the patient who made it" \
  "begin; $JUAN_BOOKS reset role; select count(*) from $N where profile_id='$JUAN_AUTH'; rollback;" 0
expect_eq "confirming tells the patient" \
  "begin; $JUAN_BOOKS $asst update public.appointments set status='confirmed' where id='$V1';
   reset role; select app || ' ' || title || ' ' || link from $N where profile_id='$JUAN_AUTH'; rollback;" \
  "patient Visit confirmed /dtouchdental/appointments/$V1"
expect_eq "a patient's cancellation tells the front desk" \
  "begin; $NEWV $juan update public.appointments set status='cancelled' where id='$V1';
   reset role; select count(*) from $N where kind='visit_cancelled' and profile_id <> '$JUAN_AUTH'; rollback;" "$FRONT_DESK"
expect_eq "the clinic's cancellation tells the patient" \
  "begin; $NEWV $asst update public.appointments set status='cancelled' where id='$V1';
   reset role; select count(*) from $N where kind='visit_cancelled' and profile_id='$JUAN_AUTH'; rollback;" 1
expect_eq "check-in tells the doctor, in the doctor app" \
  "begin; $NEWV $asst update public.appointments set status='arrived' where id='$V1';
   reset role; select app || ' ' || title from $N where profile_id='$DOC_AUTH'; rollback;" "doctor Juan dela Cruz is here"
expect_eq "the clinic moving a visit tells the patient" \
  "begin; $NEWV $asst do \$\$ begin perform public.reschedule_appointment('$V1', $(at 10:30)); end \$\$;
   reset role; select kind from $N where profile_id='$JUAN_AUTH'; rollback;" "visit_moved"
expect_eq "the patient moving it asks the front desk to confirm" \
  "begin; $NEWV $juan do \$\$ begin perform public.reschedule_appointment('$V1', $(at 10:30)); end \$\$;
   reset role; select count(*) from $N where kind='visit_moved' and profile_id <> '$JUAN_AUTH'; rollback;" "$FRONT_DESK"
expect_eq "a doctor's note to the patient tells them" \
  "begin; $NEWV $doc update public.appointments set patient_note='Floss nightly.' where id='$V1';
   reset role; select title || ': ' || body from $N where profile_id='$JUAN_AUTH'; rollback;" "A note from Dr. Maria Santos: Floss nightly."
expect_eq "a patient without an account is simply not told" \
  "begin; insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at,status)
   values ('$V1','$DENTAL','$PT_MARIA','$DR_SANTOS','Check-up',$(at 09:00),'pending');
   $asst update public.appointments set status='confirmed' where id='$V1';
   reset role; select count(*) from $N; rollback;" 0
expect_eq "the service role notifies no one" \
  "begin; $NEWV update public.appointments set status='arrived' where id='$V1'; select count(*) from $N; rollback;" 0
expect_eq "issuing a bill tells the patient where to find it" \
  "begin; $ISSUED reset role; select body || ' ' || (link = '/dtouchdental/bills/' || $BILL)
   from $N where profile_id='$JUAN_AUTH'; rollback;" "INV-000001 · ₱1,500.00 true"
expect_eq "a patient reads only their own inbox" \
  "begin; $JUAN_BOOKS $asst update public.appointments set status='confirmed' where id='$V1';
   $juan select count(*) from $N; rollback;" 1
expect_dml "a patient can mark a notification read" \
  "$JUAN_BOOKS $asst update public.appointments set status='confirmed' where id='$V1'; $juan" \
  "update $N set read_at=now() returning id" 1
expect_err_msg "…but not rewrite it" \
  "begin; $JUAN_BOOKS $asst update public.appointments set status='confirmed' where id='$V1';
   $juan update $N set title='Free visits for life';" "Only read_at"
expect_dml "…nor mark someone else's" \
  "$JUAN_BOOKS $asst" "update $N set read_at=now() where profile_id <> '$ASST_AUTH' returning id" 0
expect_err "nobody writes notifications directly" \
  "$juan insert into $N (profile_id,app,kind,title,body) values ('$JUAN_AUTH','patient','x','x','x');"
SOON="insert into public.appointments (id,clinic_id,patient_id,doctor_id,service_name,scheduled_at,status,created_at)
      values ('$V2','$DENTAL','$PT_JUAN','$DR_REYES','Check-up',
              date_trunc('minute', now()) + interval '20 hours 3 minutes','confirmed',now() - interval '1 day');"
CLEAR_REYES="delete from public.appointments where doctor_id='$DR_REYES' and scheduled_at < now() + interval '2 days';"
expect_eq "a confirmed visit within the day gets one reminder" \
  "begin; $CLEAR_REYES $SOON do \$\$ begin perform private.send_visit_reminders(); end \$\$;
   select private.send_visit_reminders()
   || '/' || (select count(*) from $N where kind='visit_reminder' and profile_id='$JUAN_AUTH'); rollback;" "0/1"
expect_eq "…and another once it has moved" \
  "begin; $CLEAR_REYES $SOON do \$\$ begin perform private.send_visit_reminders(); end \$\$;
   update public.appointments set scheduled_at = scheduled_at + interval '1 hour' where id='$V2';
   select private.send_visit_reminders(); rollback;" 1
expect_eq "a visit booked just now is not reminded about" \
  "begin; $CLEAR_REYES $SOON update public.appointments set created_at=now() where id='$V2';
   select private.send_visit_reminders(); rollback;" 0

print "\n── Notification preferences ───────────────────────────────────"
MUTES='public.notification_mutes'
JUAN_MUTES_CONFIRMED="$juan insert into $MUTES (profile_id,app,kind) values ('$JUAN_AUTH','patient','visit_confirmed'); reset role;"
expect_eq "a muted kind is not written for that account" \
  "begin; $JUAN_MUTES_CONFIRMED $JUAN_BOOKS $asst update public.appointments set status='confirmed' where id='$V1';
   reset role; select count(*) from $N where profile_id='$JUAN_AUTH'; rollback;" 0
expect_eq "…other kinds still are" \
  "begin; $JUAN_MUTES_CONFIRMED $NEWV $asst update public.appointments set status='cancelled' where id='$V1';
   reset role; select kind from $N where profile_id='$JUAN_AUTH'; rollback;" "visit_cancelled"
expect_eq "…and a mute in one app leaves the others alone" \
  "begin; $asst insert into $MUTES (profile_id,app,kind) values ('$ASST_AUTH','patient','booking_requested');
   $JUAN_BOOKS reset role; select count(*) from $N where kind='booking_requested'; rollback;" "$FRONT_DESK"
expect_eq "a front desk mute stops only that account's copy" \
  "begin; $asst insert into $MUTES (profile_id,app,kind) values ('$ASST_AUTH','assistant','booking_requested');
   $JUAN_BOOKS reset role; select count(*) from $N where kind='booking_requested'; rollback;" "$((FRONT_DESK - 1))"
expect_eq "turning it back on is a delete" \
  "begin; $JUAN_MUTES_CONFIRMED $juan delete from $MUTES where kind='visit_confirmed';
   $JUAN_BOOKS $asst update public.appointments set status='confirmed' where id='$V1';
   reset role; select count(*) from $N where profile_id='$JUAN_AUTH'; rollback;" 1
expect_err "nobody mutes for someone else" \
  "$juan insert into $MUTES (profile_id,app,kind) values ('$ASST_AUTH','assistant','booking_requested');"
expect_eq "nobody reads someone else's mutes" \
  "begin; $JUAN_MUTES_CONFIRMED $asst select count(*) from $MUTES; rollback;" 0
expect_dml "…nor deletes them" \
  "$JUAN_MUTES_CONFIRMED $asst" "delete from $MUTES returning kind" 0
expect_err "an unknown kind is refused" \
  "$juan insert into $MUTES (profile_id,app,kind) values ('$JUAN_AUTH','patient','spam');"
expect_err "anon cannot mute" \
  "$anon insert into $MUTES (profile_id,app,kind) values ('$JUAN_AUTH','patient','visit_reminder');"

print "\n── Push subscriptions ─────────────────────────────────────────"
SUB="do \$\$ begin perform public.save_push_subscription('patient','https://push.example/abc','key','secret'); end \$\$;"
expect_eq "a browser subscribes for the signed-in account" \
  "begin; $juan $SUB select count(*) from public.push_subscriptions; rollback;" 1
expect_eq "the next account on that browser takes it over" \
  "begin; $juan $SUB $asst do \$\$ begin perform public.save_push_subscription('assistant','https://push.example/abc','key2','secret2'); end \$\$;
   reset role; select profile_id || ' ' || app from public.push_subscriptions; rollback;" "$ASST_AUTH assistant"
expect_eq "signing out removes it" \
  "begin; $juan $SUB do \$\$ begin perform public.delete_push_subscription('https://push.example/abc'); end \$\$;
   reset role; select count(*) from public.push_subscriptions; rollback;" 0
expect_eq "…but not someone else's" \
  "begin; $juan $SUB $asst do \$\$ begin perform public.delete_push_subscription('https://push.example/abc'); end \$\$;
   reset role; select count(*) from public.push_subscriptions; rollback;" 1
expect_eq "nobody reads another account's subscriptions" \
  "begin; $juan $SUB $asst select count(*) from public.push_subscriptions; rollback;" 0
expect_err_msg "only a real push endpoint is accepted" \
  "$juan select public.save_push_subscription('patient','http://evil.example/','k','s');" "not a push subscription"
expect_err "anon cannot subscribe" \
  "$anon select public.save_push_subscription('patient','https://push.example/x','k','s');"

print "\n── Calendar feed ──────────────────────────────────────────────"
FEEDS='public.calendar_feeds'
JUAN_FEED="$juan do \$\$ begin perform public.my_calendar_feed_token(); end \$\$; reset role;
           do \$\$ begin perform set_config('t.tok', (select token from $FEEDS
             where profile_id='$JUAN_AUTH'), true); end \$\$;"
AS_SVC="set role service_role;"
JUAN_FEED_ROWS=$(trim "$(psql $CONN -c "select count(*) from public.appointments a
  join public.patients pt on pt.id=a.patient_id join public.persons pe on pe.id=pt.person_id
  where pe.profile_id='$JUAN_AUTH' and a.status not in ('cancelled','no_show')
    and a.scheduled_at >= now() - interval '90 days';")")
JUAN_FEED_CLINICS=$(trim "$(psql $CONN -c "select count(distinct a.clinic_id) from public.appointments a
  join public.patients pt on pt.id=a.patient_id join public.persons pe on pe.id=pt.person_id
  where pe.profile_id='$JUAN_AUTH' and a.status not in ('cancelled','no_show')
    and a.scheduled_at >= now() - interval '90 days';")")
expect_eq "a patient gets a long random feed token" \
  "begin; $juan select public.my_calendar_feed_token() ~ '^[0-9a-f]{64}\$'; rollback;" "t"
expect_eq "…the same one each time they ask" \
  "begin; $juan select public.my_calendar_feed_token() = public.my_calendar_feed_token(); rollback;" "t"
expect_eq "…and a new one when they reset it" \
  "begin; $JUAN_FEED $juan select public.reset_calendar_feed_token() <> current_setting('t.tok'); rollback;" "t"
expect_err_msg "…after which the old URL is dead" \
  "begin; $JUAN_FEED $juan do \$\$ begin perform public.reset_calendar_feed_token(); end \$\$;
   $AS_SVC select * from public.calendar_feed_events(current_setting('t.tok'));" "No such calendar feed"
expect_err_msg "an unknown token is refused" \
  "$AS_SVC select * from public.calendar_feed_events('0000');" "No such calendar feed"
expect_eq "the feed lists every live visit of the account (seed has some)" \
  "begin; $JUAN_FEED $AS_SVC select count(*) from public.calendar_feed_events(current_setting('t.tok')); rollback;" "$JUAN_FEED_ROWS"
expect_eq "…across all of the person's clinics" \
  "begin; $JUAN_FEED $AS_SVC select count(distinct clinic_slug) from public.calendar_feed_events(current_setting('t.tok')); rollback;" "$JUAN_FEED_CLINICS"
expect_eq "…with the doctor and the clinic's slug for each" \
  "begin; $JUAN_FEED $AS_SVC select count(*) from public.calendar_feed_events(current_setting('t.tok'))
   where doctor_name is null or clinic_slug is null; rollback;" 0
expect_eq "a cancelled visit drops out of it" \
  "begin; $JUAN_FEED update public.appointments set status='cancelled' where id=(
     select a.id from public.appointments a where a.patient_id='$PT_JUAN'
        and a.status in ('pending','confirmed') and a.scheduled_at > now() limit 1);
   $AS_SVC select count(*) from public.calendar_feed_events(current_setting('t.tok')); rollback;" "$((JUAN_FEED_ROWS - 1))"
expect_eq "reading the feed stamps when it was last read" \
  "begin; $JUAN_FEED $AS_SVC do \$\$ begin perform public.calendar_feed_events(current_setting('t.tok')); end \$\$;
   reset role; select last_fetched_at is not null from $FEEDS where profile_id='$JUAN_AUTH'; rollback;" "t"
expect_eq "nobody reads another account's token" \
  "begin; $JUAN_FEED $asst select count(*) from $FEEDS; rollback;" 0
expect_err "a signed-in user cannot read feeds directly" \
  "$juan select * from public.calendar_feed_events('x');"
expect_err "…nor can anon" \
  "$anon select * from public.calendar_feed_events('x');"
expect_err "anon has no feed token" "$anon select public.my_calendar_feed_token();"

print "\n── RLS · anonymous ────────────────────────────────────────────"
expect_eq "anon sees no appointments" "$anon select count(*) from public.appointments;" 0
expect_eq "anon sees no clinics"      "$anon select count(*) from public.clinics;" 0
expect_eq "anon sees no doctors"      "$anon select count(*) from public.doctors;" 0
expect_eq "anon sees no persons"      "$anon select count(*) from public.persons;" 0
expect_eq "anon sees no patients"     "$anon select count(*) from public.patients;" 0
expect_eq "anon sees no medical notes" "$anon select count(*) from public.chart_notes;" 0
expect_eq "anon sees no visit notes"  "$anon select count(*) from public.visit_notes;" 0
expect_err "anon cannot insert an appointment" \
  "$anon insert into public.appointments (clinic_id,patient_id,doctor_id,service_name,scheduled_at)
   values ('$DENTAL','$PT_JUAN','$DR_SANTOS','Root Canal',now()+interval '80 days');"
expect_err "anon cannot call join_clinic" "$anon select public.join_clinic('DTOUCH26');"
expect_err "anon cannot call invite_staff" \
  "$anon select public.invite_staff('$DENTAL','newbie@mail.com','admin');"

print "\n── Public clinic pages ────────────────────────────────────────"
expect_eq "anon CAN read a clinic's public page by slug" \
  "$anon select public.clinic_by_slug('dtouchdental')->>'name';" "D-Touch Dental Clinic"
expect_eq "…matched case- and space-insensitively" \
  "$anon select public.clinic_by_slug('  DTouchDental ')->>'id';" "$DENTAL"
expect_eq "…with the vertical embedded the way the apps read it" \
  "$anon select public.clinic_by_slug('dtouchdental')->'clinic_type'->>'display_name' is not null;" "t"
expect_eq "…but NEVER the join code" \
  "$anon select public.clinic_by_slug('dtouchdental') ? 'join_code';" "f"
expect_eq "…nor any doctor's linked account" \
  "$anon select count(*) from jsonb_array_elements(public.clinic_by_slug('dtouchdental')->'doctors') d where d ? 'profile_id';" 0
DT_ACTIVE_SERVICES=$(trim "$(psql $CONN -c "select count(*) from public.services where clinic_id='$DENTAL' and is_active;")")
expect_eq "…listing every active service" \
  "$anon select jsonb_array_length(public.clinic_by_slug('dtouchdental')->'services');" "$DT_ACTIVE_SERVICES"
expect_eq "an unknown slug is null, not an error" \
  "$anon select public.clinic_by_slug('no-such-clinic') is null;" "t"
expect_eq "an inactive doctor is left off the page" \
  "begin; update public.doctors set is_active=false where id='$DR_SANTOS';
   $anon select count(*) from jsonb_array_elements(public.clinic_by_slug('dtouchdental')->'doctors') d
   where d->>'id'='$DR_SANTOS'; rollback;" 0
expect_eq "a suspended clinic's page looks like a mistyped link" \
  "begin; update public.clinics set is_active=false where id='$DENTAL';
   $anon select public.clinic_by_slug('dtouchdental') is null; rollback;" "t"
expect_err "a clinic cannot take a route's name as its slug" \
  "update public.clinics set slug='not-found' where id='$OPTO';"
expect_err "…nor a two-letter slug" \
  "update public.clinics set slug='cv' where id='$OPTO';"
# A column privilege, so this one raises rather than matching zero rows.
expect_err "an admin still cannot change their clinic's slug" \
  "$dtadmin update public.clinics set slug='mine' where id='$DENTAL';"

print "\n── Dental charting ────────────────────────────────────────────"
DENT_NEW="insert into public.dental_chart_entries (clinic_id,patient_id,appointment_id,tooth,surfaces,code,status)"
expect_eq "the dental vertical charts teeth; the others do not" \
  "select string_agg(slug || '=' || coalesce(chart_kind,'-'), ',' order by slug) from public.clinic_types;" \
  "dental=dental,optometry=-,pedia=-"
expect_eq "seeded: 7 entries at D-Touch, 1 at BrightSmile" \
  "select count(*) filter (where clinic_id='$DENTAL') || '/' || count(*) filter (where clinic_id='$BRIGHT')
   from public.dental_chart_entries;" "7/1"
expect_eq "the doctor reads D-Touch's 7 entries" \
  "$doc select count(*) from public.dental_chart_entries;" 7
expect_eq "…with their notes" \
  "$doc select note from public.dental_chart_entries where tooth=46 and code='caries';" \
  "Deep, close to the pulp"
expect_eq "the front desk reads them too (to bill and book the follow-up)" \
  "$asst select count(*) from public.dental_chart_entries;" 7
expect_eq "BrightSmile's admin reads only their own tenant's entry" \
  "$bright select count(*) from public.dental_chart_entries;" 1
expect_eq "a patient has no direct read of the table" \
  "$juan select count(*) from public.dental_chart_entries;" 0
expect_eq "…but reads his own chart through patient_dental_chart" \
  "$juan select count(*) from public.patient_dental_chart('$PT_JUAN');" 5
expect_eq "…which leaves the notes out" \
  "$juan select count(*) from information_schema.routines r
   join information_schema.parameters p on p.specific_name = r.specific_name
   where r.routine_name='patient_dental_chart' and p.parameter_mode='OUT' and p.parameter_name='note';" 0
expect_eq "…and returns nothing for someone else's chart" \
  "$juan select count(*) from public.patient_dental_chart('$PT_MARIA');" 0
expect_eq "…nor for anyone who is not a patient there" \
  "$doc select count(*) from public.patient_dental_chart('$PT_JUAN');" 0
expect_err "anon cannot call it" \
  "$anon select * from public.patient_dental_chart('$PT_JUAN');"

expect_dml "the doctor CAN chart a finding at a visit" "$doc" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN','$A6',17,'{D,M,D}','caries','existing') returning id" 1
expect_eq "…surfaces come back sorted, once each" \
  "begin; $doc $DENT_NEW values ('$DENTAL','$PT_JUAN','$A6',17,'{O,D,M,D}','caries','existing');
   select array_to_string(surfaces, '') from public.dental_chart_entries where tooth=17; rollback;" "DMO"
expect_eq "…and the author is the session, not the client" \
  "begin; $doc insert into public.dental_chart_entries (clinic_id,patient_id,tooth,code,status,created_by)
   values ('$DENTAL','$PT_JUAN',17,'crown','planned','$ASST_AUTH');
   select created_by = '$DOC_AUTH' from public.dental_chart_entries where tooth=17; rollback;" "t"
expect_dml "the admin CAN plan treatment outside a visit" "$dtadmin" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,21,'{}','crown','planned') returning id" 1
expect_dml "a primary tooth (FDI 85) is a tooth" "$doc" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,85,'{}','sealant','planned') returning id" 1
expect_err "the front desk cannot chart" \
  "$asst $DENT_NEW values ('$DENTAL','$PT_JUAN','$A6',17,'{}','crown','planned');"
expect_dml "…nor change an entry" "$asst" \
  "update public.dental_chart_entries set note='x' returning id" 0
expect_dml "…nor delete one" "$asst" \
  "delete from public.dental_chart_entries returning id" 0
expect_err "a patient cannot chart his own teeth" \
  "$juan $DENT_NEW values ('$DENTAL','$PT_JUAN',null,17,'{}','crown','planned');"
expect_err "BrightSmile cannot chart on D-Touch's patient" \
  "$bright $DENT_NEW values ('$DENTAL','$PT_MARIA',null,17,'{}','crown','planned');"
expect_dml "…nor touch D-Touch's entries" "$bright" \
  "update public.dental_chart_entries set note='x' where clinic_id='$DENTAL' returning id" 0
expect_err_msg "an eye clinic keeps no dental chart" \
  "$DENT_NEW values ('$OPTO','$PT_JUAN_OPTO',null,11,'{}','crown','planned');" \
  "does not keep a dental chart"
expect_err "tooth 19 does not exist" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,19,'{}','crown','planned');"
expect_err "nor does primary tooth 56" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,56,'{}','crown','planned');"
expect_err "an unknown surface is refused" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,17,'{X}','filling','planned');"
expect_err "surfaces on a crown mean nothing" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,17,'{O}','crown','planned');"
expect_err "a condition cannot be planned" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,17,'{}','caries','planned');"
expect_err "a found gap is 'missing', not an existing extraction" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,17,'{}','extraction','existing');"
expect_err "work done needs the visit it was done at" \
  "$DENT_NEW values ('$DENTAL','$PT_JUAN',null,17,'{}','crown','done');"
expect_err_msg "…a visit the patient attended, not a pending one" \
  "$doc $DENT_NEW values ('$DENTAL','$PT_JUAN','$A4',46,'{}','root_canal','done');" \
  "only at a visit the patient attended"
expect_err "an entry cannot hang off another patient's visit" \
  "$DENT_NEW values ('$DENTAL','$PT_MARIA','$A6',17,'{}','crown','planned');"
expect_dml "the doctor CAN carry out the plan at an attended visit" "$doc" \
  "update public.dental_chart_entries set status='done', appointment_id='$A6'
   where id='60000000-0000-0000-0000-000000000004' returning id" 1
expect_dml "the doctor CAN take back a mistaken entry" "$doc" \
  "delete from public.dental_chart_entries where id='60000000-0000-0000-0000-000000000005' returning id" 1
expect_eq "deleting a visit keeps its entries on the chart" \
  "begin;
   delete from public.appointments where id='$A7';
   select count(*) from public.dental_chart_entries
   where id='60000000-0000-0000-0000-000000000007' and appointment_id is null; rollback;" 1

print "\n── Patient search ─────────────────────────────────────────────"
# Earlier sections add charts at D-Touch, so count rather than assume.
DT_CHARTS=$(trim "$(psql $CONN -c "select count(*) from public.patients where clinic_id='$DENTAL';")")
expect_eq "the front desk pages through D-Touch's charts, two at a time" \
  "$asst select (r->>'total') || ':' || jsonb_array_length(r->'patients')
   from public.search_patients('$DENTAL', null, 2, 0) r;" "$DT_CHARTS:2"
expect_eq "…and the pages add up to the whole list" \
  "$asst select sum(jsonb_array_length(r->'patients'))
   from generate_series(0, $DT_CHARTS, 2) o, public.search_patients('$DENTAL', null, 2, o) r;" "$DT_CHARTS"
expect_eq "…sorted by name" \
  "$asst select string_agg(p->'person'->>'full_name', ',' order by n)
   from public.search_patients('$DENTAL') r,
        jsonb_array_elements(r->'patients') with ordinality as x(p, n);" \
  "$(trim "$(psql $CONN -c "select string_agg(pe.full_name, ',' order by lower(pe.full_name), pt.id)
     from public.patients pt join public.persons pe on pe.id=pt.person_id where pt.clinic_id='$DENTAL';")")"
expect_eq "search by part of the name" \
  "$asst select r->>'total' from public.search_patients('$DENTAL', 'juan') r;" 1
expect_eq "search by phone, however it is typed" \
  "$asst select r->>'total' from public.search_patients('$DENTAL',
     (select '+63 ' || substr(regexp_replace(pe.phone,'[^0-9]','','g'), 2)
      from public.persons pe where pe.id='$PERSON_JUAN')) r;" 1
expect_eq "a % is a character, not a wildcard" \
  "$asst select r->>'total' from public.search_patients('$DENTAL', '%') r;" 0
expect_eq "carries each chart's completed visits" \
  "$asst select p->>'completed_visits' from public.search_patients('$DENTAL', 'juan') r,
     jsonb_array_elements(r->'patients') p;" 1
expect_eq "…and its next visit" \
  "$asst select (p->>'next_visit_at') is not null from public.search_patients('$DENTAL', 'juan') r,
     jsonb_array_elements(r->'patients') p;" "t"
expect_eq "another tenant's staff get an empty page" \
  "$bright select r->>'total' from public.search_patients('$DENTAL') r;" 0
expect_eq "…and so does a patient" \
  "$juan select r->>'total' from public.search_patients('$DENTAL', 'maria') r;" 0
expect_err "anon cannot search" \
  "$anon select public.search_patients('$DENTAL');"

print "\n── Patient list: remarks, filters, sorting ────────────────────"
# <expr> over one chart's row in the list, as the front desk (or $3) sees it.
row() { print -r -- "${3:-$asst} select $2 from public.search_patients('$DENTAL', '$1') r,
  jsonb_array_elements(r->'patients') p;" }
# As the database owner, with triggers off, to set a scene the flow forbids.
SCENE="reset role; set local session_replication_role = replica;"
MARIA_DONE="update public.appointments set status='cancelled'
  where patient_id='$PT_MARIA' and scheduled_at > now();"
expect_eq "the counts cover the whole search" \
  "$asst select r->'counts'->>'all' from public.search_patients('$DENTAL') r;" "$DT_CHARTS"
expect_eq "first and last visit are the same when there was one" \
  "$(row juan "p->>'first_visit_at' = p->>'last_visit_at'")" "t"
expect_eq "…with who saw them and for what" \
  "$(row juan "p->>'last_visit_doctor' is not null and p->>'last_visit_service' is not null")" "t"
expect_eq "nothing owed: no balance remark" \
  "$(row juan "(p->>'balance') || '/' || (p->'flags' ? 'balance')")" "0/false"
expect_eq "an issued bill is owed, and flagged" \
  "begin; $ISSUED $(row juan "(p->>'balance') || '/' || (p->'flags' ? 'balance')") rollback;" "1500.00/true"
expect_eq "…which the doctor sees too" \
  "begin; $ISSUED $(row juan "p->>'balance'" "$doc") rollback;" "1500.00"
expect_eq "a draft bill is not owed yet" \
  "begin; $HERE_V $asst $MAKE_BILL $(row juan "p->>'balance'") rollback;" "0"
expect_eq "unpaid 30 days after issue needs attention" \
  "begin; $ISSUED $SCENE update public.invoices set issued_at = now() - interval '40 days' where id=$BILL;
   $(row juan "p->'attention'") rollback;" '["overdue_balance"]'
expect_eq "…not before" \
  "begin; $ISSUED $(row juan "p->'attention'") rollback;" '[]'
expect_eq "no phone and no email: no way to reach them" \
  "begin; $SCENE update public.persons set phone='', email=null where id='$PERSON_MARIA';
   $asst select count(*) from public.search_patients('$DENTAL', null, 30, 0, '{no_contact}') r,
     jsonb_array_elements(r->'patients') p where p->>'id'='$PT_MARIA'; rollback;" 1
expect_eq "seen 8 months ago with nothing booked: due for recall" \
  "begin; $SCENE $MARIA_DONE update public.appointments set scheduled_at = now() - interval '8 months'
   where patient_id='$PT_MARIA' and status='completed';
   $(row maria "p->'flags' ? 'recall'") rollback;" "t"
expect_eq "…not at a clinic that recalls yearly" \
  "begin; $SCENE $MARIA_DONE update public.appointments set scheduled_at = now() - interval '8 months'
   where patient_id='$PT_MARIA' and status='completed';
   update public.clinics set recall_months=12 where id='$DENTAL';
   $(row maria "p->'flags' ? 'recall'") rollback;" "f"
expect_eq "…nor with a visit booked" \
  "$(row juan "p->'flags' ? 'recall'")" "f"
expect_eq "a last visit missed needs attention" \
  "begin; $SCENE $MARIA_DONE update public.appointments set status='no_show' where id='$A7';
   $(row maria "p->'attention'") rollback;" '["no_show"]'
expect_eq "planned work and nothing booked needs attention" \
  "begin; $SCENE $MARIA_DONE insert into public.dental_chart_entries
     (clinic_id,patient_id,appointment_id,tooth,surfaces,code,status)
     values ('$DENTAL','$PT_MARIA',null,17,'{}','crown','planned');
   $(row maria "p->'attention' ? 'unbooked_plan'") rollback;" "t"
expect_eq "under 18 is pedia" \
  "begin; $SCENE update public.persons set date_of_birth = current_date - interval '10 years'
   where id='$PERSON_MARIA';
   $(row maria "(p->>'age') || '/' || (p->'flags' ? 'pedia') || '/' || (p->'flags' ? 'adult')") rollback;" "10/true/false"
expect_eq "every filter must hold: pedia and adult is no one" \
  "$asst select r->>'total' from public.search_patients('$DENTAL', null, 30, 0, '{pedia,adult}') r;" 0
expect_eq "…and the counts still cover the whole search" \
  "$asst select r->'counts'->>'all' from public.search_patients('$DENTAL', null, 30, 0, '{pedia,adult}') r;" "$DT_CHARTS"
expect_eq "sorts by name, backwards" \
  "$asst select r->'patients'->0->'person'->>'full_name'
   from public.search_patients('$DENTAL', null, 1, 0, null, 'name', true) r;" \
  "$(trim "$(psql $CONN -c "select pe.full_name from public.patients pt join public.persons pe on pe.id=pt.person_id
     where pt.clinic_id='$DENTAL' order by lower(pe.full_name) desc, pt.id limit 1;")")"
expect_eq "sorts by most visits" \
  "$asst select r->'patients'->0->>'completed_visits'
   from public.search_patients('$DENTAL', null, 1, 0, null, 'visits', true) r;" \
  "$(trim "$(psql $CONN -c "select max(c) from (select count(*) filter (where a.status='completed') c
     from public.patients pt left join public.appointments a on a.patient_id=pt.id
     where pt.clinic_id='$DENTAL' group by pt.id) x;")")"
expect_eq "…and the sorted pages still add up" \
  "$asst select sum(jsonb_array_length(r->'patients'))
   from generate_series(0, $DT_CHARTS, 2) o,
        public.search_patients('$DENTAL', null, 2, o, null, 'last_visit', true) r;" "$DT_CHARTS"
expect_err "an admin sets the recall interval within reason" \
  "$dtadmin update public.clinics set recall_months=0 where id='$DENTAL';"
expect_dml "…and may set it" "$dtadmin" \
  "update public.clinics set recall_months=12 where id='$DENTAL' returning id" 1

print "\n── Patient information form ───────────────────────────────────"
INTAKE="'{\"under_treatment\":false,\"takes_medications\":true,\"medications\":\" Losartan 50mg \",
  \"allergies\":[\"penicillin\",\"latex\"],\"conditions\":[\"high_blood_pressure\"],
  \"signed_name\":\"Ana Cruz\",\"consent\":true}'::jsonb"
ANA="'{\"full_name\":\" Ana Cruz \",\"phone\":\"0917 555 0101\",\"date_of_birth\":\"1990-04-02\",
  \"sex\":\"female\",\"emergency_contact_name\":\"Ben Cruz\",\"emergency_contact_phone\":\"0917 555 0102\"}'::jsonb"
REGISTER_ANA="public.register_patient('$DENTAL', $ANA, $INTAKE, 'front_desk_tablet')"
expect_eq "the front desk registers a patient with their form, no visit needed" \
  "begin; $asst select count(*) from (select $REGISTER_ANA) x; reset role;
   select pe.full_name || '|' || pe.sex || '|' || i.source || '|' || i.medications || '|'
          || array_to_string(i.allergies, ',') || '|' || (i.consent_at is not null)
     from public.patient_intakes i
     join public.patients pt on pt.id = i.patient_id
     join public.persons pe on pe.id = pt.person_id
    where pe.full_name = 'Ana Cruz';
   rollback;" \
  $'1\nAna Cruz|female|front_desk_tablet|Losartan 50mg|penicillin,latex|true'
expect_eq "…and can read what they just registered" \
  "begin; $asst create temp table t as select $REGISTER_ANA as id;
   select pe.emergency_contact_name from public.patients pt
     join public.persons pe on pe.id = pt.person_id where pt.id = (select id from t);
   rollback;" "Ben Cruz"
expect_ok "a form is optional: registering can be just who they are" \
  "begin; $asst select public.register_patient('$DENTAL', '{\"full_name\":\"Quick Add\",\"phone\":\"0917 555 0199\"}'); rollback;"
expect_err_msg "registering needs a phone number" \
  "$asst select public.register_patient('$DENTAL', '{\"full_name\":\"No Phone\"}');" \
  "phone is required"
expect_err_msg "…and the privacy consent, when a form comes with it" \
  "$asst select public.register_patient('$DENTAL', $ANA,
     '{\"under_treatment\":false,\"takes_medications\":false,\"signed_name\":\"Ana\"}');" \
  "privacy consent"
expect_err_msg "the yes/no questions must be answered" \
  "$asst select public.register_patient('$DENTAL', $ANA, '{\"signed_name\":\"Ana\",\"consent\":true}');" \
  "under treatment"
expect_err "an allergy that is not on the list goes in 'other'" \
  "$asst select public.register_patient('$DENTAL', $ANA,
     '{\"under_treatment\":false,\"takes_medications\":false,\"allergies\":[\"cats\"],
       \"signed_name\":\"Ana\",\"consent\":true}');"
expect_err "an unknown sex value is refused" \
  "$asst select public.register_patient('$DENTAL',
     '{\"full_name\":\"X\",\"phone\":\"0917 555 0100\",\"sex\":\"x\"}');"
expect_err_msg "the patient app does not register patients" \
  "$asst select public.register_patient('$DENTAL', $ANA, $INTAKE, 'patient_app');" \
  "join a clinic"
expect_err "a doctor does not register patients" \
  "$doc select public.register_patient('$DENTAL', $ANA, $INTAKE);"
expect_err "nor does another clinic's admin, at this clinic" \
  "$bright select public.register_patient('$DENTAL', $ANA, $INTAKE);"
expect_err "anon cannot register anyone" \
  "$anon select public.register_patient('$DENTAL', $ANA, $INTAKE);"

expect_ok "a patient fills in their own form in the patient app" \
  "$juan select public.save_patient_intake('$PT_JUAN',
     '{\"sex\":\"male\",\"address\":\"Makati\"}', $INTAKE, 'patient_app');"
expect_eq "…which updates who they are without blanking what the form left out" \
  "select pe.sex || '|' || pe.address || '|' || (pe.phone is not null)
   from public.persons pe where pe.id='$PERSON_JUAN';" "male|Makati|true"
expect_eq "…and they can read it back" \
  "$juan select source from public.patient_intakes where patient_id='$PT_JUAN';" "patient_app"
expect_eq "the front desk sees it too" \
  "$asst select medications from public.patient_intakes where patient_id='$PT_JUAN';" "Losartan 50mg"
expect_eq "…and the doctor" \
  "$doc select array_to_string(conditions, ',') from public.patient_intakes where patient_id='$PT_JUAN';" \
  "high_blood_pressure"
expect_eq "another clinic's staff do not" \
  "$bright select count(*) from public.patient_intakes where patient_id='$PT_JUAN';" 0
expect_eq "…nor does another patient" \
  "begin; $asst select count(*) from (select public.save_patient_intake('$PT_MARIA', '{}', $INTAKE, 'staff')) x;
   $juan select count(*) from public.patient_intakes where patient_id='$PT_MARIA'; rollback;" $'1\n0'
expect_eq "Juan's form at D-Touch is not his form at ClearVision" \
  "$juan select count(*) from public.patient_intakes where patient_id='$PT_JUAN_OPTO';" 0
expect_err_msg "a patient cannot fill in someone else's form" \
  "$juan select public.save_patient_intake('$PT_MARIA', '{}', $INTAKE, 'patient_app');" \
  "no such patient"
expect_err_msg "…nor pass their own answers off as the front desk's" \
  "$juan select public.save_patient_intake('$PT_JUAN', '{}', $INTAKE, 'staff');" \
  "only this clinic's staff"
expect_err_msg "a name cannot be blanked" \
  "$juan select public.save_patient_intake('$PT_JUAN', '{\"full_name\":\" \"}', $INTAKE, 'patient_app');" \
  "name is required"
expect_ok "the front desk updates a walk-in's form on the tablet" \
  "$asst select public.save_patient_intake('$PT_MARIA', '{\"address\":\"Pasig\"}', $INTAKE, 'front_desk_tablet');"
expect_eq "…one form per chart: saving again replaces it" \
  "begin; $asst select public.save_patient_intake('$PT_MARIA', '{}',
     '{\"under_treatment\":false,\"takes_medications\":false,\"medications\":\"ignored\",
       \"signed_name\":\"Maria\",\"consent\":true}', 'staff');
   reset role;
   select (select count(*) from public.patient_intakes where patient_id='$PT_MARIA')
          || '|' || coalesce(medications, 'none') || '|' || source
   from public.patient_intakes where patient_id='$PT_MARIA'; rollback;" $'\n1|none|staff'
expect_err_msg "another clinic's admin cannot fill in D-Touch's form" \
  "$bright select public.save_patient_intake('$PT_MARIA', '{}', $INTAKE, 'staff');" \
  "no such patient"
expect_err "…nor write it straight into the table" \
  "$bright insert into public.patient_intakes (patient_id, clinic_id, under_treatment,
     takes_medications, consent_at, signed_name, source)
   values ('$PT_JUAN', '$DENTAL', false, false, now(), 'J', 'staff');"
expect_dml "…while at their own clinic they can" "$bright" \
  "insert into public.patient_intakes (patient_id, clinic_id, under_treatment,
     takes_medications, consent_at, signed_name, source)
   values ('$PT_MARIA_BRIGHT', '$BRIGHT', false, false, now(), 'M', 'staff')
   returning patient_id" 1
expect_err "…and an intake cannot sit on another clinic's chart" \
  "insert into public.patient_intakes (patient_id, clinic_id, under_treatment,
     takes_medications, consent_at, signed_name, source)
   values ('$PT_JUAN', '$BRIGHT', false, false, now(), 'J', 'staff');"
expect_dml "nobody deletes a form" "$asst" \
  "delete from public.patient_intakes where patient_id='$PT_MARIA' returning patient_id" 0

GUARDIAN="'{\"under_treatment\":false,\"takes_medications\":false,
  \"filled_by_guardian\":true,\"guardian_name\":\" Rosa Santos \",\"guardian_relationship\":\"parent\",
  \"guardian_phone\":\"0917 555 0133\",\"guardian_email\":\" \",
  \"signed_name\":\"Rosa Santos\",\"consent\":true}'::jsonb"
expect_eq "a parent fills in the form for their child, and is recorded" \
  "begin; $asst select count(*) from (select public.save_patient_intake('$PT_MARIA', '{}', $GUARDIAN, 'front_desk_tablet')) x;
   reset role;
   select guardian_name || '|' || guardian_relationship || '|' || guardian_phone || '|'
          || coalesce(guardian_email, 'none') || '|' || signed_name
     from public.patient_intakes where patient_id='$PT_MARIA'; rollback;" \
  $'1\nRosa Santos|parent|0917 555 0133|none|Rosa Santos'
expect_eq "…and the patient app can say so too" \
  "begin; $juan select count(*) from (select public.save_patient_intake('$PT_JUAN', '{}', $GUARDIAN, 'patient_app')) x;
   select guardian_relationship from public.patient_intakes where patient_id='$PT_JUAN'; rollback;" \
  $'1\nparent'
expect_err_msg "a guardian needs a name, relationship and phone" \
  "$asst select public.save_patient_intake('$PT_MARIA', '{}',
     '{\"under_treatment\":false,\"takes_medications\":false,\"filled_by_guardian\":true,
       \"guardian_name\":\"Rosa\",\"guardian_relationship\":\"parent\",
       \"signed_name\":\"Rosa\",\"consent\":true}', 'staff');" \
  "name, relationship and phone"
expect_err "…and is a parent or a guardian" \
  "$asst select public.save_patient_intake('$PT_MARIA', '{}',
     '{\"under_treatment\":false,\"takes_medications\":false,\"filled_by_guardian\":true,
       \"guardian_name\":\"Rosa\",\"guardian_relationship\":\"neighbour\",\"guardian_phone\":\"0917\",
       \"signed_name\":\"Rosa\",\"consent\":true}', 'staff');"
expect_eq "without the box ticked, guardian keys are ignored" \
  "begin; $asst select count(*) from (select public.save_patient_intake('$PT_MARIA', '{}',
     '{\"under_treatment\":false,\"takes_medications\":false,\"guardian_name\":\"Stray\",
       \"signed_name\":\"Maria\",\"consent\":true}', 'staff')) x;
   reset role;
   select coalesce(guardian_name, 'none') from public.patient_intakes where patient_id='$PT_MARIA'; rollback;" \
  $'1\nnone'
expect_eq "a later form by the patient themself clears the guardian" \
  "begin; $asst select count(*) from (select public.save_patient_intake('$PT_MARIA', '{}', $GUARDIAN, 'staff')) x;
   select count(*) from (select public.save_patient_intake('$PT_MARIA', '{}', $INTAKE, 'staff')) x;
   reset role;
   select coalesce(guardian_name, 'none') from public.patient_intakes where patient_id='$PT_MARIA'; rollback;" \
  $'1\n1\nnone'
expect_err "a half-guardian cannot be written straight into the table" \
  "insert into public.patient_intakes (patient_id, clinic_id, under_treatment,
     takes_medications, consent_at, signed_name, source, guardian_name)
   values ('$PT_MARIA_BRIGHT', '$BRIGHT', false, false, now(), 'M', 'staff', 'Rosa')
   on conflict (patient_id) do update set guardian_name = excluded.guardian_name;"

print "\n── Staff PIN (front desk tablet) ──────────────────────────────"
expect_eq "no PIN until one is set" "$asst select public.has_staff_pin();" "f"
expect_err_msg "a PIN is four digits" "$asst select public.set_staff_pin('12a4');" "4 digits"
expect_err_msg "patients have no staff PIN" "$juan select public.set_staff_pin('1234');" "only clinic staff"
expect_err_msg "checking a PIN that was never set says so" \
  "$asst select public.verify_staff_pin('1234');" "set a staff PIN first"
expect_ok "the front desk sets a PIN" "$asst select public.set_staff_pin('2468');"
expect_eq "…and has one now" "$asst select public.has_staff_pin();" "t"
expect_eq "the right PIN unlocks" "$asst select public.verify_staff_pin('2468');" "t"
expect_eq "a wrong one does not" "$asst select public.verify_staff_pin('0000');" "f"
expect_eq "the PIN is one account's: the doctor has none" "$doc select public.has_staff_pin();" "f"
expect_eq "nobody reads the stored PINs" "$asst select count(*) from public.staff_pins;" 0
expect_err_msg "five wrong PINs lock it, even against the right one" \
  "$asst select public.verify_staff_pin('0000') from generate_series(1, 5);
   select public.verify_staff_pin('2468');" "too many wrong PINs"
expect_eq "…the wrong attempts are counted even though each only returns false" \
  "$asst select public.verify_staff_pin('1111'); reset role;
   select failed_attempts from public.staff_pins where profile_id='$ASST_AUTH';" \
  $'f\n2'
expect_ok "setting a new PIN clears the count" "$asst select public.set_staff_pin('1357');"
expect_err "anon cannot check PINs" "$anon select public.verify_staff_pin('1357');"

print "\n── Patient import / export ────────────────────────────────────"
# Two new patients (one with the form, a note and an old balance), one that
# is Maria again under a different phone format, and one bad row.
IMPORT_ROWS="'[
  {\"row\":2,\"chart_number\":\"A-0001\",
   \"person\":{\"full_name\":\" Rosa Imported \",\"phone\":\"0917 555 0301\",\"date_of_birth\":\"1970-01-02\",\"sex\":\"female\"},
   \"intake\":{\"under_treatment\":false,\"takes_medications\":true,\"medications\":\"Metformin\",
              \"allergies\":[\"latex\"],\"signed_name\":\"Rosa Imported\",\"signed_on\":\"2024-05-06\"},
   \"chart_note\":\"Sensitive lower molars.\",\"opening_balance\":\"1500.50\"},
  {\"row\":3,\"person\":{\"full_name\":\"Nophone Imported\"}},
  {\"row\":4,\"person\":{\"full_name\":\"maria reyes\",\"phone\":\"+63 928 123 4567\"}},
  {\"row\":5,\"person\":{\"full_name\":\"Bad Sex\",\"phone\":\"0917 555 0302\",\"sex\":\"x\"}}
]'::jsonb"
res() { print -r -- "(select string_agg(e->>'result', ',' order by (e->>'row')::int) from jsonb_array_elements($1) e)" }

expect_eq "a dry run says what each row would do" \
  "$asst select $(res "public.import_patients('$DENTAL', $IMPORT_ROWS)");" \
  "created,created,duplicate,error"
expect_eq "…and writes nothing" \
  "$asst select count(*) from public.persons where full_name like '%Imported%';" 0
expect_eq "…and takes no invoice number" \
  "select count(*) from public.invoices where notes = 'Opening balance (imported)';" 0
expect_eq "the duplicate names the patient already here" \
  "$asst select e->'match'->>'id' from jsonb_array_elements(public.import_patients('$DENTAL', $IMPORT_ROWS)) e
   where e->>'row' = '4';" "$PT_MARIA"
expect_eq "a bad value is explained on its row" \
  "$asst select e->>'message' from jsonb_array_elements(public.import_patients('$DENTAL', $IMPORT_ROWS)) e
   where e->>'row' = '5';" "Sex must be Female or Male."
expect_eq "a missing phone is a warning, not a failure" \
  "$asst select jsonb_array_length(e->'warnings') from jsonb_array_elements(public.import_patients('$DENTAL', $IMPORT_ROWS)) e
   where e->>'row' = '3';" 1
expect_eq "the front desk's notes are left out, with a warning" \
  "$asst select e->'warnings'->>0 from jsonb_array_elements(public.import_patients('$DENTAL', $IMPORT_ROWS)) e
   where e->>'row' = '2';" "Clinic notes were left out: only doctors and admins can add them."
expect_err_msg "doctors do not import" \
  "$doc select public.import_patients('$DENTAL', $IMPORT_ROWS);" "Only the front desk and admins"
expect_err_msg "nor does another clinic's admin" \
  "$bright select public.import_patients('$DENTAL', $IMPORT_ROWS);" "Only the front desk and admins"
expect_err "nor anon" "$anon select public.import_patients('$DENTAL', $IMPORT_ROWS);"
expect_err_msg "a batch belongs to its clinic" \
  "begin; $dtadmin select public.import_patients('$BRIGHT', '[]',
     public.start_import('$DENTAL', 'patients', 'x.csv')); rollback;" "Only the front desk and admins"
expect_err_msg "…and to whoever started it" \
  "begin; $dtadmin select 1 where set_config('test.batch', public.start_import('$DENTAL', 'patients', 'x.csv')::text, true) is null;
   $asst select public.import_patients('$DENTAL', '[]', current_setting('test.batch')::uuid); rollback;" "not yours"

# The real run, kept (no rollback) for the checks that follow; undone below.
psql $CONN -c "$dtadmin select public.start_import('$DENTAL', 'patients', 'legacy.csv');" > /dev/null
BATCH=$(trim "$(psql $CONN -c "select id from public.import_batches where file_name='legacy.csv';")")
IMPORT_OUT=$(trim "$(psql $CONN -c "$dtadmin select $(res "public.import_patients('$DENTAL', $IMPORT_ROWS, '$BATCH')");")")
expect_eq "an admin imports: created, created, duplicate held back, error" \
  "select '$IMPORT_OUT';" "created,created,duplicate,error"
expect_eq "…the batch keeps the tally" \
  "select created_count || '/' || updated_count || '/' || skipped_count || '/' || failed_count
   from public.import_batches where id='$BATCH';" "2/0/1/1"
expect_eq "…the person, trimmed, with a chart and its number" \
  "select pe.full_name || '|' || pt.chart_number from public.patients pt
   join public.persons pe on pe.id=pt.person_id where pt.clinic_id='$DENTAL' and pe.full_name='Rosa Imported';" \
  "Rosa Imported|A-0001"
expect_eq "…the form, marked as imported and dated as signed" \
  "select i.source || '|' || i.medications || '|' || (i.consent_at at time zone 'Asia/Manila')::date
   from public.patient_intakes i join public.patients pt on pt.id=i.patient_id
   where pt.chart_number='A-0001';" "import|Metformin|2024-05-06"
expect_eq "…the clinic note (an admin is a clinician)" \
  "select n.body from public.chart_notes n join public.patients pt on pt.id=n.patient_id
   where pt.chart_number='A-0001';" "Sensitive lower molars."
expect_eq "…and what they owed, as an issued bill" \
  "select v.status || '|' || v.balance from public.invoices v join public.patients pt on pt.id=v.patient_id
   where pt.chart_number='A-0001';" "issued|1500.50"
expect_eq "the same file again finds them by chart number and changes nothing twice" \
  "begin; $dtadmin select $(res "public.import_patients('$DENTAL', $IMPORT_ROWS, '$BATCH')");
   reset role;
   select count(*) from public.invoices v join public.patients pt on pt.id=v.patient_id
    where pt.chart_number='A-0001';
   select n.body from public.chart_notes n join public.patients pt on pt.id=n.patient_id
    where pt.chart_number='A-0001';
   rollback;" \
  $'updated,duplicate,duplicate,error\n1\nSensitive lower molars.'
expect_eq "an update fills in, and a blank cell blanks nothing" \
  "begin; $asst select $(res "public.import_patients('$DENTAL',
     '[{\"row\":2,\"chart_number\":\"a-0001\",\"person\":{\"address\":\"Pasig\"},
        \"intake\":{\"medications\":\"Metformin 500mg\"}}]', public.start_import('$DENTAL', 'patients', 't.csv'))");
   reset role;
   select pe.phone || '|' || pe.address || '|' || i.medications || '|' || array_to_string(i.allergies, ',')
     from public.patients pt join public.persons pe on pe.id=pt.person_id
     join public.patient_intakes i on i.patient_id=pt.id where pt.chart_number='A-0001';
   rollback;" $'updated\n0917 555 0301|Pasig|Metformin 500mg|latex'
expect_eq "a duplicate, once decided, updates the patient already here" \
  "begin; $asst select $(res "public.import_patients('$DENTAL',
     '[{\"row\":4,\"action\":\"update\",\"match_id\":\"$PT_MARIA\",\"chart_number\":\"M-7\",
        \"person\":{\"full_name\":\"maria reyes\"}}]', public.start_import('$DENTAL', 'patients', 't.csv'))");
   reset role; select chart_number from public.patients where id='$PT_MARIA'; rollback;" $'updated\nM-7'
expect_eq "…or is added as someone new" \
  "begin; $asst select $(res "public.import_patients('$DENTAL',
     '[{\"row\":4,\"action\":\"create\",\"person\":{\"full_name\":\"Maria Reyes\",\"phone\":\"09281234567\"}}]', public.start_import('$DENTAL', 'patients', 't.csv'))");
   rollback;" "created"
expect_eq "…and cannot update a chart at another clinic" \
  "$asst select e->>'message' from jsonb_array_elements(public.import_patients('$DENTAL',
     '[{\"row\":9,\"action\":\"update\",\"match_id\":\"$PT_MARIA_BRIGHT\",\"person\":{}}]')) e;" \
  "The patient to update is not at this clinic."
expect_eq "an exported id from another clinic is refused" \
  "$asst select e->>'result' from jsonb_array_elements(public.import_patients('$DENTAL',
     '[{\"row\":9,\"patient_id\":\"$PT_MARIA_BRIGHT\",\"person\":{\"full_name\":\"X\"}}]')) e;" "error"
expect_eq "a chart number is one patient's" \
  "$asst select e->>'message' from jsonb_array_elements(public.import_patients('$DENTAL',
     '[{\"row\":9,\"action\":\"create\",\"chart_number\":\"A-0001\",\"person\":{\"full_name\":\"Someone Else\"}}]')) e;" \
  "That chart number is already used by another patient here."
expect_eq "a form needs who signed it" \
  "$asst select e->>'message' from jsonb_array_elements(public.import_patients('$DENTAL',
     '[{\"row\":9,\"person\":{\"full_name\":\"Unsigned Form\"},\"intake\":{\"under_treatment\":false,\"takes_medications\":false}}]')) e;" \
  'The form has no "Signed by": give the name it was signed with.'
expect_err "nobody writes batches by hand" \
  "$dtadmin insert into public.import_records values ('$BATCH', 'patients', '$PT_MARIA', 'created');"
expect_eq "the front desk sees the clinic's imports" \
  "$asst select count(*) from public.import_batches where clinic_id='$DENTAL';" 1
expect_eq "…another clinic does not" "$bright select count(*) from public.import_batches;" 0

expect_eq "an export has every chart here, and only here" \
  "$asst select jsonb_array_length(public.export_patients('$DENTAL', 1000, 0));" \
  "$(trim "$(psql $CONN -c "select count(*) from public.patients where clinic_id='$DENTAL';")")"
expect_eq "…with the form and the chart number" \
  "$asst select e->>'chart_number' || '|' || (e->'intake'->>'medications') || '|' || (e->'intake'->>'signed_on')
   from jsonb_array_elements(public.export_patients('$DENTAL')) e where e->>'full_name'='Rosa Imported';" \
  "A-0001|Metformin|2024-05-06"
expect_eq "…the clinic note for an admin" \
  "$dtadmin select e->>'chart_note' from jsonb_array_elements(public.export_patients('$DENTAL')) e
   where e->>'full_name'='Rosa Imported';" "Sensitive lower molars."
expect_eq "…but never for the front desk" \
  "$asst select count(*) from jsonb_array_elements(public.export_patients('$DENTAL')) e
   where e->>'chart_note' is not null;" 0
expect_eq "…and what they owe" \
  "$asst select e->>'balance' from jsonb_array_elements(public.export_patients('$DENTAL')) e
   where e->>'full_name'='Rosa Imported';" "1500.50"
expect_eq "pages are by name and add up" \
  "$asst select sum(jsonb_array_length(public.export_patients('$DENTAL', 2, o)))
   from generate_series(0, 20, 2) o;" \
  "$(trim "$(psql $CONN -c "select count(*) from public.patients where clinic_id='$DENTAL';")")"
expect_err_msg "doctors do not export" "$doc select public.export_patients('$DENTAL');" "Only the front desk and admins"
expect_eq "every export is on record, once per file" \
  "select count(*) from public.data_exports where clinic_id='$DENTAL' and created_by='$DT_ADMIN_AUTH';" 1
expect_eq "…which admins can read" "$dtadmin select count(*) from public.data_exports;" \
  "$(trim "$(psql $CONN -c "select count(*) from public.data_exports where clinic_id='$DENTAL';")")"
expect_eq "…and the front desk cannot" "$asst select count(*) from public.data_exports;" 0

expect_err_msg "an import with a visit since cannot be undone" \
  "begin; insert into public.appointments (clinic_id, patient_id, doctor_id, service_name, scheduled_at)
   select '$DENTAL', pt.id, '$DR_SANTOS', 'Checkup', now() + interval '30 days'
     from public.patients pt where pt.chart_number='A-0001';
   $dtadmin select public.undo_import('$BATCH'); rollback;" "1 of the patients this import added"
expect_err_msg "the front desk cannot undo an admin's import" \
  "$asst select public.undo_import('$BATCH');" "Only an admin or whoever ran"
expect_eq "undo removes what it added: patients, people, the opening bill" \
  "$dtadmin select public.undo_import('$BATCH')->>'removed'; reset role;
   select count(*) from public.persons where full_name like '%Imported%';
   select count(*) from public.invoices where notes = 'Opening balance (imported)';" $'2\n0\n0'
expect_err_msg "…once" "$dtadmin select public.undo_import('$BATCH');" "already undone"
expect_err_msg "an undone batch takes no more rows" \
  "$dtadmin select public.import_patients('$DENTAL', '[]', '$BATCH');" "not yours"
psql $CONN -c "delete from public.import_batches where id='$BATCH'; delete from public.data_exports;" > /dev/null

print "\n── Visit and dental chart import / export ─────────────────────"
VISIT_ROWS="'[
  {\"row\":2,\"patient_id\":\"$PT_JUAN\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2023-01-10\",\"service\":\"teeth cleaning\"},
  {\"row\":3,\"patient_name\":\"maria reyes\",\"patient_phone\":\"0928 123 4567\",\"doctor_id\":\"$DR_SANTOS\",
   \"date\":\"2023-01-10\",\"service\":\"Old Denture Fitting\",\"duration_minutes\":\"60\",
   \"visit_note\":\"Upper denture relined.\",\"patient_note\":\"Soft food today.\"},
  {\"row\":4,\"patient_id\":\"$PT_JUAN\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2023-01-10\",\"service\":\"Teeth Cleaning\"},
  {\"row\":5,\"patient_id\":\"$PT_JUAN\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2031-01-06\"},
  {\"row\":6,\"patient_id\":\"$PT_JUAN\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2023-02-01\",\"status\":\"confirmed\"},
  {\"row\":7,\"patient_name\":\"Nobody Here\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2023-02-01\"},
  {\"row\":8,\"patient_id\":\"$PT_JUAN\",\"doctor_id\":\"$WALKIN\",\"date\":\"2023-02-01\"},
  {\"row\":9,\"patient_id\":\"$PT_JUAN\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2031-01-06\",\"time\":\"10:00\",\"service\":\"Dental X-Ray\"},
  {\"row\":10,\"patient_id\":\"$PT_MARIA\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2031-01-06\",\"time\":\"10:00\",\"service\":\"Dental X-Ray\"},
  {\"row\":11,\"patient_id\":\"$PT_MARIA\",\"doctor_id\":\"$DR_SANTOS\",\"date\":\"2023-03-01\",\"status\":\"no_show\"}
]'::jsonb"
msg() { print -r -- "(select e->>'message' from jsonb_array_elements($1) e where e->>'row' = '$2')" }

expect_eq "a visits dry run says what each row would do" \
  "$asst select $(res "public.import_visits('$DENTAL', $VISIT_ROWS)");" \
  "created,created,skipped,error,error,error,error,created,error,created"
expect_eq "…and writes nothing" \
  "select count(*) from public.appointments where imported or service_name = 'Old Denture Fitting';" 0
expect_eq "an upcoming visit needs a time" \
  "$asst select $(msg "public.import_visits('$DENTAL', $VISIT_ROWS)" 5);" "An upcoming visit needs a time."
expect_eq "a past visit is over" \
  "$asst select $(msg "public.import_visits('$DENTAL', $VISIT_ROWS)" 6);" \
  "A past visit is Completed, Cancelled or No-show, not confirmed."
expect_eq "a patient who is not here is named" \
  "$asst select $(msg "public.import_visits('$DENTAL', $VISIT_ROWS)" 7);" \
  "No patient here matches Nobody Here. Import the patients first."
expect_eq "a doctor must be on this clinic's roster" \
  "$asst select $(msg "public.import_visits('$DENTAL', $VISIT_ROWS)" 8);" \
  "Match this row's doctor to one on the roster."
expect_eq "upcoming visits are bookings: the doctor cannot be in two places" \
  "$asst select $(msg "public.import_visits('$DENTAL', $VISIT_ROWS)" 10);" \
  "This doctor already has a visit at that time. Pick another time."
expect_eq "the front desk's visit notes are left out, with a warning" \
  "$asst select e->'warnings'->>0 from jsonb_array_elements(public.import_visits('$DENTAL', $VISIT_ROWS)) e
   where e->>'row' = '3';" "Visit notes were left out: only doctors and admins can add them."
expect_err_msg "doctors do not import visits" \
  "$doc select public.import_visits('$DENTAL', $VISIT_ROWS);" "Only the front desk and admins"
expect_err_msg "a patients batch takes no visits" \
  "begin; $dtadmin select public.import_visits('$DENTAL', '[]',
     public.start_import('$DENTAL', 'patients', 'x.csv')); rollback;" "not yours"

psql $CONN -c "$dtadmin select public.start_import('$DENTAL', 'visits', 'visits.csv');" > /dev/null
VBATCH=$(trim "$(psql $CONN -c "select id from public.import_batches where file_name='visits.csv';")")
VOUT=$(trim "$(psql $CONN -c "$dtadmin select $(res "public.import_visits('$DENTAL', $VISIT_ROWS, '$VBATCH')");")")
expect_eq "an admin imports the visits" "select '$VOUT';" \
  "created,created,skipped,error,error,error,error,created,error,created"
expect_eq "past visits are history: completed at 09:00 Manila, the same doctor twice at once" \
  "select count(*) || '|' || bool_and(imported) || '|' || min(to_char(scheduled_at at time zone 'Asia/Manila', 'HH24:MI'))
          || '|' || bool_and(completed_at = ends_at)
   from public.appointments where (scheduled_at at time zone 'Asia/Manila')::date = '2023-01-10';" \
  "2|true|09:00|true"
expect_eq "…with the service matched, or kept as typed with its length" \
  "select string_agg(service_name || ':' || (service_id is not null) || ':' || duration_minutes, ',' order by service_name)
   from public.appointments where (scheduled_at at time zone 'Asia/Manila')::date = '2023-01-10';" \
  "Old Denture Fitting:false:60,Teeth Cleaning:true:45"
expect_eq "…and an admin's notes" \
  "select n.body || '|' || a.patient_note from public.appointments a join public.visit_notes n on n.appointment_id = a.id
   where a.service_name = 'Old Denture Fitting';" "Upper denture relined.|Soft food today."
expect_eq "a past no-show is history too" \
  "select status || '|' || imported from public.appointments where patient_id='$PT_MARIA'
   and (scheduled_at at time zone 'Asia/Manila')::date = '2023-03-01';" "no_show|true"
expect_eq "an upcoming visit is an ordinary booking" \
  "select status || '|' || imported from public.appointments where patient_id='$PT_JUAN'
   and (scheduled_at at time zone 'Asia/Manila')::date = '2031-01-06';" "confirmed|false"
expect_eq "the same file again adds nothing" \
  "begin; $dtadmin select $(res "public.import_visits('$DENTAL', $VISIT_ROWS, '$VBATCH')"); rollback;" \
  "skipped,skipped,skipped,error,error,error,error,skipped,error,skipped"
expect_err_msg "only an import marks history" \
  "$asst insert into public.appointments (clinic_id, patient_id, doctor_id, service_name, scheduled_at, imported)
   values ('$DENTAL', '$PT_JUAN', '$DR_SANTOS', 'X', now() - interval '400 days', true);" "Only an import"
expect_err_msg "…and it cannot be switched on later" \
  "$dtadmin update public.appointments set imported = true where id = '$A2';" "Only an import"

expect_eq "a visits export has every visit here" \
  "$asst select jsonb_array_length(public.export_visits('$DENTAL', 1000, 0));" \
  "$(trim "$(psql $CONN -c "select count(*) from public.appointments where clinic_id='$DENTAL';")")"
expect_eq "…with doctor, time and the admin's notes" \
  "$dtadmin select e->>'doctor' || '|' || (e->>'time') || '|' || (e->>'visit_note')
   from jsonb_array_elements(public.export_visits('$DENTAL', 1000, 0)) e where e->>'service' = 'Old Denture Fitting';" \
  "Maria Santos|09:00|Upper denture relined."
expect_eq "…and no visit notes for the front desk" \
  "$asst select count(*) from jsonb_array_elements(public.export_visits('$DENTAL', 1000, 0)) e
   where e->>'visit_note' is not null;" 0

DENTAL_ROWS="'[
  {\"row\":2,\"patient_id\":\"$PT_JUAN\",\"tooth\":16,\"surfaces\":[\"O\",\"M\"],\"code\":\"filling\",\"status\":\"done\",\"date\":\"2023-01-10\",\"note\":\" Composite \"},
  {\"row\":3,\"patient_id\":\"$PT_JUAN\",\"tooth\":36,\"code\":\"extraction\",\"status\":\"done\"},
  {\"row\":4,\"patient_id\":\"$PT_JUAN\",\"tooth\":19,\"code\":\"filling\"},
  {\"row\":5,\"patient_id\":\"$PT_JUAN\",\"tooth\":26,\"surfaces\":[\"D\"],\"code\":\"caries\",\"status\":\"planned\"},
  {\"row\":6,\"patient_id\":\"$PT_JUAN\",\"tooth\":16,\"surfaces\":[\"M\",\"O\"],\"code\":\"filling\",\"date\":\"2023-01-10\"},
  {\"row\":7,\"patient_id\":\"$PT_JUAN\",\"tooth\":46,\"code\":\"crown\",\"surfaces\":[\"O\"]}
]'::jsonb"
expect_err_msg "the front desk does not import dental charts" \
  "$asst select public.import_dental('$DENTAL', $DENTAL_ROWS);" "Only doctors and admins"
expect_err_msg "…nor start one" \
  "$asst select public.start_import('$DENTAL', 'dental', 'x.csv');" "Only doctors and admins"
expect_eq "a dental dry run: done at the visit that day, a repeat skipped, a bad tooth refused" \
  "$dtadmin select $(res "public.import_dental('$DENTAL', $DENTAL_ROWS)");" \
  "created,created,error,created,skipped,created"
expect_eq "work with no visit to point at is recorded as already there" \
  "$dtadmin select e->'warnings'->>0 from jsonb_array_elements(public.import_dental('$DENTAL', $DENTAL_ROWS)) e
   where e->>'row' = '3';" "No date, so no visit to record it at: recorded as work already there."

psql $CONN -c "$dtadmin select public.start_import('$DENTAL', 'dental', 'chart.csv');" > /dev/null
DBATCH=$(trim "$(psql $CONN -c "select id from public.import_batches where file_name='chart.csv';")")
psql $CONN -c "$dtadmin select public.import_dental('$DENTAL', $DENTAL_ROWS, '$DBATCH');" > /dev/null
expect_eq "the filling is done at the imported visit, dated that day" \
  "select e.status || '|' || array_to_string(e.surfaces, '') || '|' || e.note || '|' || a.service_name
          || '|' || (e.created_at at time zone 'Asia/Manila')::date
   from public.dental_chart_entries e join public.appointments a on a.id = e.appointment_id
   where e.patient_id='$PT_JUAN' and e.tooth=16 and e.code='filling';" \
  "done|MO|Composite|Teeth Cleaning|2023-01-10"
expect_eq "an extraction with no visit is a missing tooth; a planned decay is a finding; a crown has no surfaces" \
  "select string_agg(tooth || ':' || code || ':' || status || ':' || array_to_string(surfaces, ''), ',' order by tooth)
   from public.dental_chart_entries where patient_id='$PT_JUAN' and tooth in (26, 36, 46)
     and created_by = '$DT_ADMIN_AUTH';" \
  "26:caries:existing:D,36:missing:existing:,46:crown:existing:"
expect_eq "the front desk exports the chart" \
  "$asst select count(*) from jsonb_array_elements(public.export_dental('$DENTAL', 1000, 0)) e
   where e->>'patient_id' = '$PT_JUAN' and e->>'tooth' = '16' and e->>'surfaces' = 'MO' and e->>'date' = '2023-01-10';" 1

expect_err_msg "a visit charted since cannot be undone" \
  "$dtadmin select public.undo_import('$VBATCH');" "changed, billed or charted since"
expect_err_msg "a chart entry changed since cannot be undone" \
  "begin; update public.dental_chart_entries set note = 'edited' where note = 'Composite';
   $dtadmin select public.undo_import('$DBATCH'); rollback;" "changed since"
expect_eq "undo takes the chart entries back" \
  "$dtadmin select public.undo_import('$DBATCH')->>'removed';" 4
expect_eq "…and then the visits, notes and all" \
  "$dtadmin select public.undo_import('$VBATCH')->>'removed'; reset role;
   select count(*) from public.appointments where imported or service_name = 'Old Denture Fitting';
   select count(*) from public.visit_notes where body = 'Upper denture relined.';" $'4\n0\n0'

expect_eq "the patient list finds a chart by its number" \
  "begin; update public.patients set chart_number = 'DT-0042' where id = '$PT_MARIA';
   $asst select jsonb_array_length(r->'patients') || '|' || (r->'patients'->0->>'chart_number')
   from public.search_patients('$DENTAL', 'dt-0042') r; rollback;" "1|DT-0042"
psql $CONN -c "delete from public.import_batches where id in ('$VBATCH', '$DBATCH'); delete from public.data_exports;" > /dev/null

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
