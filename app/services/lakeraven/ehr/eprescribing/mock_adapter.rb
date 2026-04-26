# frozen_string_literal: true

module Lakeraven
  module EHR
    module Eprescribing
      class MockAdapter < BaseAdapter
        attr_reader :transmissions, :cancellations

        def initialize
          @transmissions = {}
          @cancellations = []
        end

        def mode
          :mock
        end

        def send_prescription(prescription)
          transmission_id = "erx-#{SecureRandom.hex(8)}"
          @transmissions[transmission_id] = {
            prescription: prescription,
            status: "transmitted",
            transmitted_at: Time.current
          }
          TransmissionResult.success(transmission_id: transmission_id, status: "transmitted")
        end

        def check_status(transmission_id)
          record = @transmissions[transmission_id]
          return TransmissionResult.failure("Transmission not found", transmission_id: transmission_id) unless record
          TransmissionResult.success(transmission_id: transmission_id, status: record[:status])
        end

        def cancel_prescription(transmission_id, reason: nil)
          record = @transmissions[transmission_id]
          return TransmissionResult.failure("Transmission not found", transmission_id: transmission_id) unless record
          record[:status] = "cancelled"
          @cancellations << { transmission_id: transmission_id, reason: reason }
          TransmissionResult.success(transmission_id: transmission_id, status: "cancelled")
        end

        def request_refill(transmission_id, pharmacy_ncpdpid:)
          record = @transmissions[transmission_id]
          return TransmissionResult.failure("Transmission not found", transmission_id: transmission_id) unless record
          refill_id = "refill-#{SecureRandom.hex(8)}"
          @transmissions[refill_id] = { type: :refill, status: "pending" }
          TransmissionResult.success(transmission_id: refill_id, status: "pending")
        end

        def approve_refill(refill_id)
          record = @transmissions[refill_id]
          return TransmissionResult.failure("Refill not found", transmission_id: refill_id) unless record
          record[:status] = "approved"
          TransmissionResult.success(transmission_id: refill_id, status: "approved")
        end

        def deny_refill(refill_id, reason: nil)
          record = @transmissions[refill_id]
          return TransmissionResult.failure("Refill not found", transmission_id: refill_id) unless record
          record[:status] = "denied"
          TransmissionResult.success(transmission_id: refill_id, status: "denied")
        end

        def request_change(transmission_id, pharmacy_ncpdpid:, new_medication:)
          record = @transmissions[transmission_id]
          return TransmissionResult.failure("Transmission not found", transmission_id: transmission_id) unless record
          change_id = "change-#{SecureRandom.hex(8)}"
          @transmissions[change_id] = { type: :change, status: "pending" }
          TransmissionResult.success(transmission_id: change_id, status: "pending")
        end

        def approve_change(change_id)
          record = @transmissions[change_id]
          return TransmissionResult.failure("Change not found", transmission_id: change_id) unless record
          record[:status] = "approved"
          TransmissionResult.success(transmission_id: change_id, status: "approved")
        end

        def deny_change(change_id, reason: nil)
          record = @transmissions[change_id]
          return TransmissionResult.failure("Change not found", transmission_id: change_id) unless record
          record[:status] = "denied"
          TransmissionResult.success(transmission_id: change_id, status: "denied")
        end

        def simulate_delivery(transmission_id)
          record = @transmissions[transmission_id]
          return false unless record
          record[:status] = "delivered"
          true
        end
      end
    end
  end
end
