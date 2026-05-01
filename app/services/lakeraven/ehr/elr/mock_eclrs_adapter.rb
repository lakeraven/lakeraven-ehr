# frozen_string_literal: true

module Lakeraven
  module EHR
    module Elr
      # Mock eCLRS adapter for testing electronic laboratory reporting transmission.
      class MockEclrsAdapter
        attr_reader :submissions

        def initialize
          @submissions = []
        end

        def transmit(oru_message)
          tracking_id = "elr-#{SecureRandom.hex(8)}"
          @submissions << { oru_message: oru_message, tracking_id: tracking_id, transmitted_at: Time.current }
          { success: true, tracking_id: tracking_id }
        end
      end
    end
  end
end
