# frozen_string_literal: true

module Lakeraven
  module EHR
    module DrugInteraction
      # The named backend has no adapter on this server.
      # DrugInteractionService turns this into an incomplete, unsafe result
      # with no interactions, rather than reporting the check as safe.
      class AdapterNotAvailable < StandardError; end
    end
  end
end
