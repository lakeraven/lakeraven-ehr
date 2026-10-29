# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # Interface for a terminology backend. Subclasses implement every
      # operation; this class raises NotImplementedError for each one.
      class BaseAdapter
        def expand_valueset(_valueset_id)
          raise NotImplementedError, "#{self.class}#expand_valueset"
        end

        def get_valueset(_valueset_id)
          raise NotImplementedError, "#{self.class}#get_valueset"
        end

        def list_valuesets
          raise NotImplementedError, "#{self.class}#list_valuesets"
        end

        def search(_query)
          raise NotImplementedError, "#{self.class}#search"
        end

        def lookup_code(_system, _code)
          raise NotImplementedError, "#{self.class}#lookup_code"
        end

        def validate_code(_system, _code, valueset_id:)
          raise NotImplementedError, "#{self.class}#validate_code"
        end

        def backend
          raise NotImplementedError, "#{self.class}#backend"
        end
      end
    end
  end
end
