# frozen_string_literal: true

module Lakeraven
  module EHR
    module ApplicationHelper
      def feature_available?(capability)
        BackendRegistry.current.provides?(capability)
      end
    end
  end
end
