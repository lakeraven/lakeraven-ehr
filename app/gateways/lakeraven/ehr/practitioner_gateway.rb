# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class PractitionerGateway
      class << self
        def find(ien)
          attrs = RpmsRpc::DataMapper.practitioner_info.fetch_one(ien.to_s, extras: { ien: ien.to_i })
          return nil unless attrs
          return nil if attrs[:name] == "-1"

          Practitioner.new(**attrs)
        end

        def search(name_pattern)
          results = RpmsRpc::DataMapper.practitioner_list.fetch_many(name_pattern, "1")
          results.filter_map do |attrs|
            next if attrs[:name].blank?

            Practitioner.new(**attrs)
          end
        end
      end
    end
  end
end
