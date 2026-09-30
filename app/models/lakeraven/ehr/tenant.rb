# frozen_string_literal: true

module Lakeraven
  module EHR
    # The tenancy boundary — ADR 0007. Minimal on purpose: each addition here
    # is the one the failing spec asked for, nothing further.
    class Tenant < ApplicationRecord
      has_many :approved_instances
    end
  end
end
