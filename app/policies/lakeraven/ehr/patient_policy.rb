# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientPolicy < ApplicationPolicy
      def index?
        Roles.can?(user, :view_patients)
      end

      def show?
        Roles.can?(user, :view_patients)
      end
    end
  end
end
