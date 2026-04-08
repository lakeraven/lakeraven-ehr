source "https://rubygems.org"

# Specify your gem's dependencies in lakeraven-ehr.gemspec.
gemspec

# rpms-rpc 0.1.0 is published as a tagged GitHub release but not yet
# pushed to rubygems.org. Pull it from the git tag so CI and local
# development resolve to the same revision. Local contributors can
# override with `bundle config local.rpms-rpc ../rpms-rpc` to work
# against an unpushed sibling checkout.
gem "rpms-rpc", git: "https://github.com/lakeraven/rpms-rpc.git", tag: "v0.1.0"

gem "puma"
gem "pg"
gem "propshaft"

# SMART on FHIR / OAuth 2.0 provider — handles the authorization
# code flow, PKCE, refresh tokens, and token introspection. The
# engine wraps Doorkeeper with a SMART configuration endpoint and
# its own scope vocabulary; Doorkeeper handles the OAuth 2.0 mechanics.
gem "doorkeeper", "~> 5.9"

group :development, :test do
  gem "rubocop-rails-omakase", require: false
  gem "cucumber-rails", require: false
end
