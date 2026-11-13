# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      module Setup
        # The eligibility modifiers a clerk picks as proof of a name change, a
        # legal document or legal sex (lakeraven-ehr#982): the ELIGIBILITY
        # MODIFIERS table (#9000030), as BPRM's Table Maintenance edits it.
        # Adding one takes a name and one of the types N, L, S, NL, NS, LS or
        # NLS; editing one changes its name only. The table also holds the
        # reasons behind an eligibility status (I, C, D, P) and the advance
        # directive types (A): those are listed and never changed here, so
        # nothing on this page changes anyone's eligibility (#520).
        # BPRM's key for the page is AGZMGR (CanAccessRegistrationTableMaintenance).
        class EligibilityModifiersController < BaseController
          before_action -> { require_capability!("registration.table_maintenance") }

          rate_limit only: %i[index new create edit update]

          # GET /registration/setup/eligibility_modifiers
          def index
            @modifiers = RegistrationSetupGateway.eligibility_modifiers
          end

          # GET /registration/setup/eligibility_modifiers/new
          def new
            @name = ""
            @type = ""
          end

          # POST /registration/setup/eligibility_modifiers
          def create
            @name = params[:name].to_s
            @type = params[:type].to_s
            result = RegistrationSetupGateway.add_eligibility_modifier(@name, @type)
            return redirect_to(registration_setup_eligibility_modifiers_path, notice: "Modifier added.") if result.saved?

            flash.now[:alert] = write_failure_message(result, "modifier")
            render :new, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end

          # GET /registration/setup/eligibility_modifiers/:ien/edit
          def edit
            @modifier = find_modifier
            return render_not_found unless @modifier
            return redirect_to(registration_setup_eligibility_modifiers_path, alert: READ_ONLY) unless @modifier[:legal_document]

            @name = @modifier[:name]
          end

          # POST /registration/setup/eligibility_modifiers/:ien
          def update
            @modifier = find_modifier
            return render_not_found unless @modifier

            @name = params[:name].to_s
            result = RegistrationSetupGateway.rename_eligibility_modifier(@modifier[:ien], @name)
            return redirect_to(registration_setup_eligibility_modifiers_path, notice: "Modifier renamed.") if result.saved?

            flash.now[:alert] = write_failure_message(result, "modifier")
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end

          READ_ONLY = "Only a name change, legal document or legal sex modifier is changed here."

          private

          def find_modifier
            RegistrationSetupGateway.eligibility_modifiers.find { |row| row[:ien] == params[:ien].to_i }
          end

          def render_not_found
            render plain: "No such eligibility modifier.", status: :not_found
          end
        end
      end
    end
  end
end
