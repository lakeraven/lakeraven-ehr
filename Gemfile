# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # Pinned to the #235 merge (rpms-rpc 0.3.0): the broker-faithful sign-on path
  # — encrypted AV pair, CIA reply grammar, and RpmsRpc.synchronize_wire. A
  # fixed ref rather than branch:main so the pin does not drift during the auth
  # merge train (#235 -> #486 -> #501 -> #491 -> #517); bump to a later ref or
  # branch:main once the train has landed.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", ref: "d5f09c4"
end

gem "puma"
gem "pg"

gem "cucumber-rails", require: false
gem "minitest"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
