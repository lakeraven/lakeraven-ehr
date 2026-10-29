# frozen_string_literal: true

module Lakeraven
  module EHR
    module DrugInteraction
      # A documented or configured backend that nothing has registered.
      # build succeeds; check_interactions and check_allergies raise
      # AdapterNotAvailable and name the backend. The class is concrete so
      # an unregistered name is never constantized.
      class UnavailableAdapter < BaseAdapter
        def initialize(backend)
          @backend = backend
        end

        def backend
          @backend
        end

        def check_interactions(_medications)
          unavailable!
        end

        def check_allergies(_medication, _allergies)
          unavailable!
        end

        private

        def unavailable!
          raise AdapterNotAvailable, "Drug interaction backend #{@backend} is not available"
        end
      end
    end
  end
end
