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
    class Part2Posture
      def self.part2?(record_type:, record_id:, content:)
        return true if record_type.blank? || record_id.to_s.blank?
        return true if labelled?(record_type.to_s, record_id.to_s)

        SudContentSuspicion.classify(content) != :not_suspected
      end

      # Only database errors are rescued: a label table that cannot be read
      # gives no reason to call the record clean, so it fails closed to
      # Part 2. Anything else is a bug and is left to surface rather than
      # being silently swallowed.
      def self.labelled?(record_type, record_id)
        Part2Label.exists?(record_type: record_type, record_id: record_id) ? true : false
      rescue ActiveRecord::ActiveRecordError
        true
      end
      private_class_method :labelled?
    end
  end
end
