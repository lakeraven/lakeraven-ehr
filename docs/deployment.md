# Deployment

## Rate limits and client IP

`X-Forwarded-For` is trusted only from `config.action_dispatch.trusted_proxies`,
which defaults to Rails' private and loopback ranges. An on-prem or LAN
deployment where clients reach the app directly from private addresses MUST
pin `trusted_proxies` to the real proxies. Otherwise the IP limit and
LoginThrottle's IP limb can be bypassed: a private `REMOTE_ADDR` is treated
as a proxy, and the client-supplied forwarded address picks the bucket.

`RateLimit` and `LoginThrottle` keep their counters in the process. Another
Puma worker does not see these hits, and `Rails.cache` is not that store. A
multi-process deployment has one budget per process until those counters are
backed by a shared store.
