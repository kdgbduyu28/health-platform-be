// deno test supabase/functions/calendar-feed/ics_test.ts
// (or, without Deno: node --experimental-strip-types on Node 22.6+)
import assert from "node:assert/strict";
import { test } from "node:test";
import { feedCalendar, fold, icsText, icsTime } from "./ics.ts";

const visit = {
  appointment_id: "40000000-0000-0000-0000-000000000002",
  status: "confirmed",
  scheduled_at: "2026-09-29T01:00:00+00:00",
  ends_at: "2026-09-29T01:30:00+00:00",
  updated_at: "2026-09-22T08:00:00.123+00:00",
  clinic_name: "D-Touch Dental Clinic",
  clinic_address: "12 Rizal St., Quezon City",
  clinic_phone: "+63 2 8123 4567",
  clinic_slug: "dtouchdental",
  doctor_name: "Maria Santos",
};

test("times are UTC basic format", () => {
  assert.equal(icsTime("2026-09-29T09:00:00+08:00"), "20260929T010000Z");
});

test("text is escaped", () => {
  assert.equal(icsText("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne");
});

test("long lines fold at 75 octets, multi-byte safe", () => {
  const line = "DESCRIPTION:" + "₱".repeat(40);
  const folded = fold(line);
  for (const part of folded.split("\r\n")) {
    assert.ok(new TextEncoder().encode(part).length <= 75, part);
  }
  assert.equal(folded.replace(/\r\n /g, ""), line);
});

test("a confirmed visit", () => {
  const ics = feedCalendar([visit], {
    now: new Date("2026-09-22T00:00:00Z"),
    appUrl: "https://patients.example.com/",
  });
  assert.ok(ics.startsWith("BEGIN:VCALENDAR\r\n"));
  assert.ok(ics.endsWith("END:VCALENDAR\r\n"));
  assert.match(ics, /\r\nUID:40000000-0000-0000-0000-000000000002@health-platform\r\n/);
  assert.match(ics, /\r\nDTSTART:20260929T010000Z\r\nDTEND:20260929T013000Z\r\n/);
  assert.match(ics, /\r\nSUMMARY:Visit at D-Touch Dental Clinic\r\n/);
  assert.match(ics, /\r\nSTATUS:CONFIRMED\r\n/);
  assert.match(ics, /\r\nLOCATION:12 Rizal St.\\, Quezon City\r\n/);
  assert.match(ics, /\r\nURL:https:\/\/patients.example.com\/dtouchdental\/appointments\/40000000/);
  assert.ok(!/\n[^ ][^\r]{75,}\r/.test(ics), "no unfolded long line");
});

test("a requested visit is tentative", () => {
  const ics = feedCalendar([{ ...visit, status: "pending" }]);
  assert.match(ics, /\r\nSUMMARY:Requested: Visit at D-Touch Dental Clinic\r\n/);
  assert.match(ics, /\r\nSTATUS:TENTATIVE\r\n/);
  assert.ok(!ics.includes("URL:"), "no app link without PATIENT_APP_URL");
});

test("a later change has a higher SEQUENCE", () => {
  const seq = (updated_at: string) =>
    Number(/SEQUENCE:(\d+)/.exec(feedCalendar([{ ...visit, updated_at }]))![1]);
  assert.ok(seq("2026-09-23T00:00:00Z") > seq("2026-09-22T00:00:00Z"));
});

test("an empty feed is still a calendar", () => {
  assert.equal((feedCalendar([]).match(/BEGIN:VEVENT/g) ?? []).length, 0);
  assert.ok(feedCalendar([]).includes("X-WR-CALNAME:Clinic visits"));
});
