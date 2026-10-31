# frozen_string_literal: true

module Lakeraven
  module EHR
    # Host hook for licensed CPT display text.
    #
    # AMA descriptor prose is not redistributable. The engine stores and
    # compares numeric codes only; a deployment that holds a license installs
    # a callable here. Until one is installed, display is absent.
    class LicensedCptContent
      NULL_PROVIDER = ->(_code) { nil }

      cattr_accessor :descriptor_provider, default: NULL_PROVIDER

      def self.display_for(cpt_code)
        provider = descriptor_provider || NULL_PROVIDER
        provider.call(cpt_code)
      end
    end
  end
end
