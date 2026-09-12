# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestsController < ApplicationController
      include PatientCompartment

      def index
        results = ServiceRequest.for_patient(patient_compartment_dfn)
        render_bundle(results.map { |r| { resourceType: "ServiceRequest" }.merge(r) })
      end
    end
  end
end
