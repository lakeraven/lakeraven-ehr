# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # A patient's advance directives (rpms-ux S-REG-17): whether they have
      # one, of what type and from when, or why they have none. RPMS keeps them
      # in ADVANCE DIRECTIVE (9000040), and AG*7.1*17 warns on the registration
      # while none is on file (AG error 55, S-REG-17.8). The patient's page
      # lists them (advance_directives/_section); this page records, changes
      # and removes them.
      class AdvanceDirectivesController < PatientSectionController
        EDIT_ACTIONS = %w[create edit update destroy].freeze

        rate_limit only: %i[index create edit update destroy]

        # GET /registration/patients/:dfn/advance_directives
        def index
          @entry = AdvanceDirectiveEntry.new(entered_on: SiteTime.today)
          load_page
        end

        # POST /registration/patients/:dfn/advance_directives
        def create
          @entry = AdvanceDirectiveEntry.new(entry_params)
          return render_index(:unprocessable_content) unless @entry.valid?

          result = PatientProfileGateway.record_advance_directive(@dfn, @entry)
          if result.saved?
            redirect_to registration_patient_advance_directives_path(@dfn), notice: "Advance directive recorded."
          else
            flash.now[:alert] = write_failure_message(result, "advance directive")
            render_index(result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        # GET /registration/patients/:dfn/advance_directives/:ien/edit
        def edit
          row = find_row
          return redirect_to(registration_patient_advance_directives_path(@dfn), alert: "That advance directive is not on file.") unless row

          @entry = AdvanceDirectiveEntry.from_row(row)
          @types = PatientProfileGateway.advance_directive_types
        end

        # POST /registration/patients/:dfn/advance_directives/:ien
        def update
          @entry = AdvanceDirectiveEntry.new(entry_params)
          @types = PatientProfileGateway.advance_directive_types
          return render(:edit, status: :unprocessable_content) unless @entry.valid?

          result = PatientProfileGateway.change_advance_directive(@dfn, params[:ien], @entry)
          if result.saved?
            redirect_to registration_patient_advance_directives_path(@dfn), notice: "Advance directive changed."
          else
            flash.now[:alert] = write_failure_message(result, "change")
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        # POST /registration/patients/:dfn/advance_directives/:ien/remove
        def destroy
          result = PatientProfileGateway.remove_advance_directive(@dfn, params[:ien])
          if result.saved?
            redirect_to registration_patient_advance_directives_path(@dfn), notice: "Advance directive removed."
          else
            redirect_to registration_patient_advance_directives_path(@dfn), alert: write_failure_message(result, "removal")
          end
        end

        private

        def entry_params
          params.fetch(:advance_directive, {}).permit(:entered_on, :directive, :type_ien, :reason)
        end

        def load_page
          @directives = PatientProfileGateway.advance_directives(@dfn)
          @types = PatientProfileGateway.advance_directive_types
        end

        def render_index(status)
          load_page
          render :index, status: status
        end

        def find_row
          ien = params[:ien].to_i
          PatientProfileGateway.advance_directives(@dfn).find { |row| row[:ien] == ien }
        end
      end
    end
  end
end
