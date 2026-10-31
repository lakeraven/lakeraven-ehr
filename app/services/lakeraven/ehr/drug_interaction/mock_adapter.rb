# frozen_string_literal: true

module Lakeraven
  module EHR
    module DrugInteraction
      # Historical :mock name for the YAML knowledge base. Existing callers
      # that construct MockAdapter keep today's checks; the rules live on
      # LocalAdapter. AdapterFactory refuses :mock in production.
      class MockAdapter < LocalAdapter
        def backend
          :mock
        end
      end
    end
  end
end
