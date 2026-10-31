# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestPolicy < ApplicationPolicy
      def index?
        Roles.can?(user, :view_referrals)
      end

      def show?
        Roles.can?(user, :view_referrals)
      end

      def create?
        Roles.can?(user, :create_referrals)
      end

      def update?
        Roles.can?(user, :edit_own_referrals) ||
          Roles.can?(user, :manage_referrals)
      end

      def approve?
        Roles.can_approve_chs?(user)
      end

      def deny?
        Roles.can_approve_chs?(user)
      end
    end
  end
end
