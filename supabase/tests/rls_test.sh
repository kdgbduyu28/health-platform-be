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
