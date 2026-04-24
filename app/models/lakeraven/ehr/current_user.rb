# frozen_string_literal: true

module Lakeraven
  module EHR
    class CurrentUser
      attr_reader :duz, :name, :user_type, :security_keys

      def initialize(attrs)
        attrs = attrs.symbolize_keys if attrs.respond_to?(:symbolize_keys)
        @duz = attrs[:duz]
        @name = attrs[:name]
        @user_type = attrs[:user_type] || "user"
        @security_keys = Array(attrs[:security_keys])
      end

      def can?(permission)
        RpmsRpc::Capabilities.can?(self, permission)
      end

      def can_approve_chs?
        RpmsRpc::Capabilities.can_approve_chs?(self)
      end

      def can_process_chs?
        RpmsRpc::Capabilities.can_process_chs?(self)
      end

      def can_manage_consults?
        RpmsRpc::Capabilities.can_manage_consults?(self)
      end

      def capabilities
        RpmsRpc::Capabilities.capabilities_for(self)
      end

      def provider? = @user_type == "provider"
      def nurse? = @user_type == "nurse"
      def clerk? = @user_type == "clerk"

      def case_manager?
        @user_type == "case_manager" || RpmsRpc::Capabilities.has_key?(self, :prc_manager)
      end
    end
  end
end
