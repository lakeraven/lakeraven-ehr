# frozen_string_literal: true

require "test_helper"
require "prism"

module Lakeraven
  module EHR
    # A FHIR search that fails must say so (#656). An index action that
    # rescues every error and renders an empty Bundle tells the client
    # "no such records" when the truth is "could not read them", and for a
    # resource that gates disclosure that is the most dangerous wrong answer.
    #
    # Enforced by parsing the source: every routed FHIR search (GET [type])
    # names a controller#index, and no rescue in that method may catch
    # everything. Rescuing a named error the action knows how to answer
    # (a bad parameter, an unknown ValueSet) is fine.
    class FhirIndexFailureConventionTest < ActiveSupport::TestCase
      ROOT = File.expand_path("../..", __dir__).freeze
      CATCH_ALL = %w[StandardError Exception].freeze

      test "the detector flags a catch-all rescue and passes a named one" do
        bare = <<~RUBY
          def index
            render_bundle(read)
          rescue => e
            render_bundle([])
          end
        RUBY
        standard = bare.sub("rescue => e", "rescue StandardError")
        named = bare.sub("rescue => e", "rescue ArgumentError")

        assert_equal 1, catch_all_rescues(bare, "index").size
        assert_equal 1, catch_all_rescues(standard, "index").size
        assert_empty catch_all_rescues(named, "index")
      end

      test "the routes name at least one FHIR search to check" do
        assert_includes fhir_index_controllers, "lakeraven/ehr/patients"
      end

      test "no FHIR search rescues every error" do
        offenders = fhir_index_controllers.flat_map do |controller|
          path = File.join(ROOT, "app", "controllers", "#{controller}_controller.rb")
          catch_all_rescues(File.read(path), "index").map { |line| "#{path.delete_prefix("#{ROOT}/")}:#{line}" }
        end

        assert_empty offenders,
          "A FHIR index must not turn every failure into an answer; rescue only errors it can name:\n" \
          "#{offenders.join("\n")}"
      end

      private

      # The controllers behind GET [type], read from the engine's routes:
      # every path whose only segment is a FHIR type.
      def fhir_index_controllers
        Lakeraven::EHR::Engine.routes.routes.filter_map { |route|
          segments = route.path.spec.to_s.delete_suffix("(.:format)").split("/").reject(&:empty?)
          next unless route.verb == "GET" && segments.size == 1 && segments.first.match?(/\A[A-Z][A-Za-z]+\z/)
          next unless route.defaults[:action] == "index"

          route.defaults[:controller]
        }.uniq
      end

      # Line numbers of the rescue clauses in method +name+ that catch every
      # error: a bare rescue, or one naming StandardError or Exception.
      def catch_all_rescues(source, name)
        lines = []
        each_node(Prism.parse(source).value) do |node|
          next unless node.is_a?(Prism::DefNode) && node.name.to_s == name

          each_node(node) do |inner|
            next unless inner.is_a?(Prism::RescueNode)

            caught = inner.exceptions.map { |exception| exception.slice.delete_prefix("::") }
            lines << inner.location.start_line if caught.empty? || caught.intersect?(CATCH_ALL)
          end
        end
        lines
      end

      def each_node(node, &block)
        yield node
        node.compact_child_nodes.each { |child| each_node(child, &block) }
      end
    end
  end
end
