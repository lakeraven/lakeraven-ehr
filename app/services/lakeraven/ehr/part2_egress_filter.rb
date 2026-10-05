# frozen_string_literal: true

module Lakeraven
  module EHR
    # C-CDA egress seam. TransitionsOfCareController serializes what this
    # returns and does not build a document when the return value is not
    # a sections hash.
    #
    # What this method does: return the sections it was given. It does
    # not classify records and it does not remove any. Bulk export and
    # the FHIR read API do not call it.
    class Part2EgressFilter
      def self.call(sections)
        sections
      end
    end
  end
end
