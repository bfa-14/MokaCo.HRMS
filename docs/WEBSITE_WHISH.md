# Whish on the website (mokanco-lb): what to build

The HRMS API already does the whole Whish payment. The website only has to **offer the choice, ask for a Whish
payment, and send the guest to Whish's page**. Everything after that (asking Whish what happened, confirming the
booking, the e-mails, bringing the guest back) is the API's, exactly as for the card.

Written from the API's code (`MokaCo.HRMS.API/Controllers/PublicBookingController.cs`). The website's own files were
not seen when this was written: the file names below are where the HRMS notes say the booking calls live
(`src/scripts/api.ts`, the reservations wizard, `/pay/`), so check them against the real code.

## The flow

```
1. GET  /api/public/booking/catalog            -> rules.depositMethods, e.g. ["card", "whish"]
2. POST /api/public/booking                    -> the booking (Pending), its ref, its deposit      (unchanged)
3. POST /api/public/booking/{ref}/pay          body { "method": "whish" }
        200 { method: "whish", collectUrl, ref, deposit, currency, holdExpiresUtc, expiresAt, linkMinutes }
4. window.location.assign(collectUrl)          -> Whish's own page (QR code + six-digit code)
5. Whish sends the guest back to the API, the API asks Whish and redirects to the SAME three pages as the card:
        paid         {site}/reservations/confirmed/?ref={ref}
        not paid     {site}/reservations/?payment=failed
        cannot tell  {site}/reservations/?payment=unconfirmed&ref={ref}
```

## What to change on the website

1. **Offer Whish only when the API says so.** Read `rules.depositMethods` from the catalogue (it is already fetched for
   the wizard). Show the choice "Card" / "Whish" on the payment step only when the list contains `"whish"`. A list
   without it, or no such field at all (an older API), means card only: change nothing for the guest.
   The catalogue is cached for a minute, so the choice may appear a minute after it is switched on in HRMS.
2. **Send the method with the existing pay call.** Same URL, same headers as today, plus a JSON body:
   `POST /api/public/booking/{ref}/pay` with `Content-Type: application/json` and `{ "method": "whish" }`.
   For the card keep sending what is sent today (no body, or `{ "method": "card" }`): its answer is unchanged
   (`sessionId`, then `/pay/#session=`).
3. **Redirect to `collectUrl`.** A plain top-level navigation (`window.location.assign(collectUrl)`). Do not put it in
   an iframe and do not open it with `fetch`. No change to the site's Content-Security-Policy is needed for a
   navigation. The `/pay/` page is NOT used for Whish.
4. **Nothing to build for the way back.** The three pages above already exist for the card and are reused as they are.
   The confirmed page reads the booking by its reference, as today.
5. **Say the two Whish facts on the payment step** (short text under the choice):
   - "You will pay on Whish's page with the Whish app (scan the code or type the six-digit code)."
   - "The Whish page stays open for 5 minutes." (`linkMinutes` in the answer says how long.)

## Refusals of the pay call (same shape as the card: `{ error, code }`)

| HTTP | code | What the site does |
|---|---|---|
| 400 | `invalid_input` | the method was not `card` or `whish`: a bug on our side |
| 404 | `not_found` | no such booking |
| 409 | `already_paid` | go to the confirmed page |
| 409 | `payment_unconfirmed` | an earlier Whish page of this booking can still be paid (up to about 6 minutes): show `error` as it is and do NOT open another payment |
| 409 | `not_pending` / `hold_expired` / `nothing_due` | as for the card today |
| 502 | `gateway_error` | Whish did not open the payment, or Whish is switched off: show `error`, offer the card or WhatsApp |
| 503 | `paused` | bookings are paused |

`error` is a sentence written for the guest; show it as it stands.

## A booking that is not paid is not a booking (HRMS script 121)

While deposits are on, the booking the site creates is only **held** for the payment: the API gives it a time limit
(`BookingHoldMinutes`, 15) from the moment it exists, tells nobody about it, and releases it by itself when it is not
paid. Nothing for the site to build, with one courtesy worth adding:

- when the guest **gives up** before a payment page opened (they close the payment choice, or `/pay` answered an error
  and they do not retry), call `POST /api/public/booking/{ref}/release`. The slot is free again at once instead of
  after the hold. The answer carries the status, as for the card's cancel today.
- do not tell the guest "your request was received" after create while `depositRequired` is true: say it only on the
  confirmed page. The guest gets no e-mail until the payment goes through.

## Trying it

- Whish must be offered by the API: in HRMS, Settings > Payment gateways holds the Whish keys (test or live), and on
  the same tab, under "What guests can do on the website", both switches must be on: "Take the deposit online"
  (`BookingDepositRequired`) and "Offer Whish on the website" (`BookingWhishEnabled`). Until then `depositMethods`
  does not contain `"whish"` and the site shows the card only. On the live system HRMS refuses those switches while
  the gateway is in test mode; try the test keys on the test side.
- With the **test** keys, Whish's page shows two buttons, **Simulate Success** and **Simulate Failure**; press one
  instead of paying. The real Whish app answers "invalid QR code" to a test payment: that is expected.
- After Simulate Success the guest lands on the confirmed page, and HRMS shows the payment under Bookings > Payments.
- After Simulate Failure the guest lands on `?payment=unconfirmed` until the Whish page's five minutes are over (Whish
  itself still calls the payment "pending" until then); pressing pay again after that opens a new payment.

## A prompt to start this work in a session that has the website's code

> Add Whish as a second way to pay the booking deposit on this website. The API is done; follow
> `docs/WEBSITE_WHISH.md` of the repository `bfa-14/MokaCo.HRMS` (branch `dev`). In short: on the payment step show a
> "Card / Whish" choice only when the booking catalogue's `rules.depositMethods` contains `"whish"`; for Whish call the
> existing `POST /api/public/booking/{ref}/pay` with the JSON body `{ "method": "whish" }` and navigate the browser to
> the `collectUrl` of the answer; the return pages (`/reservations/confirmed/`, `?payment=failed`,
> `?payment=unconfirmed`) are the card's and stay as they are. Keep the card flow exactly as it works today. Handle
> the refusal codes in the document, in English and Arabic like the rest of the wizard. Find the existing card
> payment code first and build beside it; do not change the API.
