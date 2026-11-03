# ADR 0014: What name the screen chrome shows

**Status:** Proposed
**Date:** 2026-11-03
**Decides:** the value of `Lakeraven::EHR.configuration.product_name`, and whether the header shows more than one name

## Context

Every engine page has a header (the top bar: a name, the main navigation, who is signed in, Sign out) and a `<title>`.
Both say "Lakeraven EHR" today.

The product owner's note: "i'm not sure if 'lakeraven' needs to be visible in daily app in such prime medical real-estate. tbd. maybe fine for scheduling, but not charting."

Facts that bear on it:

- **The screen is prime real estate.** A clinician's chart has a patient banner, allergies and orders competing for the top of the screen. A vendor name there tells the user nothing they need.
- **The workstation is shared.** At a front desk or a nursing station, the next person at the keyboard needs to see *where* this session is (which facility, which division) and *whose* it is (the signed-in user). The header already shows the user (`EngineLayoutTest`). It does not show the facility.
- **RPMS knows the facility.** A user signs on to a division (DUZ(2), an INSTITUTION entry; `XUS DIVISION GET` lists the ones they may use). The engine has a `SiteGateway` for this but does not keep the division in the session today.
- **The `<title>` is what a screen reader announces first and what a tab or taskbar shows.** "Book | Dental clinic | …" should end with something that tells the user which application this tab is, among several open.
- **The switch already exists.** `product_name` is one setting; the header and every `<title>` read it, and its default is "Lakeraven EHR" (front-desk components PR). This ADR decides only what it should say.

## Options

### A. Keep the vendor name everywhere (today)

"Lakeraven EHR" in the header and every title.

- For: no work; one name across sites; easy for support ("which app?").
- Against: the product owner's concern exactly. It spends header space on a name the user doesn't need, and says nothing about where the session is.

### B. The site's name from RPMS

The header shows the facility the user signed on to (the division's INSTITUTION name, from RPMS at sign-on). The `<title>` ends with it too.

- For: the most useful thing on a shared workstation after who is signed in. It comes from RPMS, so it's right per site with no configuration. It's the site's own name on its own screens.
- Against: needs the division kept at sign-on (the sign-on reply's DUZ(2), or `XUS DIVISION GET`) and refreshed if division switching lands (`SiteGateway.select` refuses today; see #541). A user who may sign on to two divisions needs to see which one, which is a feature, not a cost. A long institution name needs truncation in the header.

### C. A neutral product name

Something like "Front desk" or "EHR", set per deployment.

- For: no vendor name, no RPMS dependency; one setting.
- Against: still says nothing about the facility. A generic word in every title is noise.

### D. The vendor name only on sign-in and About

Sign-in, About and the documentation say "Lakeraven EHR". The daily screens don't.

- For: the vendor is credited where a user meets the product, and the daily screens stay clean.
- Against: on its own it leaves the header with nothing in the name slot. It needs B or C for the daily screens.

### E. Per area

Scheduling and registration show one name; the chart shows another or none.

- For: matches the note ("maybe fine for scheduling, but not charting").
- Against: two names for one application confuses support and users. The real difference between the areas is how much header space they can spare, which is a layout question, not a naming one.

## Recommendation

**B for the daily screens, with D for the vendor name.**

- The header's name slot shows the signed-in facility: the division the user signed on to, as RPMS names it. Next to it, as today, the signed-in user and Sign out.
- The `<title>` ends with the facility: "Book | Dental clinic | <facility>".
- Sign-in (before there is a facility) and an About page say "Lakeraven EHR". `product_name` keeps that value, and becomes the fallback when the facility isn't known.
- In the chart, the header stays one line, and the patient banner gets the space below it.

Why: on a shared workstation the facility and the signed-in user matter most, and on clinical screens every line counts. RPMS already knows the facility, so the name is right at every site with nothing to configure. The vendor is still named where a user first meets the product.

## Consequences

- Sign-on keeps the division (IEN and name) in the session, from RPMS's own answer. The header and `page_title` read it, falling back to `product_name`.
- A test signs on as a persona and finds the division's name in the header and the title, and "Lakeraven" in neither.
- Division switching (`SiteGateway.select`, which refuses today), when it lands, updates the session value, so the header follows.
- Nothing changes until this is accepted: `product_name` stays "Lakeraven EHR".

## Not decided here

- The About page's content.
- Whether a deployment may override the facility name (a shorter one, say). Start with RPMS's name; add a setting only if a site asks.
