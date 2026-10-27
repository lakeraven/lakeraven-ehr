# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    class PatientGateway
      class << self
        def find(dfn)
          attrs = RpmsRpc::Patient.find(dfn.to_i)
          return nil unless attrs

          build_patient(attrs)
        end

        # ORWPT LIST ALL answers one page of the name index starting at the
        # text, not a filter, and RPMS stores names upper-case (rpms-rpc
        # #352). Ask in upper case and keep the rows whose name begins with
        # the text. A page holds at most 44 rows, so a very common prefix
        # can stop short of every match. A row carries the DFN and name and
        # nothing else, so each match is read with #find for the sex and
        # date of birth a Patient resource must carry; a row #find cannot
        # read keeps what the row gave.
        def search(name_pattern)
          text = name_pattern.to_s.upcase
          RpmsRpc::Patient.search(text)
            .select { |row| row[:name].to_s.upcase.start_with?(text) }
            .map { |row| find(row[:dfn]) || build_patient(row) }
        end

        def find_by_ssn(ssn)
          attrs = RpmsRpc::Patient.find_by_ssn(ssn)
          attrs ? build_patient(attrs) : nil
        end

        # Chart-banner projection — returns the issue-#60 contract hash or nil.
        # Delegates to RpmsRpc::Patient.brief_header (lakeraven/rpms-rpc#60).
        # Coerces dfn to_i to match the convention used by `find` and
        # `find_by_ssn` on this gateway.
        def brief_header(dfn)
          RpmsRpc::Patient.brief_header(dfn.to_i)
        end

        private

        # rpms-rpc returns fields beyond the Patient model's declared
        # attributes (veteran, ward_location, etc.); slice to model.attribute_names
        # so ActiveModel doesn't raise UnknownAttributeError on the extras.
        def build_patient(attrs)
          known = Patient.attribute_names.map(&:to_sym)
          Patient.new(**attrs.slice(*known))
        end
      end
    end
  end
end
