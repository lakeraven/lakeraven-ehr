# frozen_string_literal: true

require_relative 'lib/lakeraven/ehr/version'

Gem::Specification.new do |spec|
  spec.name        = 'lakeraven-ehr'
  spec.version     = Lakeraven::EHR::VERSION
  spec.authors     = [ 'Lakeraven' ]
  spec.email       = [ 'eng@lakeraven.com' ]
  spec.homepage    = 'https://github.com/lakeraven/lakeraven-ehr'
  spec.summary     = 'SMART-on-FHIR Rails engine for RPMS/VistA EHR integration'
  spec.description = 'Rails engine providing FHIR R4 Patient/Practitioner reads ' \
                     'against RPMS/VistA backends via rpms-rpc. US Core conformant, ' \
                     'SMART auth, PHI audit logging.'
  spec.license     = 'MIT'

  spec.metadata = {
    'homepage_uri' => 'https://github.com/lakeraven/lakeraven-ehr',
    'source_code_uri' => 'https://github.com/lakeraven/lakeraven-ehr',
    'changelog_uri' => 'https://github.com/lakeraven/lakeraven-ehr/blob/main/CHANGELOG.md'
  }

  spec.required_ruby_version = '>= 3.4.0'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['{app,config,db,docs,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']
  end

  spec.add_dependency 'csv'
  spec.add_dependency 'doorkeeper', '~> 5.8'
  spec.add_dependency 'pundit', '~> 2.4'
  spec.add_dependency 'rails', '>= 8.1.0'
  spec.add_dependency 'rpms-rpc', '~> 0.1'
end
