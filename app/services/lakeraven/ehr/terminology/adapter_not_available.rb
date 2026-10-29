# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # The selected terminology backend has no registered adapter.
      # A StandardError, so `rescue => e` and `rescue StandardError` catch
      # it. It is not a NotImplementedError; callers that rescue that class
      # also rescue AdapterNotAvailable.
      class AdapterNotAvailable < StandardError
      end
    end
  end
end
