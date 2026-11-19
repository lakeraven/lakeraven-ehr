# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #969: the +if:+ option of disclosure_surface. It names a predicate
    # method by Symbol and nothing else, and a predicate that raises closes
    # the surface rather than opening it.
    class DisclosureSurfaceIfTest < ActiveSupport::TestCase
      ABSENT = Object.new.freeze

      # [ label, configured value, fhir_api open ]
      CONFIG_ROWS = [
        [ "the key is absent",             ABSENT,               false ],
        [ "only other surfaces are named", %i[bulk_export ccda], false ],
        [ "fhir_api is opened by name",    %i[fhir_api],         true ]
      ].freeze

      # [ label, predicate body, the rule applies ]
      PREDICATE_ROWS = [
        [ "raises a StandardError", -> { raise "boom" },                     true ],
        [ "raises a NoMethodError", -> { nil.no_such_method_on_nil },        true ],
        [ "returns true",           -> { true },                             true ],
        [ "returns a truthy value", -> { "yes" },                            true ],
        [ "returns false",          -> { false },                            false ],
        [ "returns nil",            -> { nil },                              false ]
      ].freeze

      # [ label, value ]: none is a Symbol, so none may be declared.
      NON_SYMBOL_IFS = [
        [ "a lambda",   -> { true } ],
        [ "a Proc",     proc { true } ],
        [ "true",       true ],
        [ "an Integer", 1 ],
        [ "a String",   "probe?" ]
      ].freeze

      setup { @saved_options = Rails.application.config.x.lakeraven_ehr }
      teardown { Rails.application.config.x.lakeraven_ehr = @saved_options }

      PREDICATE_ROWS.each do |label, body, applies|
        CONFIG_ROWS.each do |config, value, open|
          closed = applies && !open
          test "a rule whose predicate #{label} #{closed ? 'closes' : 'does not close'} the surface when #{config}" do
            configure(value)
            controller = probe(body).new
            assert_equal [ closed ? :fhir_api : nil ], [ controller.send(:closed_disclosure_surface, "show") ]
          end

          test "a request under a predicate that #{label} is #{closed ? 'a bare 404' : 'served'} when #{config}" do
            configure(value)
            klass = probe(body)
            status, _headers, body_parts = klass.action(:show).call(Rack::MockRequest.env_for("/probe"))
            text = +""
            body_parts.each { |part| text << part }
            assert_equal [ closed ? 404 : 204, "" ], [ status, text ]
            assert_equal (closed ? 0 : 1), klass.served
          end
        end
      end

      test "a predicate that raises applies its rule only to the actions the rule names" do
        configure(ABSENT)
        klass = Class.new(ActionController::API) do
          include DisclosureSurfaceGate
          disclosure_surface :fhir_api, only: :show, if: :probe?
          def probe? = raise("boom")
        end
        assert_equal :fhir_api, klass.new.send(:closed_disclosure_surface, "show")
        assert_nil klass.new.send(:closed_disclosure_surface, "index")
      end

      NON_SYMBOL_IFS.each do |label, value|
        test "declaring if: as #{label} raises ArgumentError naming if: and adds no rule" do
          klass = Class.new(ActionController::API) { include DisclosureSurfaceGate }
          error = assert_raises(ArgumentError) { klass.disclosure_surface :fhir_api, if: value }
          assert_match(/\bif:/, error.message)
          assert_empty klass.disclosure_surface_rules
        end
      end

      test "declaring if: as a Symbol is accepted and stored as that Symbol" do
        klass = Class.new(ActionController::API) { include DisclosureSurfaceGate }
        klass.disclosure_surface :fhir_api, if: :probe?
        assert_equal [ { surface: :fhir_api, only: nil, if: :probe? } ], klass.disclosure_surface_rules
      end

      test "a declaration without if: is unconditional" do
        klass = Class.new(ActionController::API) { include DisclosureSurfaceGate }
        klass.disclosure_surface :fhir_api
        assert_equal [ false ], klass.disclosure_surface_rules.map { |rule| rule.key?(:if) }
      end

      private

      # An anonymous controller gating #show on fhir_api under a predicate
      # with +body+. .served counts the times the action itself ran.
      def probe(body)
        Class.new(ActionController::API) do
          include DisclosureSurfaceGate
          disclosure_surface :fhir_api, if: :probe?
          singleton_class.attr_accessor :served
          self.served = 0
          define_method(:probe?, &body)
          define_method(:show) do
            self.class.served += 1
            head :no_content
          end
        end
      end

      def configure(value)
        options = ActiveSupport::OrderedOptions.new
        options[:open_disclosure_surfaces] = value unless value.equal?(ABSENT)
        Rails.application.config.x.lakeraven_ehr = options
      end
    end
  end
end
