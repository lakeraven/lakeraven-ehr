# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # A recognized backend has no registered adapter. NotImplementedError
      # so callers that already rescue that class keep their current behavior.
      class AdapterNotAvailable < NotImplementedError
      end
    end
  end
end
