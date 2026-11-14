# frozen_string_literal: true

require "rpms_rpc/api/registration_parameters"

module Lakeraven
  module EHR
    # The signed-on user's facility's registration settings (#980, #981):
    # REGISTRATION PARAMETERS (#9009061) for the division RPMS signed the user
    # on to (DUZ(2)), read through RpmsRpc::RegistrationParameters. Read for
    # each request that needs them, so a change a site manager makes in RPMS
    # shows on the next form.
    class RegistrationSettingsGateway
      class << self
        # A RegistrationSiteSettings; RegistrationSiteSettings.unavailable when
        # RPMS did not answer or the session has no division, which callers
        # treat as "could not determine", never as "nothing set".
        def current
          reader.call
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[registration] registration parameters read failed: #{e.class}")
          RegistrationSiteSettings.unavailable
        end

        # How the settings are read. The mocked test suite, which has no
        # broker division, sets its own (test/test_helper.rb).
        attr_writer :reader

        def reader = @reader || method(:read_from_rpms)

        private

        def read_from_rpms
          client = BackendRegistry.current.client
          facility = client.respond_to?(:division) ? client.division&.dig(:ien) : nil
          unless facility.to_i.positive?
            Rails.logger.error("[registration] registration parameters: the session has no division")
            return RegistrationSiteSettings.unavailable
          end

          RegistrationSiteSettings.new(::RpmsRpc::RegistrationParameters.for_facility(facility))
        end
      end
    end
  end
end
