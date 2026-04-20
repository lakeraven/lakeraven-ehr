# frozen_string_literal: true

module Lakeraven
  module EHR
    module Integrations
      class Result
        attr_reader :value, :error

        def initialize(value: nil, error: nil, success:)
          @value = value
          @error = error
          @success = success
        end

        def success?
          @success
        end

        def failure?
          !@success
        end

        def value!
          raise error.to_s if failure?
          @value
        end

        def map
          return self if failure?
          Result.success(yield(@value))
        end

        def and_then
          return self if failure?
          yield(@value)
        end

        class << self
          def success(value = nil)
            new(value: value, success: true)
          end

          def failure(error)
            error = wrap_error(error)
            new(error: error, success: false)
          end

          private

          def wrap_error(error)
            case error
            when Error
              error
            when String
              Error.new(code: :unknown, message: error)
            else
              raise ArgumentError, "error must be an Integrations::Error or String, got #{error.class}"
            end
          end
        end
      end
    end
  end
end
