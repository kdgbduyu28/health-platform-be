-- The steps of a visit between "confirmed" and "completed".
--
-- Until now the front desk's Check In set a visit to `completed` the moment
-- the patient walked in, so the doctor never had a waiting room to see. The
-- flow is now:
--
--   pending → confirmed → arrived → in_consultation → completed
--                 └──────────────────────┘
--   (a doctor may start straight from confirmed: small clinics often have
--   nobody at the desk)
--
-- plus `cancelled` (before the consultation) and `no_show` (a confirmed visit
-- whose time passed without the patient).
--
-- On its own because a new enum value cannot be used in the transaction that
-- adds it; 20260923120100 uses these in a constraint.

alter type public.appointment_status add value if not exists 'arrived'         after 'confirmed';
alter type public.appointment_status add value if not exists 'in_consultation' after 'arrived';
alter type public.appointment_status add value if not exists 'no_show'         after 'cancelled';
