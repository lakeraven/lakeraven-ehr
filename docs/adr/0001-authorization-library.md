# ADR 0001: Authorization Library

## Status

Accepted

## Context

lakeraven-ehr needs an authorization layer to control what authenticated users can do. The authorization data originates in RPMS — user classes (provider, nurse, clerk), security keys (PRCFA SUPERVISOR, GMRC MGR), and the capabilities those keys grant. This data flows through rpms-rpc into the EHR engine.

### Constraints

- **RPMS is the source of truth** for roles and security keys. The authorization library must consume externally-defined roles, not manage its own role storage.
- **Rails engine architecture.** lakeraven-ehr is a mountable engine. The host app (Jumpstart Pro) handles authentication (Devise). Authorization must compose cleanly — the engine defines policies for its resources, the host app can override or extend them.
- **Multiple engines.** corvid and rook are independent engines that need the same RPMS role/key data. Authorization logic must not couple engines to each other.
- **rpms-rpc owns RPMS details.** RPMS key strings (`"PRCFA SUPERVISOR"`), user class numbers (`"4"` = nurse), and key-to-capability mappings belong in rpms-rpc, not in engine code.

### Options considered

| Library | Pattern | Engine-friendly | External roles | Community |
|---|---|---|---|---|
| **Pundit** | Policy per resource | Yes — policies namespace naturally | Yes — no role storage | Large, mature |
| **Action Policy** | Policy per resource | Yes | Yes | Growing, modern |
| **CanCanCan** | Central Ability class | Poor — one Ability class doesn't compose across engines | Yes | Large, mature |
| **Rolify** | DB-backed role management | N/A (role storage) | No — assumes DB roles | Medium |
| **Hand-rolled** | `can?` / `has_key?` methods | Yes | Yes | N/A |

## Decision

**Use Pundit** for authorization in lakeraven-ehr, corvid, and rook.

### Rationale

1. **Policy-per-resource** composes across engines. Each engine defines policies for its own models (`Lakeraven::EHR::PatientPolicy`, `Corvid::PrcReferralPolicy`). No shared Ability class to coordinate.

2. **No role storage.** Pundit doesn't manage roles — it receives a `current_user` object and checks whatever attributes it has. RPMS roles and security keys flow through rpms-rpc into `CurrentUser`, and Pundit policies query that object. RPMS stays the source of truth.

3. **Host app override.** Jumpstart Pro (or any host) can define its own policies that override or extend engine defaults. Standard Pundit resolution order handles this.

4. **Rails standard.** Most commonly paired with Devise. Contributors will recognize the pattern. Extensive documentation and ecosystem support.

5. **Action Policy** was a close second — better scoping, caching, and failure reasons. But Pundit's larger ecosystem and simpler mental model win for a multi-engine architecture where contributors may work across repos.

## Consequences

### rpms-rpc responsibilities

rpms-rpc will export:
- `RpmsRpc::SecurityKeys` — registry mapping symbolic names to RPMS key strings, and resolution of raw key strings to symbols
- `RpmsRpc::UserRoles` — user class to role mapping, and key-to-capability derivation

### Engine responsibilities

Each engine defines Pundit policies for its resources. Policies query `CurrentUser` attributes (user_type, capabilities, security keys as symbols). No RPMS key strings or user class numbers appear in engine code.

### CurrentUser

`CurrentUser` becomes a thin data object holding pre-resolved attributes:
- `user_type` (string, resolved from RPMS user class by rpms-rpc)
- `security_keys` (array of symbols, resolved from RPMS key strings by rpms-rpc)
- `capabilities` (Set of symbols, derived from keys by rpms-rpc)

Pundit policies check these attributes. The `can?`/`has_key?`/`can_approve_chs?` methods are replaced by policy checks.

### Migration path

Existing hand-rolled `can?` checks in step definitions and controllers will be replaced with `authorize` calls and Pundit policies. This should happen before porting additional features (#95-#107) to avoid accumulating technical debt.
