# Clinic-user directory

Part of #984 and BPRM parity epic #565, outside the December pilot scope.

As a scheduling supervisor, I want a searchable, alphabetic list of a clinic's
existing scheduling users and their rights, so I can inspect current access
without changing it.

The Clinic users link on Clinic settings opens a read-only directory. It requires
`scheduling.open` and `scheduling.supervise` (SDZSUP), an IHS scheduling backend,
and a known clinic resource. Other scheduling users cannot open the directory,
including through a direct request. The application checks these capabilities
before reading the directory; it does not rely on RPMS to enforce the screen's
supervisor restriction.

`ClinicUsersGateway` calls the pinned `RpmsRpc::SchedulingSetup.resource_users`
with the BSDX resource ID, not its HOSPITAL LOCATION ID. That API reads BSDX
RESOURCE USER (#9002018.15) and returns existing users and four rights. Names
are sorted case-insensitively (RPMS uses LAST,FIRST format); search is a literal,
case-insensitive substring. Each request reads RPMS afresh. Search accepts only
scalar text up to 100 characters.

An empty successful read and no search matches have different messages. A
missing or malformed reply, or broker error, produces an unavailable page rather
than an empty list. Broker exception details are not rendered. Unknown right
values are not rendered as a definite No. Names and search text are HTML escaped.

This slice changes no user rights and adds no write route. Provider management
is separate in #1146. Rights editing, provider addition, and no-show enforcement
remain outside this change. These regression tests use synthetic gem replies;
they do not establish live RPMS/BPRM parity or clinical deployment readiness.
