# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # The appointments needing action in the scheduler's clinics (#875,
      # rpms-ux S-SCH-13.5): past their time with no check-in, check-out,
      # cancellation or no-show recorded, over a range of dates, today unless
      # the scheduler chooses others. Each links to its clinic's day, where it
      # is checked in, cancelled or marked a no-show. The clinics are the ones
      # scheduling offers this user (BaseController#visible?).
      class NeedingActionController < BaseController
        # Throttled like every credentialed route (#498).
        rate_limit only: :index

        # GET /scheduling/needing_action?from=YYYY-MM-DD&to=YYYY-MM-DD
        def index
          @from = params[:from].to_s
          @to = params[:to].to_s
          @window, @window_error = NeedingActionWindow.parse(@from, @to)
          @appointments = read_needing_action(@window) if @window
        end

        private

        # The rows, or :unread when RPMS does not answer: a failed read is said
        # so, never shown as an empty list. A refusal keeps RPMS's reason.
        def read_needing_action(window)
          resources = AppointmentBookingGateway.resources.select { |r| visible?(r) }
          AppointmentBookingGateway.needing_action(resources, window)
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[scheduling] appointments needing action raised #{e.class}")
          @refusal = e.message if e.is_a?(::RpmsRpc::Client::RpcRefusedError)
          :unread
        end
      end
    end
  end
end
