# frozen_string_literal: true

module Lakeraven
  module EHR
    module Ecr
      # Mock eCLRS (Electronic Clinical Laboratory Reporting System) adapter
      # for testing electronic case reporting transmission.
      class MockEclrsAdapter
        attr_reader :submissions

        def initialize
          @submissions = []
        end

        def transmit(eicr_xml)
          tracking_id = "ecr-#{SecureRandom.hex(8)}"
          @submissions << { eicr_xml: eicr_xml, tracking_id: tracking_id, transmitted_at: Time.current }
          { success: true, tracking_id: tracking_id }
        end
      end
    end
  end
end
