# Read-only clinic holiday calendar

Refs lakeraven-ehr #616 and #565; supporting read slice, not completion of
holiday editing or BPRM parity. Not December pilot scope.

The clinic-settings link opens a yearly view of RPMS HOLIDAY (#40.5) through
`RpmsRpc::SchedulingSetup.holidays`. Dates in this table are site-wide. The
selected clinic's HOSPITAL LOCATION (#44) field 1918.5, SCHEDULE ON HOLIDAYS?,
is read through `clinic_rules`. No holiday is added, removed or edited here.

Access is the same as viewing clinic settings: IHS scheduling backend,
authentication, `scheduling.open`, and a visible hospital-linked resource.
The route has no patient information or appointment roster. It is read-only
for supervisors and ordinary schedulers alike.

The year defaults to SiteTime.today.year. Explicit input must be a four-digit
year in 1800..2699; malformed input is refused before the holiday/rules calls.
The gem reads the inclusive Jan 1 to Dec 31 range through DDR LISTER, with an
exclusive numeric FileMan FROM bound one below Jan 1 and a stop after Dec 31.
The host validates returned dates, names and boolean clinic policy, and sorts
by date. An empty array is an empty calendar. Failed or malformed reads are
unavailable, never an empty calendar; raw broker messages are not displayed.

Validation is at the gem boundary. The pinned gem converts the raw field to
`value == "Y"` before returning it, so this host cannot detect an unknown raw
value already converted to false. The policy is today's clinic setting, not a
historical reconstruction for the year selected. Other booking constraints
remain in force even when scheduling on holidays is enabled.

Why no write controls: `add_holiday`/`remove_holiday` edit global #40.5, not a
clinic-local calendar. A future editing story must ground its authorization,
site-wide effects and readback separately. This slice does not change undo
check-in behavior or address the retained-visit issue linked from #616.
