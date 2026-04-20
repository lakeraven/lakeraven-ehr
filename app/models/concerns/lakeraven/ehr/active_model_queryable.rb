# frozen_string_literal: true

# ActiveModelQueryable - ActiveRecord-like query methods for ActiveModel classes
#
# Provides standard query methods (all, where, find_by, none) for ActiveModel classes
# that use gateway adapters for data access.
module Lakeraven
  module EHR
    module ActiveModelQueryable
      extend ActiveSupport::Concern

      included do
        class_attribute :gateway_all_method, default: nil
        class_attribute :gateway_all_args, default: []
      end

      class_methods do
        # Fetch all records from gateway
        def all
          method_name = gateway_all_method || :"get_all_#{name.demodulize.underscore.pluralize}"
          args = gateway_all_args

          results = args.any? ? gateway.send(method_name, *args) : gateway.send(method_name)
          results.map { |data| new(transform_gateway_data(data)) }
        end

        # Return empty collection (for policy scopes, null object pattern)
        def none
          []
        end

        # Find first record matching conditions
        def find_by(conditions = {})
          where(conditions).first
        end

        # Filter records by conditions hash
        def where(conditions = {})
          return all if conditions.empty?

          all.select do |record|
            conditions.all? do |key, value|
              record.send(key) == value
            end
          end
        end

        private

        # Hook for subclasses to transform gateway data before model instantiation
        def transform_gateway_data(data)
          data
        end
      end
    end
  end
end
