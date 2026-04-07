# frozen_string_literal: true

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR

      # Tell Zeitwerk that "ehr" should resolve to the EHR constant
      # (capitalized acronym) rather than the default "Ehr". Without
      # this, autoloading from app/services/lakeraven/ehr/foo.rb would
      # try to find Lakeraven::Ehr::Foo and not find Lakeraven::EHR::Foo.
      config.before_initialize do
        Rails.autoloaders.each do |loader|
          loader.inflector.inflect("ehr" => "EHR")
        end
      end
    end
  end
end
