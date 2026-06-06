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

          # ORWU USERINFO returns fields beyond what the Practitioner
          # model declares (duz, user_class, kernel_domain, site_ien);
          # slice to the model's known attribute names so ActiveModel
          # doesn't raise UnknownAttributeError.
          known = Practitioner.attribute_names.map(&:to_sym)
          Practitioner.new(**attrs.slice(*known))
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
