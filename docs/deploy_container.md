# Deploying lakeraven-ehr as a container

The deployable unit is a container image: the engine served by its host app (`test/dummy`)
under Puma, in production mode.
`Dockerfile` builds it; `.github/workflows/image.yml` publishes it to
`ghcr.io/lakeraven/lakeraven-ehr` on every push to `main`.
A deploy pins an immutable `sha-<short>` tag, never `main`.

## What the container needs

| Env var | Required | Meaning |
|---|---|---|
| `SECRET_KEY_BASE` | yes | Rails secret; keep it in a secret store, one per instance |
| `DATABASE_URL` | yes | PostgreSQL, e.g. `postgres://user:pass@host:5432/lakeraven_ehr_production?sslmode=require` |
| `VISTA_BROKER` | yes | `cia` for a YottaDB stack (one broker, `{CIA}` on 9100); `xwb` for XWB |
| `VISTA_RPC_HOST` | yes | The RPMS server's private address |
| `VISTA_RPC_PORT` | yes | 9100 on a YottaDB stack; 9200 for CIA on an IRIS stack |
| `RAILS_FORCE_SSL` | no | Unset: TLS, terminated in front of the app (a load balancer). Exactly `false` serves plain HTTP, only for an app reachable solely inside a private network; any other value keeps TLS |
| `RAILS_LOG_LEVEL` | no | Default `info` |

The entrypoint runs `bin/rails db:prepare` before the server starts, so a new database is created and loaded, and an existing one is migrated.
The container listens on 3000 and answers `GET /up` with 200 once the app has booted; the image's `HEALTHCHECK` uses it.

The sign-in page is `/lakeraven-ehr/login`.

## Credentials

The sign-on codes come from the login form; the app reads none from the environment.
Outside development, rpms-rpc refuses the PROV123 debug pair, even when it is typed into the form.
A deployed instance therefore needs a real (non-debug) RPMS user.

## Build and run locally

```sh
docker build -t lakeraven-ehr .
docker run --rm -p 3000:3000 \
  -e SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  -e DATABASE_URL=postgres://postgres:postgres@host.docker.internal:5432/lakeraven_ehr_production \
  -e RAILS_FORCE_SSL=false \
  -e VISTA_BROKER=cia -e VISTA_RPC_HOST=host.docker.internal -e VISTA_RPC_PORT=19200 \
  lakeraven-ehr
```

## On AWS

The Terraform that deploys this image lives with the deployment infrastructure, outside this repo.
It creates an EC2 host that runs this image with Docker, and an encrypted RDS PostgreSQL instance.
The database password is RDS-managed in Secrets Manager, and so is `SECRET_KEY_BASE`.
Put a TLS load balancer in front of the host and leave `RAILS_FORCE_SSL` unset.
