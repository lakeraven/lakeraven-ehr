# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    # Registering a new patient (rpms-ux S-REG-02) through RpmsRpc::Patient.register:
    # AG's own add (AGG ADD NEW PATIENT), after the gem's candidate lookup. The
    # gem decides identity: a name or date of birth already on file comes back as
    # :duplicate_identity with the candidates' DFNs, and only allow_duplicate:
    # true, after a person has reviewed them, files anyway. Nothing here second-
    # guesses that answer.
    class PatientRegistrationGateway
      Result = Data.define(:status, :dfn, :candidate_dfns, :message) do
        def registered? = status == :registered
        def possible_matches? = status == :possible_matches
      end

      PICK_LIMIT = 25

      def self.register(registration, allow_duplicate: false, via: ::RpmsRpc::Patient)
        attrs = registration.register_attrs
        attrs = attrs.merge(allow_duplicate: true) if allow_duplicate == true
        reply = via.register(attrs)
        return Result.new(status: :unavailable, dfn: nil, candidate_dfns: [], message: "RPMS did not answer") if reply.nil?
        return Result.new(status: :registered, dfn: reply[:dfn], candidate_dfns: [], message: nil) if reply[:success]

        if reply[:error] == :duplicate_identity
          return Result.new(status: :possible_matches, dfn: nil, candidate_dfns: Array(reply[:candidate_dfns]), message: nil)
        end

        Result.new(status: :refused, dfn: nil, candidate_dfns: [], message: reply[:message].to_s)
      end

      # The tribes and communities whose names start with the text, for the
      # clerk to choose from. Empty text lists nothing.
      def self.tribes(part, via: ::RpmsRpc::Tribal)
        return [] if part.to_s.strip.empty?

        Array(via.tribes(part: part.to_s.strip.upcase)).first(PICK_LIMIT)
      end

      def self.communities(part, via: ::RpmsRpc::Tribal)
        return [] if part.to_s.strip.empty?

        Array(via.communities(part: part.to_s.strip.upcase)).first(PICK_LIMIT)
      end
    end
  end
end
