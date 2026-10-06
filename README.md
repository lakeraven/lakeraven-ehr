# Lakeraven::Ehr
A web front end for RPMS.
RPMS stays the system of record: this engine reads and writes through its RPC brokers and keeps no clinical data of its own.

## Usage
How to use my plugin.

## RPMS backend

The app needs an RPMS broker to sign in and to read or write anything.
The host app names it in `config/rpms.yml`, one block per environment, the way `config/database.yml` names a database:

```yaml
default: &default
  broker: "<%= ENV.fetch("VISTA_BROKER", "cia") %>"  # cia (RPMS CIA broker) or xwb (stock VistA XWB)
  host: "<%= ENV["VISTA_RPC_HOST"] %>"
  port: <%= ENV.fetch("VISTA_RPC_PORT", 9100) %>

development:
  <<: *default
  host: "<%= ENV.fetch("VISTA_RPC_HOST", "127.0.0.1") %>"

production:
  <<: *default
```

The engine reads it with `config_for(:rpms)` at boot; the dummy app's copy is `test/dummy/config/rpms.yml`.
Each value can come from the environment (`VISTA_BROKER`, `VISTA_RPC_HOST`, `VISTA_RPC_PORT`), so a container or a stack sets them there.
With no host named, the app boots and logs `No RPMS backend configured`, and sign-in fails.
A host app may instead set `RpmsRpc.configure { |c| c.client = ... }` in an initializer; the engine leaves a configured client alone.

**Local: an rpms-ops release in Docker.**
Every `bcer-*-ydb` release of [rpms-ops](https://github.com/lakeraven/rpms-ops) is an image; take the newest tag from its releases page.
If the pull is refused, `docker login ghcr.io` with a GitHub token that can read lakeraven packages.

```bash
$ docker run -d --name rpms -p 127.0.0.1:9100:9100 ghcr.io/lakeraven/rpms-ydb:$TAG
$ cd test/dummy
$ bin/rails server        # development defaults to a CIA broker on 127.0.0.1:9100
```

Sign in at http://localhost:3000/lakeraven-ehr/login with an RPMS access and verify code on that image.

**A deployed stack.**
Forward the stack's broker port to your machine (cloud-rpms runs its stacks behind SSM) and point `VISTA_RPC_HOST` and `VISTA_RPC_PORT` at the forwarded port.
A YottaDB stack serves CIA on 9100; an IRIS stack serves XWB on 9100 and CIA on 9200.

**Tests need no backend.**
`bin/rails test` and `bundle exec cucumber` run against rpms-rpc's in-memory `MockClient`.
`test/system/live` signs in against a real broker and skips unless `LIVE_RPMS=1`; its header says how to run it.

## Installation
Add this line to your application's Gemfile:

```ruby
gem "lakeraven-ehr"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install lakeraven-ehr
```

### Styles

Engine pages are styled with Tailwind CSS v4 and link the host's Tailwind build (`tailwind.css`).
The engine ships no build of its own.
The host needs `tailwindcss-rails` (4.x) and includes the engine in its build:

```bash
$ bin/rails tailwindcss:engines
```

Then add this line to the host's `app/assets/tailwind/application.css`:

```css
@import "../builds/tailwind/lakeraven_ehr";
```

The engine's styles cannot restyle the host's own pages.
They define no theme, and every element default is scoped to `.lr-ehr`, the class the engine layout puts on `<body>`.

## Contributing
Contribution directions go here.

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
