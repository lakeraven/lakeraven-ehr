# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # A patient's applications for coverage (rpms-ux S-REG-03.3 to 03.5),
      # listed on the patient's coverage page (applications/_section). RPMS
      # keeps them in AG's PATIENT APPLICATIONS (9000045); nothing is deleted:
      # an application recorded by mistake is marked entered in error.
      class ApplicationsController < PatientSectionController
        # Throttled like every credentialed route (#498).
        rate_limit only: %i[new create update]

        EDIT_ACTIONS = %w[new create update].freeze

        # The outcomes the front desk records (9000045.11 .04), in its words.
        OUTCOMES = { "A" => "Approved", "D" => "Denied", "P" => "Pending", "E" => "Entered in error" }.freeze

        # GET /registration/patients/:dfn/applications/new
        def new
          @entry = ApplicationEntry.new(applied_on: Date.current, submitted_on: Date.current)
          load_types
        end

        # POST /registration/patients/:dfn/applications
        def create
          @entry = ApplicationEntry.new(entry_params)
          load_types
          return render(:new, status: :unprocessable_content) unless @entry.valid?

          result = PatientApplicationGateway.add(@dfn, @entry, duz: session[:duz])
          if result.saved?
            redirect_to registration_patient_coverage_path(@dfn, anchor: "applications-section"), notice: "Application recorded."
          else
            flash.now[:alert] = write_failure_message(result, "application")
            render :new, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        # POST /registration/patients/:dfn/applications/:ien/status
        def update
          status = params[:status].to_s
          date = parse_date(params[:status_on])
          unless OUTCOMES.key?(status) && date && date <= Date.current
            return redirect_to(registration_patient_coverage_path(@dfn, anchor: "applications-section"),
                               alert: "Choose what happened to the application and a date that is not in the future.")
          end

          result = PatientApplicationGateway.update_status(@dfn, params[:ien], status, date)
          if result.saved?
            redirect_to registration_patient_coverage_path(@dfn, anchor: "applications-section"),
                        notice: "Application marked #{OUTCOMES[status].downcase}."
          else
            redirect_to registration_patient_coverage_path(@dfn, anchor: "applications-section"),
                        alert: write_failure_message(result, "application's status")
          end
        end

        private

        def entry_params
          params.fetch(:application, {}).permit(:type_ien, :applied_on, :submitted_on, :submitted_via)
        end

        def load_types
          @types = PatientApplicationGateway.types
        end

        def parse_date(value)
          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end
      end
    end
  end
end
