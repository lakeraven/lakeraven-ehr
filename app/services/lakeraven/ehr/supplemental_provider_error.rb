# frozen_string_literal: true

module Lakeraven
  module EHR
    # Raised when a CONFIGURED supplemental clinical provider fails.
    #
    # Deliberately not rescued into an empty slice: a deployment that opted in
    # and whose adapter is broken would otherwise be indistinguishable from one
    # that never configured a provider, so an incomplete chart would read as a
    # complete one.
    #
    # Its own file because Zeitwerk resolves a constant from the file named
    # after it; defined alongside SupplementalClinicalResources it could not be
    # referenced before that class had been loaded for another reason.
    class SupplementalProviderError < StandardError; end
  end
end
