# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # Pinned to rpms-rpc main 98276f0, past #251: CIA sign-on reads the DUZ with
  # XUS GET USER INFO (every CIA sign-on failed closed before it; #540). Not
  # yet 19fffc3 (#188): it retires Problem.filter and reshapes the medication
  # and vitals rows, a migration of its own. Earlier
  # pins brought RpmsRpc::SessionPool (ADR 0005 / #234), the #249 nil-DUZ
  # fail-closed sign-on and the 0.3.0 sign-on path (encrypted AV pair, CIA
  # reply grammar, RpmsRpc.synchronize_wire). A fixed ref rather than
  # branch:main so the pin does not drift mid-merge.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", ref: "98276f0"
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

# Headless Chrome for the live system tests (test/system/live), which sign in
# against a real RPMS broker and save screenshots as evidence.
gem "cuprite", require: false

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
