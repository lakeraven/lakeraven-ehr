# frozen_string_literal: true

require "lakeraven/ehr/version"
require "lakeraven/ehr/engine"

module Lakeraven
  # Lakeraven EHR — public Rails engine for SMART-on-FHIR-compliant
  # patient/practitioner reads against an RPMS/VistA backend.
  #
  # The engine ships zero PHI at rest. All clinical data flows through
  # adapter calls (rpms-rpc for the RPMS path) and is presented as
  # FHIR R4 resources at request time.
  module EHR
  end
end
