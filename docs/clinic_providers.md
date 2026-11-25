# Clinic providers

Scheduling users who can view a clinic resource can open its providers from Clinic settings. Scheduling supervisors (SDZSUP) can select an existing clinic provider as the default or remove an existing provider. Adding providers and editing user rights are outside this screen.

The resource is resolved to its RPMS hospital location. Before a change, the provider list is read to verify that the entry belongs to that clinic. After RPMS reports success, the list is read again: the selected entry must be the sole default, or the removed entry must be absent. An unavailable read, failed response, or inconsistent readback is reported as unconfirmed; it may still be necessary to check RPMS before retrying. These calls are not an atomic transaction and concurrent changes can occur between reads and writes.

Removing a default is allowed. If check-in creates a visit and requires a provider, the clinic settings page warns when no default provider is present. Provider information is read from RPMS, not stored locally. Synthetic tests do not establish behavior against a live RPMS system.
