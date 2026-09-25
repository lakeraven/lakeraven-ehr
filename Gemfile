# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # Pinned to the #250 merge (rpms-rpc main f514068): adds RpmsRpc::SessionPool
  # (session-scoped broker clients, ADR 0005 / #234) plus the #249 nil-DUZ
  # fail-closed sign-on and the #240 RPC tiers, on top of the 0.3.0 sign-on
  # path (encrypted AV pair, CIA reply grammar, RpmsRpc.synchronize_wire). A
  # fixed ref rather than branch:main so the pin does not drift mid-merge.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", ref: "f514068"
end

gem "puma"
gem "pg"

# The asset pipeline and Tailwind CSS v4 for the dummy app, the same pair the
# SaaS host runs. Engine pages link the host's Tailwind build (tailwind.css);
# without an asset pipeline that link has no route and every page load 404s it.
gem "propshaft"
gem "tailwindcss-rails", "~> 4.4"

gem "cucumber-rails", require: false
gem "minitest"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
