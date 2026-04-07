# frozen_string_literal: true

require_relative "lib/lakeraven/ehr/version"

Gem::Specification.new do |spec|
  spec.name        = "lakeraven-ehr"
  spec.version     = Lakeraven::EHR::VERSION
  spec.authors     = [ "Lakeraven" ]
  spec.email       = [ "eng@lakeraven.com" ]
  spec.homepage    = "https://github.com/lakeraven/lakeraven-ehr"
  spec.summary     = "SMART-on-FHIR Rails engine for VistA/RPMS-backed EHRs"
  spec.description = "Public Rails engine providing FHIR R4 patient and " \
                     "practitioner reads, SMART on FHIR authentication, and " \
                     "PHI audit logging for VistA/RPMS-backed EHR deployments. " \
                     "Stores zero PHI at rest — clinical data flows through " \
                     "the rpms-rpc adapter at request time."
  spec.license     = "MIT"

  spec.metadata = {
    "homepage_uri"      => "https://github.com/lakeraven/lakeraven-ehr",
    "source_code_uri"   => "https://github.com/lakeraven/lakeraven-ehr",
    "changelog_uri"     => "https://github.com/lakeraven/lakeraven-ehr/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/lakeraven/lakeraven-ehr/tree/main/docs"
  }

  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,docs,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.1.3"
  spec.add_dependency "rpms-rpc", "~> 0.1"
end
