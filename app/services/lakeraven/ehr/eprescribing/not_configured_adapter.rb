# frozen_string_literal: true

module Lakeraven
  module EHR
    module Eprescribing
      # What production runs until an e-prescribing gateway exists (#708). Every
      # call answers with a failed result, so signing an order reports that the
      # prescription was not sent; nothing is transmitted.
      class NotConfiguredAdapter < BaseAdapter
        MESSAGE = "E-prescribing is not configured on this server"

        def mode
          :not_configured
        end

        def send_prescription(_prescription)
          TransmissionResult.failure(MESSAGE)
        end

        def check_status(transmission_id)
          TransmissionResult.failure(MESSAGE, transmission_id: transmission_id)
        end

        def cancel_prescription(transmission_id, reason: nil)
          TransmissionResult.failure(MESSAGE, transmission_id: transmission_id)
        end
      end
    end
  end
end
