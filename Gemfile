# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  gem "rpms-rpc", path: "../rpms-rpc"
end

if ENV["VISTA_RPC_PATH"]
  gem "vista-rpc", path: ENV["VISTA_RPC_PATH"]
else
  gem "vista-rpc", path: "../vista-rpc"
end

gem "puma"
gem "pg"

gem "cucumber-rails", require: false
gem "minitest"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
