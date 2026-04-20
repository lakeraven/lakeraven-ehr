# frozen_string_literal: true

require "lakeraven/ehr/version"
require "lakeraven/ehr/engine"
require "lakeraven/ehr/configuration"
require "lakeraven/ehr/current"
require "lakeraven/ehr/integrations/error"
require "lakeraven/ehr/integrations/result"
require "lakeraven/ehr/rpms/repository"
require "lakeraven/ehr/rpms/patient"
require "lakeraven/ehr/rpms/practitioner"

module Lakeraven
  # Lakeraven EHR — public Rails engine for SMART-on-FHIR-compliant
  # patient/practitioner reads against an RPMS/VistA backend.
  #
  # Clinical data flows through the gateway pattern (GatewayFactory →
  # domain gateways → rpms-rpc) and is presented as FHIR R4 resources.
  module EHR
  end
end
