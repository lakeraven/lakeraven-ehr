# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # Pinned to rpms-rpc main 45125a7 (0.4.0 and the unreleased changes after
  # it): past #251, so CIA sign-on reads the DUZ with CIAVCXUS VIMINFO and
  # resolves one (lakeraven-ehr#540); the invented RPC names and their API
  # removed (#310/#311) or rebuilt on registered RPCs (#374-#380); typed
  # errors for a missing RPC (#370); the sign-on user class read from ORWU
  # USERINFO (#236). A fixed ref rather than branch:main so the pin does
  # not drift mid-merge.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", ref: "45125a7"
end

gem "puma"
gem "pg"

gem "cucumber-rails", require: false
gem "minitest"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
