// Sends one notification as Web Push to every browser its account has
// subscribed in the app it belongs to.
//
// Called by the database (private.push_notification, over pg_net) with
// { "notification_id": "…" } and the shared secret in x-push-secret. It
// is deployed with --no-verify-jwt because that secret, not a user's JWT,
// is what authorises it; it reads with the service role, which the Edge
// runtime provides.
//
// Secrets (supabase secrets set …):
//   PUSH_WEBHOOK_SECRET   the same value as the Vault secret push_webhook_secret
//   VAPID_PUBLIC_KEY      the key the apps subscribe with (SupabaseConfig)
//   VAPID_PRIVATE_KEY
//   VAPID_SUBJECT         mailto: address push services can contact
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const env = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing secret ${name}`);
  return value;
};

webpush.setVapidDetails(
  env("VAPID_SUBJECT"),
  env("VAPID_PUBLIC_KEY"),
  env("VAPID_PRIVATE_KEY"),
);

const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

/** Constant-time, so the secret cannot be guessed a byte at a time. */
function sameSecret(given: string | null, expected: string): boolean {
  if (given === null || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < given.length; i++) {
    diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!sameSecret(req.headers.get("x-push-secret"), env("PUSH_WEBHOOK_SECRET"))) {
    return new Response("unauthorized", { status: 401 });
  }

  let id: unknown;
  try {
    ({ notification_id: id } = await req.json());
  } catch {
    return new Response("bad request", { status: 400 });
  }
  if (typeof id !== "string") return new Response("bad request", { status: 400 });

  const { data: n, error } = await db
    .from("notifications")
    .select("id, profile_id, app, title, body, link, pushed_at")
    .eq("id", id)
    .maybeSingle();
  if (error) return new Response(error.message, { status: 500 });
  // Deleted, or already sent by an earlier attempt.
  if (!n || n.pushed_at) return Response.json({ sent: 0 });

  const { data: subs, error: subsError } = await db
    .from("push_subscriptions")
    .select("id, endpoint, p256dh, auth")
    .eq("profile_id", n.profile_id)
    .eq("app", n.app);
  if (subsError) return new Response(subsError.message, { status: 500 });

  // What push_sw.js in each app reads. `tag` makes a resend replace, not
  // duplicate, the notification on the device.
  const payload = JSON.stringify({ title: n.title, body: n.body, link: n.link, tag: n.id });

  let sent = 0;
  const gone: string[] = [];
  const used: string[] = [];
  await Promise.all(
    (subs ?? []).map(async (s) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          payload,
          // A day-old "you are next" is worse than none.
          { TTL: 60 * 60 * 12, urgency: "high" },
        );
        sent++;
        used.push(s.id);
      } catch (e) {
        const status = (e as { statusCode?: number }).statusCode;
        // The browser unsubscribed, or the subscription expired.
        if (status === 404 || status === 410) gone.push(s.id);
        else console.error(`push to ${new URL(s.endpoint).host} failed`, status ?? e);
      }
    }),
  );

  const now = new Date().toISOString();
  await Promise.all([
    gone.length ? db.from("push_subscriptions").delete().in("id", gone) : null,
    used.length ? db.from("push_subscriptions").update({ last_used_at: now }).in("id", used) : null,
    db.from("notifications").update({ pushed_at: now }).eq("id", n.id),
  ]);

  return Response.json({ sent, removed: gone.length });
});
