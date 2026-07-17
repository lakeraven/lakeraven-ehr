# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "vista_rpc/api/patient"
require "rpms_rpc/api/practitioner"
require "vista_rpc/api/practitioner"
require "rpms_rpc/api/vital"
require "vista_rpc/api/vital"
require "rpms_rpc/api/lab"
require "vista_rpc/api/lab"
require "rpms_rpc/api/problem"
require "vista_rpc/api/problem"
require "rpms_rpc/api/allergy"
require "vista_rpc/api/allergy"

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

      def vital_api
        vista? ? VistaRpc::Vital : RpmsRpc::Vital
      end

      def lab_api
        vista? ? VistaRpc::Lab : RpmsRpc::Lab
      end

      # Problem/allergy reads are stock VistA on both backends; RpmsRpc
      # keeps the IHS-specific write surface (BGOPROB*), so RPMS resolves
      # to RpmsRpc::Problem rather than the shared read-only module.
      def problem_api
        vista? ? VistaRpc::Problem : RpmsRpc::Problem
      end

      def allergy_api
        vista? ? VistaRpc::Allergy : RpmsRpc::Allergy
      end

      private

      def vista?
        @kind == :vista
      end
    end
  end
end
