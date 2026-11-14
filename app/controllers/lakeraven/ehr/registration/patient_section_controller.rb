# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    module Registration
      # A section of a patient's registration: who the patient is, and one part
      # of the record (contacts, languages, other names). Reading takes
      # registration.view, changing takes patient.register (ADR 0010).
      #
      # Each section is a partial (`_section`) that a patient record page can
      # render as it is; until that page has it, the section is its own page.
      class PatientSectionController < WebController
        include RpmsUnavailableRendering
        include RegistrationSiteSettingsLookup

        before_action :require_bprm_registration!
        before_action :require_authentication
        before_action -> { require_capability!("registration.view") }
        # Refused before RPMS is asked anything (ADR 0010).
        before_action -> { require_capability!("patient.register") }, if: -> { self.class::EDIT_ACTIONS.include?(action_name) }
        before_action :load_patient

        # The actions that change the record; a subclass names its own.
        EDIT_ACTIONS = [].freeze

        private

        # Registration runs on AG, which only an IHS backend serves (#647).
        def require_bprm_registration!
          return if BackendRegistry.current.provides?(:bprm_registration)

          note_audit_denial("browser access refused: backend lacks bprm_registration")
          render plain: "Registration is not available on this backend.", status: :not_found
        end

        def load_patient
          @dfn = params[:dfn].to_i
          @patient = RpmsRpc::Patient.brief_header(@dfn)
          render "lakeraven/ehr/registration/patients/not_found", status: :not_found unless @patient
        end

        # What the clerk sees when a save did not land, by the gateway's answer.
        def write_failure_message(result, what)
          if result.unknown?
            "RPMS did not say whether the #{what} #{what.end_with?('s') ? 'were' : 'was'} saved. Reload the page and check before saving again."
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
