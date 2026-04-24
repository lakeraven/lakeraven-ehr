# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestPolicy < ApplicationPolicy
      def index?
        RpmsRpc::Capabilities.can?(user, :view_referrals)
      end

      def show?
        RpmsRpc::Capabilities.can?(user, :view_referrals)
      end

      def create?
        RpmsRpc::Capabilities.can?(user, :create_referrals)
      end

      def update?
        RpmsRpc::Capabilities.can?(user, :edit_own_referrals) ||
          RpmsRpc::Capabilities.can?(user, :manage_referrals)
      end

      def approve?
        RpmsRpc::Capabilities.can_approve_chs?(user)
      end

      def deny?
        RpmsRpc::Capabilities.can_approve_chs?(user)
      end
    end
  end
end
