# frozen_string_literal: true

module Lakeraven
  module EHR
    class OrganizationsController < ApplicationController
      def show
        org = Organization.find_by_ien(params[:ien])

        if org.nil?
          render_operation_outcome(status: :not_found, severity: "error", code: "not-found", diagnostics: "Organization not found")
          return
        end

        render_fhir(org.to_fhir)
      end
    end
  end
end
