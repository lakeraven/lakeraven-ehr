# Limited date-of-birth editing

For an existing patient's browser demographics form, the facility's RPMS
registration setting for limited date-of-birth editing controls who may change
that field (issue #981 under #565; existing demographics context S-REG-20).
When enabled, a registration manager may correct it. Other registration
editors see why it is unavailable and may still edit other fields. A submitted
attempt to change it is refused in full and records an authorization denial.
The setting and the patient record are read for each request. If the disabled
field is omitted, the form uses the date from that request's record, not a
value supplied by the browser. Unavailable site settings still prevent saves.

This check applies to the browser demographics path. It compares against the
record read for the request; it does not lock the record or make the later RPMS
write conditional on that value. RPMS remains the system of record and checks
its own writes. The tests use synthetic records and gem-boundary stubs; they do
not establish live RPMS behavior or BPRM parity.
