# frozen_string_literal: true

module Lakeraven
  module EHR
    # The signed-on facility's registration settings, as RPMS holds them in
    # REGISTRATION PARAMETERS (#9009061, ^AGFAC), one entry per facility
    # (RpmsRpc::RegistrationParameters.for_facility). lakeraven-ehr keeps no
    # copy: a site manager changes them in RPMS (AG's site parameters option),
    # and the next form shown follows.
    #
    # Two kinds of setting:
    #
    # - Mandatory fields (field 1101 MANDATORY FIELDS (SITE)): per file, the
    #   fields this site requires, by the field's RPMS label. A field the site
    #   does not list is not required, which is RPMS's own rule
    #   ($$ISREQ^AGFLDREQ quits 0 for it).
    # - Switches (the "Ask for ..." fields 1 to 28): whether a section is asked.
    #   A switch the site has not answered asks, so a clerk is never kept from
    #   recording something; Limited DOB editing unanswered does not limit.
    #
    # When RPMS could not be read the two fail differently (#980, #981):
    # required fields fail closed (a form that cannot know what is required
    # does not save), switches fail open (every section is asked).
    class RegistrationSiteSettings
      attr_reader :facility

      def initialize(parameters)
        @parameters = parameters
        @facility = parameters&.dig(:facility)
      end

      # RPMS did not answer: see the class comment.
      def self.unavailable = new(nil)

      # RPMS answered, and the facility has no #9009061 entry.
      def self.not_on_file(facility = nil)
        new({ facility: facility, on_file: false, switches: {}, mandatory_fields: [] })
      end

      def available? = !@parameters.nil?

      # Whether the site requires the field: file is the RPMS file number,
      # label the field's label as #9009061.1101 holds it ("CITY",
      # "PHONE NUMBER [RESIDENCE]"). Nil when RPMS could not be read: the
      # caller refuses to save rather than guess.
      def required?(file, label)
        return nil unless available?

        Array(@parameters[:mandatory_fields]).any? do |row|
          row[:file].to_s == file.to_s && row[:field].to_s == label.to_s && row[:required]
        end
      end

      # Whether the section a switch controls is asked. True when RPMS could
      # not be read or the site has not answered.
      def ask?(switch)
        return true unless available?

        @parameters.dig(:switches, switch) != false
      end

      # Limited DOB editing (field 12): only a registration manager (AGZMGR)
      # may change an existing patient's date of birth.
      def limited_dob_editing? = available? && @parameters.dig(:switches, :limited_dob_editing) == true
    end
  end
end
