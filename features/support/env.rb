# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../test/dummy/config/environment", __dir__)
require "minitest/assertions"

World(Minitest::Assertions)

# Minitest requires this for World inclusion
def mu_pp(obj) = obj.inspect
