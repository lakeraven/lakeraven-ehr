# frozen_string_literal: true

module Lakeraven
  module EHR
    module ApplicationHelper
      def feature_available?(capability)
        BackendRegistry.current.provides?(capability)
      end

      # Whether the patient bar offers its search (rpms-ux S-CHT-01): the
      # controller decides; one that does not say offers none.
      def patient_search_allowed?
        controller.respond_to?(:patient_search_allowed?) && controller.patient_search_allowed?
      end
    end
  end
end
