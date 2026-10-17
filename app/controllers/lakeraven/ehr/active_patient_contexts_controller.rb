# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clears the session's open patient. A separate controller so this does
    # not inherit PatientContextsController's open-record before_actions.
    #
    # The destination is fixed. A caller-supplied return path would be an
    # open redirect, and this action's only job is to close the context.
    class ActivePatientContextsController < WebController
      include ClinicianPatientContext

      before_action :require_authentication

      def destroy
        close_patient_context!
        redirect_to dashboard_path
      end
    end
  end
end
