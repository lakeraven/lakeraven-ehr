# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class PractitionerGateway < BaseGateway
      class << self
        def find(ien)
          response = rpc_client.call_rpc("ORWU USERINFO", ien.to_s)
          return nil if empty_response?(response)

          attrs = RpmsRpc::DataMapper[:practitioner_info].parse_one(response, extras: { ien: ien.to_i })
          return nil unless attrs
          return nil if attrs[:name] == "-1"

          Practitioner.new(**attrs)
        end

        def search(name_pattern)
          response = rpc_client.call_rpc("ORWU NEWPERS", name_pattern, "1")
          return [] if empty_response?(response)

          RpmsRpc::DataMapper[:practitioner_list].parse_many(response).filter_map do |attrs|
            next if attrs[:name].blank?

            Practitioner.new(**attrs)
          end
        end
      end
    end
  end
end
