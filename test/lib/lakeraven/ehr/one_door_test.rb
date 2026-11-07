# frozen_string_literal: true

require "test_helper"
require "prism"

module Lakeraven
  module EHR
    # ADR 0013, decision 6e ("One door, with its real reach"), first slice of #762.
    #
    # The code that opens and holds an RPMS scope is one layer (the door), and
    # a client-resolving reference anywhere else in the engine's app/ and lib/
    # fails this test. The scan is by reference over the Prism AST, never a
    # grep: comments and strings do not match, a call split across lines does,
    # and `::RpmsRpc::X.y` is the same reference as `RpmsRpc::X.y`.
    #
    # The scanner lives in this file so that the code under test cannot
    # change it, and its self-tests on inline source prove it is not vacuous.
    class OneDoorTest < ActiveSupport::TestCase
      ROOT = Lakeraven::EHR::Engine.root
      SCANNED_DIRECTORIES = %w[app lib].freeze

      # The door (6e): files allowed to hold a client-resolving reference.
      # Explicit paths, relative to the engine root. "The console" has no
      # file in app/ or lib/ today, so it is not listed.
      DOOR_FILES = %w[
        lib/lakeraven/ehr/rpms_sessions.rb
        app/controllers/concerns/lakeraven/ehr/rpms_user_scope.rb
        app/services/lakeraven/ehr/authentication_service.rb
        app/controllers/lakeraven/ehr/sessions_controller.rb
        lib/lakeraven/ehr/engine.rb
      ].freeze
      DOOR_DIRECTORIES = %w[app/gateways].freeze

      # Narrower than the door (6e): the only two files that may open a scope
      # or build a client.
      SCOPE_OPENERS = %w[
        lib/lakeraven/ehr/rpms_sessions.rb
        app/services/lakeraven/ehr/authentication_service.rb
      ].freeze

      # Named exemptions. An exemption is a path plus its reason, no wildcards
      # (6e). There are none in this slice: every leak moves behind a gateway.
      EXEMPTIONS = {}.freeze

      # The reference scanner. One instance per source string; `hits` are the
      # client-resolving references, `scope_openers` the with_client/new_client
      # calls, each as [line, ref].
      class Scanner
        TYPE_CHECKS = %i[is_a? kind_of? instance_of?].freeze
        CLIENT_CLASSES = %w[MockClient CiaClient Client].freeze
        ROOT_MODULE_CALLS = %i[client fhir_client configure mock! with_client].freeze
        PURE_PARSERS = %w[FilemanDateParser].freeze

        attr_reader :hits, :scope_openers

        def self.scan(source, path: "(inline)")
          new(source, path).tap(&:scan)
        end

        def initialize(source, path)
          @source = source
          @path = path
          @hits = []
          @scope_openers = []
        end

        def scan
          result = Prism.parse(@source)
          raise "#{@path}: #{result.errors.map(&:message).join('; ')}" if result.failure?

          walk(result.value)
          self
        end

        private

        def walk(node)
          return if node.nil?

          case node
          when Prism::DefinedNode then return # a constant probe, not a reference
          when Prism::ConstantPathNode, Prism::ConstantReadNode then return flag_bare_constant(node)
          when Prism::CallNode then visit_call(node)
          when Prism::WhenNode then visit_when(node)
          end

          node.compact_child_nodes.each { |child| walk(child) }
        end

        # A constant on its own (rescue, rescue_from, raise, an argument) is not
        # client-resolving, except RpmsRpc::SessionPool itself.
        def flag_bare_constant(node)
          hit(node, "RpmsRpc::SessionPool") if session_pool?(segments(node))
        end

        def visit_call(node)
          receiver = node.receiver
          receiver_segments = segments(receiver)

          if receiver_segments && receiver_segments.first == "RpmsRpc"
            visit_rpms_rpc_call(node, receiver_segments)
          elsif node.name == :client || node.name == :client=
            visit_client_read(node, receiver)
          elsif node.name == :new_client && receiver_segments&.last == "RpmsSessions"
            scope_opener(node, "#{receiver_segments.join('::')}.new_client")
          end

          flag_type_check(node)
        end

        def visit_rpms_rpc_call(node, receiver_segments)
          ref = "#{receiver_segments.join('::')}.#{node.name}"
          if receiver_segments.length == 1
            hit(node, ref) if ROOT_MODULE_CALLS.include?(node.name)
            scope_opener(node, ref) if node.name == :with_client
          elsif !PURE_PARSERS.include?(receiver_segments[1])
            hit(node, ref)
          end
        end

        # `.client` on `RpmsRpc.configuration` or on `BackendRegistry.current`,
        # whatever namespace prefix the registry carries.
        def visit_client_read(node, receiver)
          return unless receiver.is_a?(Prism::CallNode)

          inner = segments(receiver.receiver)
          return if inner.nil?

          if receiver.name == :configuration && inner == [ "RpmsRpc" ]
            hit(node, "RpmsRpc.configuration.#{node.name}")
          elsif receiver.name == :current && inner.last == "BackendRegistry"
            hit(node, "#{inner.join('::')}.current.#{node.name}")
          end
        end

        # `x.is_a?(RpmsRpc::MockClient)` and friends. `RpmsRpc::Client === x`
        # is a call on RpmsRpc::Client and is caught by visit_rpms_rpc_call.
        def flag_type_check(node)
          return unless TYPE_CHECKS.include?(node.name)

          Array(node.arguments&.arguments).each do |argument|
            next unless client_class?(segments(argument))

            hit(node, "#{node.name}(#{segments(argument).join('::')})")
          end
        end

        # `case x when RpmsRpc::Client` is an implicit ===.
        def visit_when(node)
          node.conditions.each do |condition|
            hit(condition, "when #{segments(condition).join('::')}") if client_class?(segments(condition))
          end
        end

        def client_class?(segs)
          segs && segs.length == 2 && segs.first == "RpmsRpc" && CLIENT_CLASSES.include?(segs.last)
        end

        def session_pool?(segs)
          segs == %w[RpmsRpc SessionPool]
        end

        # The constant path as names, `::` prefix dropped: `::RpmsRpc::A::B` and
        # `RpmsRpc::A::B` are both ["RpmsRpc", "A", "B"]. nil for anything that
        # is not a static constant path (`self.class::X`, a variable, a call).
        def segments(node)
          case node
          when Prism::ConstantReadNode then [ node.name.to_s ]
          when Prism::ConstantPathNode
            return [ node.name.to_s ] if node.parent.nil?

            parent = segments(node.parent)
            parent && parent + [ node.name.to_s ]
          end
        end

        def hit(node, ref)
          @hits << [ node.location.start_line, ref ]
        end

        def scope_opener(node, ref)
          @scope_openers << [ node.location.start_line, ref ]
        end
      end

      test "no client-resolving reference outside the door" do
        leaks = scan_engine.reject { |path, _scanner| door?(path) || EXEMPTIONS.key?(path) }
                           .flat_map { |path, scanner| scanner.hits.map { |line, ref| "#{path}:#{line} #{ref}" } }

        assert_empty leaks,
                     "client-resolving references outside the door (ADR 0013 decision 6e); move each " \
                     "behind a gateway or name the path with its reason in EXEMPTIONS:\n  #{leaks.join("\n  ")}"
      end

      test "with_client and new_client only in RpmsSessions and AuthenticationService" do
        openers = scan_engine.reject { |path, _scanner| SCOPE_OPENERS.include?(path) }
                             .flat_map { |path, scanner| scanner.scope_openers.map { |line, ref| "#{path}:#{line} #{ref}" } }

        assert_empty openers,
                     "RpmsRpc.with_client and RpmsSessions.new_client are permitted only in " \
                     "#{SCOPE_OPENERS.join(' and ')} (ADR 0013 decision 6e):\n  #{openers.join("\n  ")}"
      end

      test "the scanner flags every client-resolving form" do
        {
          "RpmsRpc::Patient.brief_header(1)" => "RpmsRpc::Patient.brief_header",
          "::RpmsRpc::Scheduling.clinic_setup" => "RpmsRpc::Scheduling.clinic_setup",
          "RpmsRpc::Tribal\n  .enrollment(dfn)" => "RpmsRpc::Tribal.enrollment",
          "RpmsRpc.client" => "RpmsRpc.client",
          "RpmsRpc.configuration.client" => "RpmsRpc.configuration.client",
          "RpmsRpc.fhir_client" => "RpmsRpc.fhir_client",
          "RpmsRpc.configure { }" => "RpmsRpc.configure",
          "RpmsRpc.mock!" => "RpmsRpc.mock!",
          "RpmsRpc.with_client(c) { }" => "RpmsRpc.with_client",
          "RpmsRpc::SessionPool.new" => "RpmsRpc::SessionPool.new",
          "pool = RpmsRpc::SessionPool" => "RpmsRpc::SessionPool",
          "BackendRegistry.current.client" => "BackendRegistry.current.client",
          "Lakeraven::EHR::BackendRegistry.current.client" => "Lakeraven::EHR::BackendRegistry.current.client",
          "x.is_a?(RpmsRpc::MockClient)" => "is_a?(RpmsRpc::MockClient)",
          "x.kind_of?(::RpmsRpc::CiaClient)" => "kind_of?(RpmsRpc::CiaClient)",
          "x.instance_of?(RpmsRpc::Client)" => "instance_of?(RpmsRpc::Client)",
          "RpmsRpc::Client === x" => "RpmsRpc::Client.===",
          "case x\nwhen RpmsRpc::MockClient then 1\nend" => "when RpmsRpc::MockClient",
          "RpmsRpc::A::B.m" => "RpmsRpc::A::B.m"
        }.each do |source, expected_ref|
          refs = Scanner.scan(source).hits.map(&:last)
          assert_includes refs, expected_ref, "expected the scanner to flag #{source.inspect}"
        end

        split_call = Scanner.scan("x = 1\nRpmsRpc::Tribal\n  .enrollment(dfn)").hits
        assert_equal [ [ 2, "RpmsRpc::Tribal.enrollment" ] ], split_call, "a split call is reported once, at its first line"
      end

      test "the scanner leaves error classes, parsers, comments, strings and probes alone" do
        [
          "begin\n  x\nrescue RpmsRpc::Client::ConnectionError, RpmsRpc::NotConfiguredError => e\n  e\nend",
          "rescue_from RpmsRpc::SessionPool::PoolExhaustedError, with: :pool_exhausted",
          "rescue_from ::RpmsRpc::Error, with: :render_rpms_unavailable",
          "e.is_a?(::RpmsRpc::Client::RpcRefusedError)",
          "raise RpmsRpc::Client::RpcError, \"refused\"",
          "RpmsRpc::FilemanDateParser.parse(x)",
          "::RpmsRpc::FilemanDateParser.to_fileman(date)",
          "# RpmsRpc::Patient.brief_header(1)",
          "\"RpmsRpc.client\"",
          "defined?(RpmsRpc::MockClient)",
          "defined?(RpmsRpc::SessionPool)",
          "Other::RpmsRpc.client",
          "RpmsRpc.configuration.timeout"
        ].each do |source|
          scanner = Scanner.scan(source)
          assert_empty scanner.hits, "expected the scanner not to flag #{source.inspect}"
          assert_empty scanner.scope_openers, "expected no scope opener in #{source.inspect}"
        end
      end

      test "the scanner flags with_client and new_client as scope openers" do
        {
          "RpmsRpc.with_client(c) {}" => "RpmsRpc.with_client",
          "::RpmsRpc.with_client(c) { |x| x }" => "RpmsRpc.with_client",
          "RpmsSessions.new_client" => "RpmsSessions.new_client",
          "Lakeraven::EHR::RpmsSessions.new_client" => "Lakeraven::EHR::RpmsSessions.new_client"
        }.each do |source, expected_ref|
          refs = Scanner.scan(source).scope_openers.map(&:last)
          assert_equal [ expected_ref ], refs, "expected the scope-opener detector to flag #{source.inspect}"
        end

        [ "new_client", "self.new_client", "@pool.with_client(key) { |c| c }", "Other.new_client" ].each do |source|
          assert_empty Scanner.scan(source).scope_openers, "expected no scope opener in #{source.inspect}"
        end
      end

      test "the door list names files that exist" do
        (DOOR_FILES + SCOPE_OPENERS).each do |path|
          assert File.file?(ROOT.join(path)), "door entry #{path} is not a file; a rename cannot silently widen the door"
        end
        DOOR_DIRECTORIES.each do |path|
          assert File.directory?(ROOT.join(path)), "door entry #{path} is not a directory"
        end
        assert_empty EXEMPTIONS.keys.grep(/[*?{\[]/), "an exemption is a path, not a wildcard"
        EXEMPTIONS.each_key { |path| assert File.file?(ROOT.join(path)), "exemption #{path} is not a file" }
      end

      test "the scan sees every ruby file" do
        scanned = scan_engine.keys
        expected = Dir[ROOT.join("{#{SCANNED_DIRECTORIES.join(',')}}/**/*.rb").to_s].map { |path| relative(path) }

        assert_operator scanned.length, :>, 0, "the scan parsed no files"
        assert_equal expected.sort, scanned.sort
      end

      private

      # Every Ruby file under the engine's app/ and lib/, as { relative path => Scanner }.
      def scan_engine
        @scan_engine ||= SCANNED_DIRECTORIES.flat_map { |dir| Dir[ROOT.join(dir, "**", "*.rb").to_s] }
                                            .sort
                                            .to_h { |path| [ relative(path), Scanner.scan(File.read(path), path: path) ] }
      end

      def relative(path)
        Pathname.new(path).relative_path_from(ROOT).to_s
      end

      def door?(path)
        DOOR_FILES.include?(path) || DOOR_DIRECTORIES.any? { |dir| path.start_with?("#{dir}/") }
      end
    end
  end
end
