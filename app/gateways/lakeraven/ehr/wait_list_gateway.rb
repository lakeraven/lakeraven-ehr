# frozen_string_literal: true

require "rpms_rpc/api/wait_list"

module Lakeraven
  module EHR
    # A clinic's wait list (rpms-ux S-SCH-10) through RpmsRpc::WaitList. Reads
    # raise the gem's errors (RpmsUnavailableRendering answers them). Writes
    # answer a Result: an error mid-call is :unknown, because the write may
    # already have filed.
    class WaitListGateway
      Result = Data.define(:status, :ien, :message) do
        def saved? = status == :saved
        def unknown? = status == :unknown
      end

      # WAITING LIST REASON (#9009017.4) for an entry closed by a booking (BSDWLE).
      APPOINTMENT_MADE = "APPOINTMENT MADE"

      class << self
        # The resource's clinic's list: { ien:, clinic_ien:, clinic:, inactive: }, or nil.
        def list_for(resource, via: ::RpmsRpc::WaitList)
          via.lists.find { |list| list[:clinic_ien] == resource[:hospital_location_id] }
        end

        def reasons(type, via: ::RpmsRpc::WaitList) = Array(via.reasons(type))

        # The entries, those with a recall date in dates if asked, open ones
        # only if asked, in recall-date then priority order (S-SCH-10.9).
        def entries(list, open_only: false, dates: nil, via: ::RpmsRpc::WaitList)
          rows = Array(via.entries(list[:ien]))
          rows = rows.select { |row| row[:open] } if open_only
          rows = rows.select { |row| row[:recall_on] && dates.cover?(row[:recall_on]) } if dates
          rows.sort_by { |row| [ row[:recall_on] || Date.new(9999), row[:priority].presence || "9" ] }
        end

        def entry(list, ien, via: ::RpmsRpc::WaitList)
          Array(via.entries(list[:ien])).find { |row| row[:ien] == ien.to_i }
        end

        def add(list, addition, via: ::RpmsRpc::WaitList)
          result_for(via.add(list: list[:ien], **addition.add_attrs))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def update(list, ien, addition, via: ::RpmsRpc::WaitList)
          result_for(via.update(list: list[:ien], entry: ien.to_i, **addition.edit_attrs))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def remove(list, ien, removal, via: ::RpmsRpc::WaitList)
          result_for(via.remove(list: list[:ien], entry: ien.to_i, removed_on: removal.removed_on, resolution: removal.resolution_ien))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # Closes the entry a booking came from, today (S-SCH-10.7).
        def close_as_booked(list, ien, via: ::RpmsRpc::WaitList)
          made = reasons("R", via: via).find { |reason| reason[:name] == APPOINTMENT_MADE }
          return Result.new(status: :refused, ien: nil, message: "RPMS has no #{APPOINTMENT_MADE} resolution") unless made

          result_for(via.remove(list: list[:ien], entry: ien.to_i, removed_on: Date.today, resolution: made[:ien]))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        private

        def result_for(reply)
          return Result.new(status: :unknown, ien: nil, message: nil) if reply.nil?
          return Result.new(status: :saved, ien: reply[:ien], message: nil) if reply[:success]

          Result.new(status: :refused, ien: nil, message: reply[:message].to_s)
        end

        def unknown(error)
          Rails.logger.error("[scheduling] wait list write raised #{error.class}; the outcome is unknown")
          Result.new(status: :unknown, ien: nil, message: nil)
        end
      end
    end
  end
end
