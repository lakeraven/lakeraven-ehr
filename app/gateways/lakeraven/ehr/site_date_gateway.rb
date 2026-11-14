# frozen_string_literal: true

require "rpms_rpc/api/orwu"

module Lakeraven
  module EHR
    # RPMS's own "today" (#1065), read through ORWU DT "T". The read sits
    # behind the gateway door (ADR 0013 decision 6e) so SiteDate, a model,
    # never touches the client itself. Errors propagate; SiteDate decides
    # what to do when RPMS does not answer.
    class SiteDateGateway
      def self.today
        ::RpmsRpc::FilemanDateParser.parse_date(::RpmsRpc::Orwu.fileman_datetime("T"))
      end
    end
  end
end
