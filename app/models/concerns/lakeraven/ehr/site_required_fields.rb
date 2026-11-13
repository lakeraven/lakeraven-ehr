# frozen_string_literal: true

module Lakeraven
  module EHR
    # A registration form whose fields a site may make mandatory in RPMS
    # (#980). The including model names, per attribute, the RPMS file and the
    # field label REGISTRATION PARAMETERS (#9009061.1101) lists it under:
    #
    #   site_required phone_home: [ "2", "PHONE NUMBER [RESIDENCE]" ]
    #
    # The controller sets site_settings (a RegistrationSiteSettings) before it
    # validates. Each required field left blank is refused by name. When the
    # settings could not be read the form is refused as a whole: it never
    # treats "could not read" as "nothing required".
    module SiteRequiredFields
      extend ActiveSupport::Concern

      UNDETERMINED = "Required fields could not be determined from RPMS. Nothing was saved. Try again in a minute."

      included do
        class_attribute :site_required_fields, instance_writer: false, default: {}
        attr_accessor :site_settings

        validate :site_required_fields_present
      end

      class_methods do
        def site_required(fields)
          self.site_required_fields = site_required_fields.merge(fields)
        end
      end

      # Whether the site requires the attribute; false when unknown, so the
      # form still renders (and site_settings_unavailable? says why).
      def required_by_site?(attribute)
        file, label = site_required_fields[attribute.to_sym]
        return false unless file && site_settings

        site_settings.required?(file, label) == true
      end

      def site_settings_unavailable? = site_settings && !site_settings.available?

      private

      def site_required_fields_present
        return if site_settings.nil?
        return errors.add(:base, UNDETERMINED) unless site_settings.available?

        site_required_fields.each_key do |attribute|
          next unless required_by_site?(attribute)
          next unless site_required_blank?(attribute)

          errors.add(attribute, "is required by this site")
        end
      end

      # A model may say a required field is answered some other way (a reason
      # for no SSN).
      def site_required_blank?(attribute) = public_send(attribute).blank?
    end
  end
end
