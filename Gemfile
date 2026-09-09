# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # rpms-rpc PR #188 (feat/provenance-phone-reads): verified measurement /
  # problem-list / patient-contact wire reads this branch builds on.
  # Final merge sequences after #188 lands; then repoint at main.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", branch: "feat/provenance-phone-reads"
end

gem "puma"
gem "pg"

gem "cucumber-rails", require: false
gem "minitest"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
