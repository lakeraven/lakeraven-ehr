# syntax=docker/dockerfile:1
# check=error=true

# The lakeraven-ehr container image: the engine served by its host app (test/dummy)
# under Puma, in production mode. See docs/deploy_container.md.
#
#   docker build -t lakeraven-ehr .
#   docker run -d -p 80:3000 \
#     -e SECRET_KEY_BASE=... \
#     -e DATABASE_URL=postgres://user:pass@host:5432/lakeraven_ehr_production \
#     -e VISTA_BROKER=cia -e VISTA_RPC_HOST=10.0.0.5 -e VISTA_RPC_PORT=9100 \
#     lakeraven-ehr

ARG RUBY_VERSION=3.4
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Runtime packages: libpq for pg, curl for the container health check.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libpq5 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    LD_PRELOAD="libjemalloc.so.2"

# Build stage: compilers, git (rpms-rpc is a git-sourced gem), and the libpq headers.
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# The gemspec reads the version file, so it is copied with the Gemfile.
COPY Gemfile Gemfile.lock lakeraven-ehr.gemspec ./
COPY lib/lakeraven/ehr/version.rb lib/lakeraven/ehr/version.rb
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

# Precompile assets when the host app has an asset pipeline; the engine carries none yet.
RUN cd test/dummy && \
    if SECRET_KEY_BASE_DUMMY=1 bin/rails -T 2>/dev/null | grep -q "assets:precompile"; then \
      SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile; \
    fi

# Final stage: runtime packages, the gems and the app, as a non-root user.
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p test/dummy/log test/dummy/tmp && \
    chown -R rails:rails test/dummy/log test/dummy/tmp
USER 1000:1000

WORKDIR /rails/test/dummy
ENTRYPOINT ["/rails/test/dummy/bin/docker-entrypoint"]

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3000/up || exit 1
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
