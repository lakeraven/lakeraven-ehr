# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      module Setup
        # The registration tables a site keeps itself, which BPRM edits under
        # Settings > Table Maintenance. Each table names the capability it
        # takes (ADR 0010); the check runs before RPMS is asked anything.
        class BaseController < WebController
          include RpmsUnavailableRendering

          before_action :require_bprm_registration!
          before_action :require_authentication

          private

          # The tables are AG's and DG's, which only an IHS backend serves (#647).
          def require_bprm_registration!
            return if BackendRegistry.current.provides?(:bprm_registration)

            note_audit_denial("browser access refused: backend lacks bprm_registration")
            render plain: "Registration is not available on this backend.", status: :not_found
          end

          # What the user sees when a save did not land, by the gateway's answer.
          def write_failure_message(result, what)
            if result.unknown?
              "RPMS did not say whether the #{what} was saved. Reload the page and check before saving again."
            elsif result.message.present?
              result.message
            else
              "RPMS did not save the #{what}."
            end
          end
        end
      end
    end
  end
end
