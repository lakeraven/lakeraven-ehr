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
        Roles.can?(self, permission)
      end

      def can_approve_chs?
        Roles.can_approve_chs?(self)
      end

      def can_process_chs?
        Roles.can_process_chs?(self)
      end

      def can_manage_consults?
        Roles.can_manage_consults?(self)
      end

      def capabilities
        Roles.capabilities_for(self)
      end

      def provider? = @user_type == "provider"
      def nurse? = @user_type == "nurse"
      def clerk? = @user_type == "clerk"

      def case_manager?
        @user_type == "case_manager" || Roles.has_key?(self, :prc_manager)
      end
    end
  end
end
