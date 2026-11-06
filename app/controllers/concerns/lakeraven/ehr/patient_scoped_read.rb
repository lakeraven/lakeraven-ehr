# frozen_string_literal: true

module Lakeraven
  module EHR
    # Search and read for a type RPMS holds per patient (#845). The controller
    # says how to read one patient's resources (#patient_resources); both the
    # search and the read serve exactly those, under one id
    # (FHIR::PatientScopedId), so a record a search returned can be fetched by
    # that id and validated against what the search served.
    #
    # A read binds the patient compartment from the id, as a search does from
    # its `patient` parameter, before anything reaches RPMS. It audits as that
    # patient's record: the accounting of disclosures counts rows against the
    # Patient, so a read recorded against Condition/<id> would be missing from
    # it. An id that names no patient is a 404 for every caller.
    #
    # A type that declares `_id` (FHIR::SearchCapabilities) can be searched by
    # it alone, and the id's patient is the compartment, as for a read.
    module PatientScopedRead
      extend ActiveSupport::Concern
      include PatientCompartment

      included do
        rate_limit only: %i[index show]

        compartment_bound :index, param: :patient, require_param: true
        before_action :enforce_read_compartment!, only: :show
      end

      def index
        dfn = patient_compartment_dfn
        resources = dfn.present? ? scoped_resources(dfn) : []
        resources = resources.select { |resource| resource[:id] == params[:_id] } if id_search?
        render_bundle_egress(resources)
      end

      def show
        resource = scoped_resources(read_patient_dfn).find { |candidate| candidate[:id] == params[:id] }
        return render_egress_not_found unless resource

        render_fhir_egress(resource)
      end

      private

      def scoped_resources(dfn)
        patient_resources(dfn).map { |resource| resource.merge(id: FHIR::PatientScopedId.build(dfn, resource[:id])) }
      end

      def read_patient_dfn
        FHIR::PatientScopedId.patient_dfn(id_search? ? params[:_id] : params[:id])
      end

      def id_search?
        params[:_id].present? && FHIR::SearchCapabilities.search_params_for(fhir_resource_type).key?("_id")
      end

      # With an `_id` the id names the patient; a `patient` beside it has to
      # name the same one.
      def enforce_declared_compartment!(param, require_param: false)
        return super unless id_search? && params[param].blank?

        authorize_patient_search!(read_patient_dfn)
      end

      def patient_compartment_dfn
        return super if params[:patient].present? || !id_search?

        read_patient_dfn
      end

      def enforce_read_compartment!
        return render_egress_not_found unless read_patient_dfn

        authorize_patient_search!(read_patient_dfn)
      end

      def render_egress_not_found
        render_not_found(fhir_resource_type, params[:id])
      end

      # A withheld capability refuses the same caller a read would (#659).
      def authorize_before_unavailable!
        super
        return if performed? || action_name != "show" || read_patient_dfn.nil?

        authorize_patient_search!(read_patient_dfn)
      end

      def audit_entity_reference
        return super unless (action_name == "show" || id_search?) && read_patient_dfn

        [ "Patient", read_patient_dfn ]
      end
    end
  end
end
