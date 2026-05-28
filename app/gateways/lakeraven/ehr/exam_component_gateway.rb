# frozen_string_literal: true

begin
  require "rpms_rpc/api/exam_component"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::ExamComponent.
end

module Lakeraven
  module EHR
    # Physical-exam component entry against an open encounter.
    # Wraps RpmsRpc::ExamComponent (lakeraven/rpms-rpc#66).
    class ExamComponentGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.add(dfn, visit_ien, exam_code, finding:, narrative: nil, via: default_provider)
        return FAILURE if via.nil?

        via.add(dfn.to_s, visit_ien.to_s, exam_code,
          finding: finding, narrative: narrative)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::ExamComponent) &&
                          ::RpmsRpc::ExamComponent.respond_to?(:add)
        ::RpmsRpc::ExamComponent
      end
    end
  end
end
