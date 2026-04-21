# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class ConditionGateway
      MAPPING = :problem_list

      def self.for_patient(dfn)
        RpmsRpc::DataMapper.public_send(MAPPING).fetch_many(dfn.to_s)
      end
    end
  end
end
