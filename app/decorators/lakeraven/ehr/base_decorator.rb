# frozen_string_literal: true

module Lakeraven
  module EHR
    # Base decorator — wraps an ActiveModel with AR supplement data.
    #
    # Adapted from rpms_redux's BaseRpmsDecorator. In rpms_redux, AR models
    # are decorated with RPMS data. Here, RPMS-backed ActiveModel objects
    # are decorated with AR-persisted supplement data.
    #
    # Usage:
    #   class PatientDecorator < BaseDecorator
    #     supplement_model PatientSupplement
    #     supplement_key :patient_dfn, from: :dfn
    #
    #     supplement_field :sexual_orientation
    #     supplement_field :gender_identity
    #   end
    #
    class BaseDecorator
      attr_reader :model

      class << self
        def supplement_model(klass)
          @supplement_model = klass
        end

        def get_supplement_model
          @supplement_model
        end

        def supplement_key(field, from:)
          @supplement_key_field = field
          @supplement_from = from
        end

        def get_supplement_key_field = @supplement_key_field
        def get_supplement_from = @supplement_from

        def supplement_field(name)
          @supplement_fields ||= []
          @supplement_fields << name

          define_method(name) do
            supplement_data&.send(name)
          end
        end

        def supplement_fields
          @supplement_fields || []
        end
      end

      def initialize(model)
        @model = model
        @supplement_loaded = false
        @supplement_data = nil
      end

      def supplement_data
        return @supplement_data if @supplement_loaded

        @supplement_loaded = true
        key_value = model.send(self.class.get_supplement_from)
        @supplement_data = self.class.get_supplement_model&.find_by(
          self.class.get_supplement_key_field => key_value
        )
      end

      def save_supplement!(**attrs)
        key_value = model.send(self.class.get_supplement_from)
        sup = self.class.get_supplement_model.find_or_initialize_by(
          self.class.get_supplement_key_field => key_value
        )
        sup.assign_attributes(attrs)
        sup.save!
        @supplement_loaded = false # bust cache
        sup
      end

      # Delegate unknown methods to wrapped model
      def method_missing(method, ...)
        if model.respond_to?(method)
          model.send(method, ...)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        model.respond_to?(method, include_private) || super
      end
    end
  end
end
