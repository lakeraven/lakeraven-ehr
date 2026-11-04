# Deployment

## Rate limits and client IP

RateLimit and LoginThrottle take the client address from `ClientIp`.

A direct-LAN deployment, where clients reach the app with no reverse proxy,
turns forwarded headers off:

    Lakeraven::EHR.configure { |c| c.trust_forwarded_for = false }

The address is then `REMOTE_ADDR`. A caller-supplied `X-Forwarded-For` does
not pick the bucket.

A proxied deployment leaves `trust_forwarded_for` at its default (`true`) and
pins `config.action_dispatch.trusted_proxies` to its real proxies. With no
explicit list, Rails' private and loopback ranges are trusted, so a private
`REMOTE_ADDR` is treated as a proxy and the forwarded header picks the bucket.

The counters live in the process. Another Puma worker does not see these
hits, and `Rails.cache` is not that store. A multi-process deployment has
one budget per process until the counters are backed by a shared store.
