# ADR 0019: Agent platforms read RPMS through one MCP surface, and a hosted model runs only in the partner's own cloud project

**Status:** Accepted on 25 Nov 2026, by the owner's decision, with the instruction to be strict about data sovereignty and loosen only when a later ADR shows the need. ADR 0016 and 0017 are still proposed; this ADR applies their deny-by-default rules to agent and model paths now.
**Date:** 2026-11-25
**Decides:** how an outside agent platform (Gemini for healthcare first) reads RPMS data through this engine; whether a hosted model such as Gemini may sit behind the ADR 0015 `Suggestions` port; and what has to exist before a connector is listed in a vendor catalog
**Builds on:** ADR 0016 (Indigenous data governance: deny by default, approvals are records, revocation stops the next transfer, no secondary use), ADR 0005 (PHI access audit), ADR 0006 (Part 2 posture), ADR 0010 (authorization derives from RPMS options and keys), ADR 0011 (a broker session is the only way to RPMS), ADR 0012 (every request carries identity and scope), ADR 0013 (a tenant is one RPMS instance), ADR 0015 (assistive AI behind one adapter)
**Issues:** #1234 (read-only MCP surface), #546 (external MCP client validation)

## Context

Agent platforms now reach clinical data through MCP connectors layered on FHIR. Gemini for
healthcare (Google Cloud, US preview, for Gemini Enterprise customers) is the first such platform
to ship one for healthcare:

- It has read-only connectors for two large commercial EHRs and an InterSystems FHIR MCP
  server. It has none for RPMS.
- Gemini Enterprise reaches a custom remote MCP server over streamable HTTP. It authenticates with
  OAuth 2.0 on behalf of the signed-in user (authorization URL, token URL, client id and secret,
  scopes, optional PKCE). An administrator registers the server in Google's Agent Registry. Traffic
  can egress through Agent Gateway to a private endpoint, but the endpoint needs a publicly trusted
  certificate.
- Partner agents are listed in Google Cloud Marketplace as A2A agents. The listing rests on an
  Agent Card and a validation designation for Gemini Enterprise. MCP servers reach customers
  through the platform's partner connector ecosystem, which goes through Google's partner team,
  not through a self-serve listing.

The owner wants Lakeraven to integrate with it. Three separate things get called "integration":

1. **Gemini reads RPMS** through this engine, so a clinic or plan that runs Gemini Enterprise
   gets RPMS data in it.
2. **Gemini as a model** behind the ADR 0015 `Suggestions` port.
3. **A catalog listing** so customers find the RPMS connector.

Binding constraints:

- Core logic stays in house; commodity functions sit behind pluggable adapters; no vendor
  coupling. Whatever we build for Gemini must work unchanged for any MCP client.
- Patient data stays under the partner's control (ADR 0015). Gemini Enterprise runs in the
  *customer's* Google tenancy under the customer's own agreement with Google. So pointing it at
  RPMS is the partner's disclosure decision, made by the partner and switchable by the partner.
- Absence of data is never verification. A failed consent or authorization check returns nothing
  sensitive and says it could not determine, not that the answer is no.

## Decision

### 0. The strict default

Every path in this ADR moves data out of the tenant: to an agent platform, or to a hosted model. ADR 0016 treats both as egress. The rule for all of them is the same:

- **Refuse when anything is missing, unknown or cannot be checked.** That covers a switch, an approval record, a scope, a consent, a condition of decision 4 or a harness result. The refusal says the service *could not determine* that the path is allowed. It never says the path is denied on the merits, and it never falls back to a looser path.
- **The tenant's governing body authorizes the path, not only its IT administrator.** Enabling agent access or a hosted model needs an active ADR 0016 approval record. The record names:
  - the approving body;
  - the recipient (the agent client or the model project);
  - the resource types;
  - the purpose;
  - an expiry.
  Revoking it stops the next call (ADR 0016 rule 6).
- **Collective approval and patient consent are both needed.** Neither overrides the other (ADR 0016 rule 4).
- **No secondary use.** A recipient may not train on, pool or retain tenant data beyond the purpose in the approval (ADR 0016 rule 10). We record the recipient's attestation, and a missing attestation is a refusal.
- **Until the ADR 0016 approval contract exists in code, every path here runs on synthetic data only.** No real tenant can be switched on before then.
- **A tenant whose `part2_program` is true gets no agent or hosted-model path** until labelling and disclosure accounting exist (ADR 0006).

Loosening any of these needs a later ADR, not a configuration change.

### 1. One vendor-neutral MCP surface on the FHIR service

The FHIR service (OpenRPMS layer C when it is extracted, this engine until then) exposes a
read-only MCP surface (#1234). It is a thin adapter over the FHIR read and search paths and adds
no data path of its own:

- **Tools:** `capabilities`, `read` and `search` over the readable resource types in the
  CapabilityStatement. No write tools. A write surface needs its own ADR.
- **Transport:** streamable HTTP. No other transport is offered.
- **Same authorization, same filters, same audit** as REST. Every tool call goes through the
  engine's SMART token checks (ADR 0012), the ADR 0006 Part 2 and consent filters, and the
  ADR 0005 audit. An AuditEvent names the agent client and the delegating user.
- Nothing in the surface names a vendor. Gemini is one client.

### 2. Per-user delegation is the default; system access is the exception

An agent acting for a clinician reads RPMS **as that clinician**:

- The agent platform is registered as a confidential SMART client. It uses the existing
  authorization-code flow with PKCE (S256, already required) and `user/` scopes.
- The user signs on with their RPMS credentials. The broker session runs as their DUZ
  (ADR 0011). RPMS options and security keys limit what they can read (ADR 0010), exactly as in
  the EHR UI. The agent can never see more than the user can.
- `system/` scopes over SMART Backend Services (#1080) stay available for batch or population
  use. A tenant must enable them separately for an agent client. They are not part of the Gemini
  setup.

### 3. The partner switches it on, per tenant, and it fails closed

Agent access is off by default for each tenant (ADR 0013). It is enabled per client application,
and only while an active ADR 0016 approval covers that client (decision 0). The approval can
limit the client to fewer resource types than the user could read. Disabling the switch, or the
approval expiring or being revoked, ends that client's tokens. If the switch or the approval
cannot be read, access is treated as off.

### 4. Gemini (and any hosted model) behind `Suggestions` only from the partner's own cloud project

This amends ADR 0015 decision 3, which today allows a hosted-model adapter only for synthetic
data in development.

- A hosted-model adapter (Vertex AI Gemini first) may receive real patient inputs **only when
  all of the following hold**:
  - the model endpoint runs in a cloud project the partner owns and controls;
  - that project is under the partner's own BAA with the cloud provider;
  - the provider does not train on the inputs;
  - the use case has passed its ADR 0015 validation harness on that adapter and model version;
  - an active ADR 0016 approval names that model project as a recipient for that use case.
- If any condition is unmet, or cannot be checked, the adapter refuses real inputs and the product
  shows no suggestion.
- The local open-weight adapter remains the default. A Lakeraven-owned Gemini account never
  carries real patient data.
- All other ADR 0015 decisions are unchanged and apply to the Gemini adapter: the off switch,
  audit, no write-back, Part 2 withheld and the harness gate.

### 5. No A2A agent and no Google-specific code now; a listing waits for a conformance pack

- We publish an MCP server, not an agent. We do not build an A2A agent or Gemini skills until a
  product needs one (for example, Corvid offering prior-authorization determinations to agents).
  That would be a separate ADR.
- The prerequisite for any catalog or partner listing is a **connector pack**:
  - a setup guide for Gemini Enterprise as an MCP client (Agent Registry entry and OAuth fields);
  - a published scope and tool list;
  - a conformance run against synthetic data that a reviewer can repeat.
- The same pack serves any other MCP-capable platform.
- Applying to Google's partner programs is a business step, not engineering, and is outside this
  ADR.

## Consequences

### Positive

- RPMS gets a seat in agent ecosystems that today reach only large commercial EHRs, without
  migrating data or coupling to one vendor.
- Inherited RPMS permissions and per-user audit match the posture of the large-EHR connectors,
  so a reviewer can compare like with like.
- Partners can use Gemini as a model without breaking ADR 0015's control guarantees.

### Negative

- Data read by an agent leaves this engine for the customer's agent platform. After that, Part 2
  redisclosure duties and retention follow the customer's agreement with that platform, not us.
  Each tenant's administrator must make that choice knowingly.
- The surface is a second entry point onto the FHIR service, so the hard panel reviews every
  slice of it.
- A hosted-model adapter adds a configuration check (project ownership, BAA) that we can test
  but not fully verify from code. The partner's attestation is recorded with the switch.

## Alternatives considered

- **Build Gemini-specific connectors or skills.** Rejected: it couples us to one vendor, and the
  MCP surface already serves Gemini.
- **Use only system credentials for agents.** Rejected as the default: the agent would see
  whatever the service account sees, not what the user may see.
- **Run Gemini under a Lakeraven-owned cloud account for all partners.** Rejected: patient data
  would leave the partner's control (ADR 0015).
- **Route agents through a third-party integration hub.** Rejected: it adds a party that holds
  PHI and tokens, and it adds nothing the FHIR service does not already do.

## Build order

0. The ADR 0016 approval contract (rule 11), at least the read side the switch needs. Nothing here runs on real data before it.
1. #1234: the read-only MCP surface, with per-user delegation and the per-tenant switch.
   It follows #546 phase 1.
2. Gemini Enterprise connects to it as a per-user OAuth client, on synthetic data.
3. The connector pack: setup guide, scope and tool list, repeatable conformance run.
4. The Vertex AI Gemini adapter behind `Suggestions`, refusing real inputs unless decision 4's
   conditions hold. It is a sub-issue of #1136 and blocked until the owner accepts decision 4.

Slices 1, 2 and 4 handle PHI and get the hard panel.

## Open questions

- Which ADR 0016 approval shape (ADR 0017's IG profile) the switch reads. Until that contract exists, decision 0 keeps every path synthetic-only.
