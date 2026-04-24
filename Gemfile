# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", branch: "main"
end

gem "puma"
gem "pg"

gem "cucumber-rails", require: false
gem "minitest"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
