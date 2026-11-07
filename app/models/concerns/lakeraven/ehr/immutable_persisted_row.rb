# frozen_string_literal: true

module Lakeraven
  module EHR
    # `readonly?` stops update and destroy. `delete`, `increment!`,
    # `decrement!`, and class-level `update_counters` do not consult it, so a
    # persisted row raises here before any of those statements.
    module ImmutablePersistedRow
      extend ActiveSupport::Concern

      def delete
        raise_readonly_record! if persisted?

        super
      end

      def increment!(attribute, by = 1, touch: nil)
        raise_readonly_record! if persisted?

        super
      end

      def decrement!(attribute, by = 1, touch: nil)
        raise_readonly_record! if persisted?

        super
      end

      private

      def raise_readonly_record!
        raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly"
      end

      class_methods do
        def update_counters(...)
          raise ActiveRecord::ReadOnlyRecord, "#{name} is marked as readonly"
        end
      end
    end
  end
end
