# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientPolicy < ApplicationPolicy
      def index?
        RpmsRpc::Capabilities.can?(user, :view_patients)
      end

      def show?
        RpmsRpc::Capabilities.can?(user, :view_patients)
      end
    end
  end
end
