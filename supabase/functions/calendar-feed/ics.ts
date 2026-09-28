// iCalendar (RFC 5545) for the calendar feed. No Deno or Supabase imports,
// so it can be checked on its own (ics_test.ts).

export type FeedVisit = {
  appointment_id: string;
  status: string;
  scheduled_at: string;
  ends_at: string;
  updated_at: string;
  clinic_name: string;
  clinic_address: string | null;
  clinic_phone: string | null;
  clinic_slug: string;
  doctor_name: string;
};

/** 20260929T010000Z: UTC, so no VTIMEZONE block is needed. */
export function icsTime(iso: string): string {
  return new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

/** TEXT escaping: backslash, semicolon, comma, newline. */
export function icsText(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

/** Lines longer than 75 octets continue on the next, indented by a space. */
export function fold(line: string): string {
  const bytes = new TextEncoder().encode(line);
  if (bytes.length <= 75) return line;
  const out: string[] = [];
  let chunk = "";
  let size = 0;
  for (const ch of line) {
    const n = new TextEncoder().encode(ch).length;
    // The first line holds 75 octets; each continuation, after its space, 74.
    if (size + n > (out.length === 0 ? 75 : 74)) {
      out.push(chunk);
      chunk = "";
      size = 0;
    }
    chunk += ch;
    size += n;
  }
  out.push(chunk);
  return out.join("\r\n ");
}

/**
 * The whole feed. Deliberately thin: clinic, doctor and time. The service
 * booked is left out, because a calendar is often shared with family or
 * work, and "Root canal" on it says more than the patient chose to share.
 */
export function feedCalendar(
  visits: FeedVisit[],
  opts: { now?: Date; appUrl?: string } = {},
): string {
  const stamp = icsTime((opts.now ?? new Date()).toISOString());
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//health-platform//calendar-feed//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:Clinic visits",
    // Hints only: Google ignores them and re-reads every few hours.
    "REFRESH-INTERVAL;VALUE=DURATION:PT1H",
    "X-PUBLISHED-TTL:PT1H",
  ];
  for (const v of visits) {
    const requested = v.status === "pending";
    const link = opts.appUrl
      ? `${opts.appUrl.replace(/\/$/, "")}/${v.clinic_slug}/appointments/${v.appointment_id}`
      : null;
    const description = [
      `With Dr. ${v.doctor_name}.`,
      requested ? "Requested: the clinic has not confirmed this time yet." : null,
      v.clinic_phone ? `Clinic: ${v.clinic_phone}` : null,
      link ? `Details: ${link}` : null,
    ].filter((l): l is string => l !== null).join("\n");

    lines.push(
      "BEGIN:VEVENT",
      `UID:${v.appointment_id}@health-platform`,
      `DTSTAMP:${stamp}`,
      // Rises whenever the visit changes, so clients replace their copy.
      `SEQUENCE:${Math.floor(new Date(v.updated_at).getTime() / 1000) - 1_700_000_000}`,
      `LAST-MODIFIED:${icsTime(v.updated_at)}`,
      `DTSTART:${icsTime(v.scheduled_at)}`,
      `DTEND:${icsTime(v.ends_at)}`,
      `SUMMARY:${icsText((requested ? "Requested: " : "") + "Visit at " + v.clinic_name)}`,
      `DESCRIPTION:${icsText(description)}`,
      `STATUS:${requested ? "TENTATIVE" : "CONFIRMED"}`,
      "TRANSP:OPAQUE",
    );
    if (v.clinic_address) lines.push(`LOCATION:${icsText(v.clinic_address)}`);
    if (link) lines.push(`URL:${link}`);
    lines.push("END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return lines.map(fold).join("\r\n") + "\r\n";
}
