# frozen_string_literal: true

require "rpms_rpc/api/practitioner"

module Lakeraven
  module EHR
    class PractitionerGateway
      class << self
        def find(ien)
          attrs = RpmsRpc::Practitioner.find(ien)
          return nil unless attrs
          return nil if attrs[:name] == "-1"

          Practitioner.new(**attrs)
        end

        def search(name_pattern)
          results = RpmsRpc::Practitioner.search(name_pattern)
          results.filter_map do |attrs|
            next if attrs[:name].blank?

            Practitioner.new(**attrs)
          end
        end
      end
    end
  end
end
