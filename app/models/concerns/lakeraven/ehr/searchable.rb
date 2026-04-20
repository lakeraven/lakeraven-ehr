# frozen_string_literal: true

# Searchable - Shared search functionality for RPC-based models
#
# Requires GatewayAccess concern to be included in the model
module Lakeraven
  module EHR
    module Searchable
      extend ActiveSupport::Concern

      class_methods do
        # Generic search by name via domain gateway
        # Domain gateways return model instances directly
        def search_by_name(name_pattern)
          return [] if name_pattern.blank?

          searcher, method = search_handler_for_model
          searcher.send(method, name_pattern.to_s.upcase)
        end

        private

        # Return the search handler and method for this model's search
        def search_handler_for_model
          case name.demodulize
          when "Patient" then [ self, :search ]
          when "Practitioner" then [ self, :search_rpms ]
          else raise NotImplementedError, "Search not defined for #{name}"
          end
        end
      end
    end
  end
end
