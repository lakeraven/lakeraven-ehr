# frozen_string_literal: true

module Lakeraven
  module EHR
    # Read-time Part 2 posture (#906, slice of #522): a record is Part 2
    # unless there is positive reason to say it is not. Unlabelled but
    # suspected content is Part 2; never the reverse.
    #
    # The ONLY false answer: the record can be identified, the label lookup
    # succeeds, there is no label row at all, and the content reads
    # :not_suspected. ANY label row means Part 2, whatever its
    # security_code — an unknown label counts as Part 2.
    #
    # An id that cannot be looked up (blank, or carrying a NUL byte, which
    # PostgreSQL refuses in a string) is Part 2 without a query: a lookup
    # that cannot succeed is no reason to call the record clean.
    class Part2Posture
      def self.part2?(record_type:, record_id:, content:)
        key = Part2Label.normalized_key(record_type: record_type, record_id: record_id)
        return true unless Part2Label.storable_key?(key)
        return true if labelled?(key)

        # classify never raises: unreadable or blank content is :unclassified.
        SudContentSuspicion.classify(content) != :not_suspected
      end

      # Only database errors are rescued: a label table that cannot be read
      # gives no reason to call the record clean, so it fails closed to
      # Part 2. Anything else is a bug and is left to surface rather than
      # being silently swallowed.
      #
      # The read runs in a savepoint, so a statement that fails at the
      # database rolls back only the savepoint and never aborts a caller's
      # open transaction. A read needs no detachment.
      def self.labelled?(key)
        Part2Label.transaction(requires_new: true) { Part2Label.exists?(key) } ? true : false
      rescue ActiveRecord::ActiveRecordError
        true
      end
      private_class_method :labelled?
    end
  end
end
