# Wiring online deposits on mokanco.com.lb

For Reda. The HRMS API now owns the server half of the deposit payment (Bank of Beirut MPGS hosted checkout). The website keeps the `/pay/` page, which opens the gateway's payment page. It no longer creates checkout sessions or verifies payments itself.

**Nothing changes for guests until `BookingDepositRequired` is switched on**, and that happens only after both sides are deployed (see [Switching it on](#switching-it-on)).

## The flow

```
wizard submit
  │  POST /api/public/booking                     (unchanged: create, answers 201 with ref, deposit, depositRequired)
  │
  ├─ depositRequired = false → /reservations/confirmed/?ref=MC-XXXXXXXX           (today's behaviour)
  │
  └─ depositRequired = true
       │  POST /api/public/booking/{ref}/pay       (no body; same Origin / X-Booking-Key as create)
       │  ← 200 { sessionId, ref, deposit, currency, holdExpiresUtc, expiresAt, timeZone }
       │
       │  location.href = '/pay/#session=' + sessionId
       │
       ▼
     /pay/ (pay.ts, unchanged) → Checkout.showPaymentPage() → the guest pays on the gateway's page
       │
       ▼  the gateway sends the browser to ONE of:
     returnUrl   https://api.mokanco.com.lb/api/public/booking/verify?ref=MC-…  (the API asks the gateway, then 302s:)
                   paid         → /reservations/confirmed/?ref=MC-…
                   failed       → /reservations/?payment=failed                  (the hold is already released)
                   anything else → /reservations/?payment=unconfirmed&ref=MC-…   (the hold is kept)
     cancelUrl   /reservations/?payment=cancelled
     timeoutUrl  /reservations/?payment=unconfirmed&ref=MC-…
```

### In `booking-wizard.ts` (the `depositRequired` branch around L857)

```ts
const created = await bookingApi.create({ ... });

if (!created.depositRequired) {
  location.href = `/reservations/confirmed/?ref=${encodeURIComponent(created.ref)}`;
  return;
}

// Keep the reference for the way back: cancelUrl does not carry it.
try { sessionStorage.setItem('mokaPayRef', created.ref); } catch { /* private mode */ }

const pay = await bookingApi.pay(created.ref);   // throws BookingApiError on a refusal, see the table below
location.href = `/pay/#session=${encodeURIComponent(pay.sessionId)}`;
```

In `api.ts`, beside `release`:

```ts
pay: (ref: string) =>
  apiPost<{ sessionId: string; ref: string; deposit: number; currency: string;
            holdExpiresUtc: string; expiresAt: string; timeZone: string }>(
    `/api/public/booking/${encodeURIComponent(ref)}/pay`,
  ),
```

`/pay` takes **no body**. It charges the booking's own deposit, the figure `create` and `quote` already showed. Nothing the browser sends can change the amount.

### The three return states on `/reservations/`

| `?payment=` | What happened | What the page says | What the page does |
|---|---|---|---|
| `failed` | The gateway said no. The API has already released the slot. | Today's text is right: "The payment didn't go through, so nothing was charged. Try again whenever you're ready." | Nothing. A retry is a new booking through the wizard. |
| `cancelled` | The guest pressed cancel on the gateway page. | Today's text is right. | Call `bookingApi.release(sessionStorage mokaPayRef)` so the slot is freed now rather than when the HRMS job gets to it, then clear the stored ref. Release is safe: it asks the gateway first and never frees a slot that might be paid. |
| **`unconfirmed`** (**new**) | The outcome is unknown: a timeout, or the gateway had not settled yet. **The guest may have been charged.** | Something like: "We couldn't confirm your payment yet. Please don't pay again. We'll confirm your booking by WhatsApp shortly. Your reference is MC-…" | **Never** say "nothing was charged". **Never** offer "try again" or re-open `/pay` (that risks a double charge). Optionally poll `GET /api/public/booking/{ref}` every 30 s, or watch the hub (`WatchBooking(ref)`, `BookingStatus`), and move to `/reservations/confirmed/?ref=` when `status` becomes `Confirmed`. The HRMS reconciliation job settles these within minutes. |

`pay.ts` needs no change. Its `mokaPayError` sends the guest to `?payment=failed`. That callback only fires when the checkout script cannot start, which is before any card is taken.

## What `/pay` can answer

Every refusal is `{ error, code }`. `error` is a sentence written for the guest, so show it as it is. `code` is for the code to branch on.

| HTTP | `code` | Meaning | Suggested handling |
|---|---|---|---|
| 200 | — | `{ sessionId, … }` | Go to `/pay/#session=…` |
| 404 | `not_found` | No booking with that ref | Show `error` |
| 409 | `not_pending` | The booking is no longer waiting for payment (confirmed or cancelled meanwhile) | Show `error`; offer the confirmed page for the ref |
| 409 | `hold_expired` | The 15-minute payment hold ran out | Show `error`; send the guest back to pick the slot again (`goto('2')` + `refreshAvailability()`) |
| 409 | `already_paid` | An earlier payment on this booking went through (the API has just recorded it) | Go to `/reservations/confirmed/?ref=` |
| 409 | `payment_unconfirmed` | An earlier attempt on this booking is still being confirmed | Treat exactly like `?payment=unconfirmed`. **Do not retry.** |
| 409 | `nothing_due` | The booking has no deposit to pay | Go to the confirmed page |
| 502 | `gateway_error` | The gateway did not open a session | Show `error` ("…Try again, or book over WhatsApp."); retrying `/pay` for the same ref is safe |
| 503 | `paused` | Online booking is paused | As for create |
| 401 | `unauthorized` | Origin not in `BookingCorsOrigins` and no key | Configuration problem |
| 429 | — | Rate limit (the same write tier as create: 5 per minute per IP) | Show a "try again in a minute" message |

**Calling `/pay` twice for the same ref is safe.** It opens a new session on the same gateway order. If the first session was paid, the second call answers `already_paid` and never opens a second checkout.

The hold: `/pay` holds the slot for `BookingHoldMinutes` (15). `expiresAt` in the answer is Beirut time with its offset, if you want a countdown. The HRMS keeps the hold while a payment is unconfirmed.

## What moves out of the website

Once this is wired, `functions/api/booking.js` and `functions/api/booking/verify.js` are dead code and a second payment path. Remove them, and remove `MPGS_*` from `.dev.vars` and the Pages or VM environment. The gateway credentials now live only in the HRMS (`/etc/mokaco/api.env`).

## Gateway host: three places, changed together at go-live

The test host is `https://test-bobsal.gateway.mastercard.com`. At go-live (production credentials, MOKANDCO, EMV 3DS2 enabled by the bank), change all three together:

1. HRMS `/etc/mokaco/api.env`: `MPGS_BASE`, `MPGS_MERCHANT_ID`, `MPGS_API_PASSWORD`.
2. `src/scripts/pay.ts`: `GATEWAY_BASE`.
3. The `/pay/` Content-Security-Policy: `public/_headers` **and the nginx vhost on the VM**, which carries the CSP now that the site is hosted there (script-src, connect-src, frame-src, img-src, form-action).

The 3DS bypass exists only on the TEST profile with a developer flag, and the API can never send it for MOKANDCO.

## Switching it on

1. HRMS: apply `docs/88_booking_online_deposit.sql`, add the `api.env` keys, and deploy the API. `BookingDepositRequired` stays `0`.
2. Website: deploy this wiring. With the setting at `0`, nothing changes for guests.
3. Test end to end against the TEST profile (`TESTMOKANDCO`, card 5123 4500 0000 0008, exp 01/39, CVC 100) on a staging origin, in a **headed** browser (the card iframes don't render headless). Cover a paid booking, a cancel, and a closed tab (the job settles it).
4. Only then set `BookingDepositRequired = 1` on the HRMS Settings page. The catalog's `rules.depositRequired` and create's `depositRequired` follow within a minute.
