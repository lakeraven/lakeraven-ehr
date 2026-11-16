# frozen_string_literal: true

require "rpms_rpc/api/allergen"

module Lakeraven
  module EHR
    # Allergen lookup for allergy entry (#1109). Wraps RpmsRpc::Allergen
    # (ORWDAL32 ALLERGY MATCH): each match carries the agent and the RPMS
    # pointer RpmsRpc::Allergy.save files, so a clinician never types one.
    class AllergenGateway
      # Matches for +text+, as RpmsRpc::Allergen.search gives them. A reply
      # RPMS did not shape as a match list raises; the caller says so.
      def self.search(text, via: default_provider)
        return [] if text.to_s.strip.empty?

        via.search(text.to_s)
      end

      # Whether RPMS's own search for +agent+ offers exactly this agent and
      # pointer. A chosen allergen is checked this way before it is filed, so
      # what RPMS receives is a pair its search gave, not one a request made up.
      def self.offers?(agent, pointer, via: default_provider)
        search(agent, via: via).any? { |match| match[:agent] == agent && match[:agent_pointer] == pointer }
      end

      def self.default_provider
        ::RpmsRpc::Allergen
      end
    end
  end
end
