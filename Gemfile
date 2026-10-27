# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # Pinned to rpms-rpc main 042374a: Patient.lookup binds AGGRPC (AGG LOOKUP
  # PATIENTS is refused under the CIA sign-on context) and a refused global-array
  # RPC raises at once (rpms-rpc#492); Capabilities and UserRoles removed
  # (rpms-rpc#491, the host decides roles). Earlier: CIA sign-on resolves a DUZ
  # (lakeraven-ehr#540), invented RPC names removed (#310/#311), typed errors for
  # a missing RPC (#370), the user class from ORWU USERINFO (#236). A fixed ref
  # rather than branch:main so the pin does not drift mid-merge.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", ref: "042374a"
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
