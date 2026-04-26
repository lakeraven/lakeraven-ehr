# frozen_string_literal: true

module Lakeraven
  module EHR
    module Eprescribing
      class BaseAdapter
        def mode
          raise NotImplementedError
        end

        def send_prescription(_prescription)
          raise NotImplementedError
        end

        def check_status(_transmission_id)
          raise NotImplementedError
        end

        def cancel_prescription(_transmission_id, reason: nil)
          raise NotImplementedError
        end
      end
    end
  end
end
