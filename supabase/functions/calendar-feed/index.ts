// Serves a patient's visits as an iCalendar feed that Google Calendar, Apple
// Calendar and Outlook subscribe to:
//
//   GET /functions/v1/calendar-feed?token=<64 hex>
//
// A calendar app cannot sign in, so the token in the URL is the credential
// (public.calendar_feeds; the patient gets and resets it in the app). It is
// deployed with --no-verify-jwt for the same reason, and reads with the
// service role, which the Edge runtime provides.
//
// Optional secret (supabase secrets set …):
//   PATIENT_APP_URL   the patient app's address, e.g. https://patients.example.com.
//                     Each event then links to the visit in the app.
import { createClient } from "npm:@supabase/supabase-js@2";
import { type FeedVisit, feedCalendar } from "./ics.ts";

const env = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing secret ${name}`);
  return value;
};

const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

const appUrl = Deno.env.get("PATIENT_APP_URL") || undefined;

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method not allowed", { status: 405 });
  }

  const token = new URL(req.url).searchParams.get("token") ?? "";
  // Checked here too, so a malformed URL never reaches the database.
  if (!/^[0-9a-f]{64}$/.test(token)) return new Response("not found", { status: 404 });

  const { data, error } = await db.rpc("calendar_feed_events", { p_token: token });
  if (error) {
    // no_data_found: the token was reset, or never existed.
    if (error.code === "P0002") return new Response("not found", { status: 404 });
    console.error("calendar feed failed", error.message);
    return new Response("unavailable", { status: 503 });
  }

  return new Response(
    req.method === "HEAD" ? null : feedCalendar(data as FeedVisit[], { appUrl }),
    {
      headers: {
        "Content-Type": "text/calendar; charset=utf-8",
        "Content-Disposition": 'inline; filename="clinic-visits.ics"',
        // The URL is a credential: no shared caches.
        "Cache-Control": "private, max-age=300",
        "Referrer-Policy": "no-referrer",
      },
    },
  );
});
