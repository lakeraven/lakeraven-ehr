# frozen_string_literal: true

module Lakeraven
  module EHR
    # `readonly?` stops update and destroy. `delete` does not consult it, so a
    # persisted row raises here before the DELETE statement.
    module ImmutablePersistedRow
      extend ActiveSupport::Concern

      def delete
        raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if persisted?

        super
      end
    end
  end
end
