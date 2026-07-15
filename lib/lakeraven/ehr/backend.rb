# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "vista_rpc/api/patient"
require "rpms_rpc/api/practitioner"
require "vista_rpc/api/practitioner"

module Lakeraven
  module EHR
    # Adapter that resolves symbolic API modules for the configured backend.
    #
    #   Lakeraven::EHR.configure { |c| c.backend = :vista }
    #   Lakeraven::EHR::Backend.current.patient_api
    #   # => VistaRpc::Patient
    #
    #   Lakeraven::EHR.configure { |c| c.backend = :rpms }
    #   Lakeraven::EHR::Backend.current.patient_api
    #   # => RpmsRpc::Patient
    #
    class Backend
      class << self
        def current
          @current ||= new(EHR.configuration.backend)
        end

        def reset!
          @current = nil
        end
      end

      def initialize(kind)
        @kind = kind
      end

      def patient_api
        vista? ? VistaRpc::Patient : RpmsRpc::Patient
      end

      def practitioner_api
        vista? ? VistaRpc::Practitioner : RpmsRpc::Practitioner
      end

      private

      def vista?
        @kind == :vista
      end
    end
  end
end
