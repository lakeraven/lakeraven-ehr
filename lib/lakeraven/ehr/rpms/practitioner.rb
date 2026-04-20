# frozen_string_literal: true

module Lakeraven
  module EHR
    module Rpms
      class Practitioner < Repository
        def find(ien)
          return validation_failure("IEN is required") if ien.blank?

          execute(PractitionerGateway, :find, ien).and_then do |practitioner|
            if practitioner.nil?
              Integrations::Result.failure(
                Integrations::Error.new(code: :not_found, message: "Practitioner not found for IEN: #{ien}")
              )
            else
              Integrations::Result.success(practitioner)
            end
          end
        end

        def search(name_pattern)
          execute(PractitionerGateway, :search, name_pattern)
        end

        def find_by_duz(duz)
          return validation_failure("DUZ is required") if duz.blank?

          execute(PractitionerGateway, :find_by_duz, duz)
        end

        private

        def validation_failure(message)
          Integrations::Result.failure(
            Integrations::Error.new(code: :validation_failed, message: message)
          )
        end
      end
    end
  end
end
