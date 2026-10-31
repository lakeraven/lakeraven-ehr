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

        # ORWU NEWPERS answers a page of the NEW PERSON name index starting
        # AT the text (NP1^ORWU1: "ORFROM=Starting name for this set"), not
        # the names that match it, so keep only names that begin with it, as
        # PatientGateway.search does for ORWPT LIST ALL. Names come back
        # mixed case ("Profile,Md"); the comparison ignores case. With a
        # key ("PROVIDER"), RPMS lists only the users holding it.
        def search(name_pattern, key: nil)
          text = name_pattern.to_s.upcase
          results = RpmsRpc::Practitioner.search(name_pattern, key: key)
          results.filter_map do |attrs|
            next if attrs[:name].blank?
            next unless attrs[:name].to_s.upcase.start_with?(text)

            Practitioner.new(**attrs)
          end
        end
      end
    end
  end
end
