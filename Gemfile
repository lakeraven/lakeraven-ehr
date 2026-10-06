# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # This sandbox demo branch resolves rpms-rpc from a matching sandbox
  # branch there (rpms-rpc#find_by_business_identifier), not main, because
  # the pinned main revision predates that lookup. Revert to "main" once
  # the real AGG LOOKUP PATIENTS path lands and this branch is retired.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", branch: "sandbox/hrn-on-pin"
end

gem "puma"
gem "pg"

gem "cucumber-rails", require: false
gem "minitest"
gem "webmock", require: false

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
