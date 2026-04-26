# frozen_string_literal: true

module Lakeraven
  module EHR
    module Eprescribing
      class TransmissionResult
        attr_reader :transmission_id, :status, :errors, :metadata

        def initialize(transmission_id:, status:, errors: [], metadata: {})
          @transmission_id = transmission_id
          @status = status
          @errors = Array(errors)
          @metadata = metadata
        end

        def success?
          errors.empty? && status != "error"
        end

        def transmitted?
          %w[transmitted delivered].include?(status)
        end

        def self.success(transmission_id:, status: "transmitted", metadata: {})
          new(transmission_id: transmission_id, status: status, metadata: metadata)
        end

        def self.failure(errors, transmission_id: nil)
          new(transmission_id: transmission_id, status: "error", errors: Array(errors))
        end
      end
    end
  end
end
