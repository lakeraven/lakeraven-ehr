# ADR 0002: Backend Abstraction for RPMS vs Stock VistA

## Status

Accepted

## Context

`lakeraven-ehr` was built against RPMS (IHS's VistA fork) and currently hardcodes `RpmsRpc::` calls throughout its gateways. The goal is to make it backend-agnostic so the same engine can run against either RPMS or stock VA VistA backends.

The lower layers are already being split:

- `vista-rpc` — stock VistA RPC namespaces and shared infrastructure.
- `rpms-rpc` — IHS-specific RPC namespaces; depends on `vista-rpc` for shared infrastructure.

The EHR engine should not care which backend is configured; it should call a symbolic API that resolves to the correct backend namespace.

## Constraints

- **Backwards compatible.** Existing RPMS deployments must keep working without host-app changes.
- **No gateway rewrite.** Gateways should change as little as possible; ideally only the namespace reference.
- **Symbolic API.** The engine calls `Patient.find(dfn)`, `Practitioner.find_by_ien(ien)`, etc., not raw `DataMapper` mappings or RPC names.
- **Backend selection at boot.** The host app configures `Lakeraven::EHR.configure { |c| c.backend = :vista }` or `:rpms`.
- **IHS-specific features remain in rpms-rpc.** Some RPMS behaviors (chart banner, tribal enrollment) have no stock VistA equivalent. Those stay in `rpms-rpc` and are only available when configured for RPMS.

## Options considered

| Approach | Pros | Cons |
|---|---|---|
| **Backend adapter object** | Clean injection; easy to test; gateways don't change much | One more abstraction layer |
| **Namespace swapping** | Minimal code change | Hard to mock; IHS-specific features leak |
| **Per-gateway config** | Fine-grained control | Too much configuration surface |
| **Backend adapter object (selected)** | Clean separation, easy to test, keeps IHS-specific behavior behind the adapter | Requires adding a small adapter layer |

## Decision

Introduce a `Lakeraven::EHR::Backend` adapter object configured at boot time. Gateways ask the backend for the symbolic API module they need instead of hardcoding `RpmsRpc::`.

### Configuration API

```ruby
Lakeraven::EHR.configure do |c|
  c.backend = :vista   # or :rpms
  c.client = VistaRpc::CiaClient.new(host: ENV["VISTA_HOST"], port: 9100)
end
```

The backend defaults to `:rpms` for backwards compatibility.

### Adapter shape

```ruby
module Lakeraven
  module EHR
    class Backend
      class << self
        def current
          @current ||= new(EHR.configuration.backend)
        end

        def reset!
          @current = nil
        end
      end

      def initialize(kind)
        @kind = kind
      end

      def patient_api
        vista? ? VistaRpc::Patient : RpmsRpc::Patient
      end

      def practitioner_api
        vista? ? VistaRpc::Practitioner : RpmsRpc::Practitioner
      end

      private

      def vista?
        @kind == :vista
      end
    end
  end
end
```

### Gateway usage

```ruby
class Lakeraven::EHR::PatientGateway
  class << self
    def find(dfn)
      attrs = backend.patient_api.find(dfn.to_i)
      return nil unless attrs
      build_patient(attrs)
    end

    def backend
      Lakeraven::EHR::Backend.current
    end
  end
end
```

### Client wiring

`Lakeraven::EHR.configure` applies `config.client` to `VistaRpc.client`. Because `RpmsRpc.client` delegates to `VistaRpc.client` via the shared infrastructure, a single configured client serves both backends.

## Consequences

### vista-rpc responsibilities

- Provide symbolic API modules for stock VistA namespaces: `VistaRpc::Patient`, `VistaRpc::Practitioner`, etc.
- These modules use the shared `VistaRpc::DataMapper` registry and `VistaRpc.client`.

### rpms-rpc responsibilities

- Keep IHS-specific API modules (`RpmsRpc::Patient#brief_header`, `TribalEnrollmentGateway`, etc.).
- Stock methods can delegate to `VistaRpc` modules where the field contract is identical.

### lakeraven-ehr responsibilities

- Gateways reference `Backend.current.*_api` instead of `RpmsRpc::*` directly.
- Configuration exposes `backend` and `client`.
- Default remains `:rpms`.

## Unresolved

- How to handle IHS-specific gateway behavior when backend is `:vista` (raise? return nil? stub?).
- Whether to move all symbolic API modules into `vista-rpc` and have `rpms-rpc` only add IHS-specific wrappers.

## References

- `lib/lakeraven/ehr.rb` — configuration object and `Lakeraven::EHR.configure`
- `lib/lakeraven/ehr/backend.rb` — backend adapter
- `lib/lakeraven/ehr/engine.rb` — Rails engine entry point
- `app/controllers/concerns/lakeraven/ehr/auditable_clinical_access.rb` — records configured backend in audit logs
