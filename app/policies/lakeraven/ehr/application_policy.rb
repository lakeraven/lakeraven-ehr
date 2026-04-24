# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationPolicy
      attr_reader :user, :record

      def initialize(user, record)
        @user = user
        @record = record
      end

      def index?
        RpmsRpc::Capabilities.can?(user, :view_patients)
      end

      def show?
        RpmsRpc::Capabilities.can?(user, :view_patients)
      end

      def create?
        false
      end

      def update?
        false
      end

      def destroy?
        false
      end

      class Scope
        def initialize(user, scope)
          @user = user
          @scope = scope
        end

        def resolve
          scope
        end

        private

        attr_reader :user, :scope
      end
    end
  end
end
