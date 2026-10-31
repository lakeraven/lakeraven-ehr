# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Two conventions of the backend registry (#646), enforced by scanning
    # the source:
    #
    # 1. No gateway reaches the rpms-rpc client directly. Gateways get it
    #    from BackendRegistry (through RpcSupport.broker), so a second
    #    backend is a registration, not an edit to every gateway.
    # 2. Only the registry reads the configured backend name. Everything
    #    else asks the capability set, so nothing can branch on "rpms".
    #
    # Comment lines are skipped: prose may name the client.
    class BackendRegistryConventionTest < ActiveSupport::TestCase
      ROOT = File.expand_path("../..", __dir__).freeze
      GATEWAYS = File.join(ROOT, "app", "gateways").freeze
      CORE_ROOTS = %w[app lib config].map { |dir| File.join(ROOT, dir) }.freeze

      GEM = "Rpms" + "Rpc"
      DIRECT_CLIENT = [
        /\b#{GEM}\s*\.\s*client\b/,
        /\b#{GEM}\s*\.\s*configuration\s*\.\s*client\b/,
        /\b#{GEM}\s*\.\s*(?:public_)?send\s*\(\s*[:"']client\b/
      ].freeze

      BACKEND_NAME_READ = /configuration\s*\.\s*backend\b/

      # The registry reads the name, and the configuration declares it.
      BACKEND_NAME_OWNERS = [
        File.join(ROOT, "app", "models", "lakeraven", "ehr", "backend_registry.rb"),
        File.join(ROOT, "lib", "lakeraven", "ehr.rb")
      ].freeze

      test "the matchers flag a direct client reach and ignore the symbolic API" do
        [
          "#{GEM}.client.call_rpc(name)",
          "AuditedBroker.wrap(::#{GEM}.client)",
          "#{GEM}.configuration.client",
          "#{GEM}.public_send(:client)",
          "#{GEM}.send(\"client\")"
        ].each { |line| assert direct_client?(line), "expected flagged: #{line}" }

        [
          "#{GEM}::Patient.find(dfn)",
          "#{GEM}::Client::ConnectionError",
          "BackendRegistry.current.client",
          "# goes through #{GEM}.client"
        ].each { |line| assert_not direct_client?(line), "expected allowed: #{line}" }
      end

      test "no gateway reaches the rpms-rpc client directly" do
        hits = scan(GATEWAYS) { |line| direct_client?(line) }

        assert_empty hits,
          "gateways get their client from BackendRegistry, via RpcSupport.broker (#646):\n#{hits.join("\n")}"
      end

      test "only the registry reads the configured backend name" do
        hits = CORE_ROOTS.flat_map do |root|
          scan(root, except: BACKEND_NAME_OWNERS) { |line| line.match?(BACKEND_NAME_READ) }
        end

        assert_empty hits,
          "ask BackendRegistry.current.provides?(capability), never the backend name (#646):\n#{hits.join("\n")}"
      end

      private

      def direct_client?(line)
        return false if comment?(line)

        DIRECT_CLIENT.any? { |pattern| line.match?(pattern) }
      end

      def comment?(line)
        line.lstrip.start_with?("#")
      end

      def scan(root, except: [])
        Dir.glob(File.join(root, "**", "*.rb")).sort.flat_map do |path|
          next [] if except.include?(path)

          File.readlines(path).each_with_index.filter_map do |line, index|
            next if comment?(line)
            next unless yield(line)

            "#{path.delete_prefix("#{ROOT}/")}:#{index + 1}: #{line.strip}"
          end
        end
      end
    end
  end
end
