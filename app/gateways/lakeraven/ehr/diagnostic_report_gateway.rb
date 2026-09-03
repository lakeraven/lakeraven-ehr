# frozen_string_literal: true

require "rpms_rpc/api/lab"

module Lakeraven
  module EHR
    class DiagnosticReportGateway
      # DiagnosticReport-style aggregated lab panels (ORWLRR REPORT LIST).
      def self.for_patient(dfn)
        RpmsRpc::Lab.reports(dfn.to_s)
      end
    end
  end
end
