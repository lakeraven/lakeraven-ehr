# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # Shared examples for LocalAdapter and MockAdapter blank-input behaviour.
      module BlankInputAdapterExamples
        BLANK_VALUES = [ nil, "", "   " ].freeze

        def assert_blank_inputs_never_verify(adapter, valid_system:, valid_code:, valueset_id:)
          BLANK_VALUES.each do |blank|
            assert_nil adapter.lookup_code(blank, valid_code),
                       "lookup_code(#{blank.inspect}, code) must be nil"
            assert_nil adapter.lookup_code(valid_system, blank),
                       "lookup_code(system, #{blank.inspect}) must be nil"
            refute adapter.validate_code(blank, valid_code, valueset_id: valueset_id),
                   "validate_code(#{blank.inspect}, code) must be false"
            refute adapter.validate_code(valid_system, blank, valueset_id: valueset_id),
                   "validate_code(system, #{blank.inspect}) must be false"
          end
        end
      end
    end
  end
end
