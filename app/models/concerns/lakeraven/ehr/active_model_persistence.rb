# frozen_string_literal: true

# ActiveModelPersistence - ActiveRecord-like persistence for ActiveModel classes
#
# Provides standard persistence methods (save, create, persisted?, etc.) for
# ActiveModel classes that delegate to gateway adapters for actual storage.
module Lakeraven
  module EHR
    module ActiveModelPersistence
      extend ActiveSupport::Concern

      included do
        class_attribute :primary_key_attribute, default: :id
      end

      class_methods do
        # Create new record and save
        def create(attributes = {})
          new(attributes).tap(&:save)
        end

        # Create new record and save, raising on failure
        def create!(attributes = {})
          new(attributes).tap(&:save!)
        end
      end

      # Returns the primary key value (for Rails/FHIR compatibility)
      def id
        send(self.class.primary_key_attribute)
      end

      # Check if record exists in backend storage
      def persisted?
        pk = id
        pk.present? && pk.to_i > 0
      end

      # Save record (create or update)
      def save
        return false unless valid?
        persisted? ? gateway_update : gateway_create
      end

      # Save record, raising on validation or gateway failure
      def save!
        raise ActiveModel::ValidationError.new(self) unless valid?
        result = persisted? ? gateway_update : gateway_create
        raise ActiveModel::ValidationError.new(self) unless result
        result
      end

      # Update attributes and save
      def update(attributes = {})
        assign_attributes(attributes)
        save
      end

      # Update attributes and save, raising on failure
      def update!(attributes = {})
        assign_attributes(attributes)
        save!
      end

      private

      # Subclasses must implement these methods
      def gateway_create
        raise NotImplementedError, "#{self.class} must implement #gateway_create"
      end

      def gateway_update
        raise NotImplementedError, "#{self.class} must implement #gateway_update"
      end
    end
  end
end
