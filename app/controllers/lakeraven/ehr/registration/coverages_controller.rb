# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    module Registration
      # A patient's Medicaid, Medicare and private insurance, as the front desk
      # records it so a visit can be billed (rpms-ux S-REG-03.1). Reads and
      # writes go through AG's own registration windows (CoverageGateway).
      #
      # Seeing coverage takes registration.view; recording it is editing the
      # patient's registration, which BPRM gates on the same keys as
      # registering (patient.register).
      class CoveragesController < WebController
        include RpmsUnavailableRendering

        before_action :require_bprm_registration!
        before_action :require_authentication
        before_action -> { require_capability!("registration.view") }, only: :index
        before_action -> { require_capability!("patient.register") }, only: %i[new create]
        before_action :load_patient!

        # GET /registration/patients/:dfn/coverage
        def index
          @policies = CoverageGateway.on_file(params[:dfn])
          render :index, status: :service_unavailable if @policies.nil?
        rescue RpmsRpc::Client::RpcRefusedError
          @refused = true
          render :index, status: :forbidden
        end

        # GET /registration/patients/:dfn/coverage/new?kind=medicaid
        # POST /registration/patients/:dfn/coverage/new: a state or insurer
        # look-up posts the form back, so what was typed stays out of the URL.
        def new
          @entry = CoverageEntry.new(entry_params.merge(kind: params[:kind] || entry_params[:kind]))
          return redirect_to(registration_patient_coverage_path(params[:dfn])) unless CoverageEntry::KINDS.include?(@entry.kind)

          load_picklists
        end

        # POST /registration/patients/:dfn/coverage
        def create
          @entry = CoverageEntry.new(entry_params)
          return render_form(:unprocessable_content) unless @entry.valid?

          result = CoverageGateway.add(params[:dfn], @entry, patient_name: @patient[:name])
          if result.filed?
            flash[:notice] = "#{@entry.noun.upcase_first} saved."
            redirect_to registration_patient_coverage_path(params[:dfn])
          elsif result.outcome_unknown?
            flash.now[:alert] = "RPMS did not say whether the #{@entry.noun} was saved. " \
                                "Check the patient's coverage before entering it again."
            render_form(:service_unavailable)
          else
            flash.now[:alert] = "RPMS did not save the #{@entry.noun}: #{result.message.presence || 'it gave no reason'}."
            render_form(:unprocessable_content)
          end
        end

        private

        # Registration runs on AG, which only an IHS backend serves (#647).
        def require_bprm_registration!
          return if BackendRegistry.current.provides?(:bprm_registration)

          note_audit_denial("browser access refused: backend lacks bprm_registration")
          render plain: "Registration is not available on this backend.", status: :not_found
        end

        def load_patient!
          @patient = RpmsRpc::Patient.brief_header(params[:dfn].to_i)
          render "lakeraven/ehr/registration/patients/not_found", status: :not_found unless @patient
        end

        def render_form(status)
          load_picklists
          render :new, status: status
        end

        def load_picklists
          @states = @entry.kind == "medicaid" ? CoverageGateway.states(params[:state_search]) : []
          @insurers = @entry.kind == "private" ? CoverageGateway.private_insurers(params[:insurer_search]) : []
        end

        def entry_params
          params.fetch(:coverage, {}).permit(:kind, :number, :starts_on, :ends_on, :state_ien, :part,
                                             :insurer_ien, :policy_holder).to_h
        end
      end
    end
  end
end
