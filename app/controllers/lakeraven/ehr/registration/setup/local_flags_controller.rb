# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      module Setup
        # The site's own (Category II) patient record flags (lakeraven-ehr#983):
        # PRF LOCAL FLAG (#26.11), each change followed by its PRF LOCAL FLAG
        # HISTORY (#26.12) entry, as DGPF and BPRM file them. A flag is
        # inactivated, never deleted, so the patients it is assigned to keep
        # their assignments (#26.13). This page defines flags; assigning one to
        # a patient, and the review notices, are other stories.
        #
        # Behavioral flags are left out until the Part 2 decision (#291):
        # listed, and not added, changed, or made from another type here
        # (RegistrationSetupGateway.withheld_type?). BPRM's key for the page is
        # DGPF MANAGER (CanAccessLocalFlagsTableMaintenance).
        class LocalFlagsController < BaseController
          before_action -> { require_capability!("record_flags.define") }
          before_action :load_types, except: :index
          before_action :load_flag, only: %i[edit update]

          rate_limit only: %i[index new create edit update]

          WITHHELD_MESSAGE = "Behavioral flags are not added or changed here until the Part 2 decision is made."

          # GET /registration/setup/local_flags
          def index
            @flags = RegistrationSetupGateway.local_flags
            @withheld_names = RegistrationSetupGateway.flag_types
                                                      .select { |type| RegistrationSetupGateway.withheld_type?(type) }
                                                      .map { |type| type[:name] }
          end

          # GET /registration/setup/local_flags/new
          def new
            @entry = LocalFlagEntry.new(active: true, review_days: 0, notification_days: 0)
          end

          # POST /registration/setup/local_flags
          def create
            @entry = LocalFlagEntry.new(entry_params)
            return render(:new, status: :unprocessable_content) unless @entry.valid?

            result = RegistrationSetupGateway.add_local_flag(@entry)
            return redirect_to(registration_setup_local_flags_path, notice: "Flag added.") if result.saved?

            flash.now[:alert] = write_failure_message(result, "flag")
            render :new, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end

          # GET /registration/setup/local_flags/:ien/edit
          def edit
            @entry = LocalFlagEntry.new(name: @flag[:name], type_ien: @flag[:type_ien], active: @flag[:active],
                                        review_days: @flag[:review_days], notification_days: @flag[:notification_days],
                                        description: Array(@flag[:description]).join("\n"), editing: true,
                                        withheld_types: @withheld)
          end

          # POST /registration/setup/local_flags/:ien
          def update
            @entry = LocalFlagEntry.new(entry_params.merge(editing: true))
            return render(:edit, status: :unprocessable_content) unless @entry.valid?

            result = RegistrationSetupGateway.update_local_flag(@flag[:ien], @entry)
            return redirect_to(registration_setup_local_flags_path, notice: "Flag saved.") if result.saved?

            flash.now[:alert] = write_failure_message(result, "flag")
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end

          private

          def entry_params
            raw = params.fetch(:local_flag, {}).permit(:name, :type_ien, :active, :review_days, :notification_days,
                                                       :description, :reason)
            raw.to_h.symbolize_keys.merge(withheld_types: @withheld)
          end

          def load_types
            types = RegistrationSetupGateway.flag_types
            @withheld = types.select { |type| RegistrationSetupGateway.withheld_type?(type) }.map { |type| type[:ien] }
            @types = types.reject { |type| @withheld.include?(type[:ien]) }
          end

          def load_flag
            @flag = RegistrationSetupGateway.local_flag(params[:ien])
            return render(plain: "No such local flag.", status: :not_found) unless @flag
            return redirect_to(registration_setup_local_flags_path, alert: WITHHELD_MESSAGE) if @withheld.include?(@flag[:type_ien])

            @history = RegistrationSetupGateway.local_flag_history(@flag[:ien])
          end
        end
      end
    end
  end
end
