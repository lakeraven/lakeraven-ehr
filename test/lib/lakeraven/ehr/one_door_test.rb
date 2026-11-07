# frozen_string_literal: true

require "test_helper"
require "prism"
require "find"

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
    # A reference is client-resolving when it is a call on a gem API module
    # or client class, a client accessor on the root module, the registry or
    # the gem configuration, reflective dispatch on the root module, or a gem
    # constant taken as a value (an argument, a default, an assignment, a
    # pattern, an operand of `==` or `<=`), because a module held in a variable
    # resolves the client the moment it is called, wherever that happens.
    # Error classes and pure parsers are allowed everywhere, by rule.
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

      # Named exemptions (6e): a path plus its reason, no wildcards. An
      # exemption applies to that exact path and nothing else, and a file
      # named here must still hold a hit, so an exemption that outlives its
      # reference fails the test instead of lingering.
      EXEMPTIONS = {
        "app/models/lakeraven/ehr/backend_registry.rb" =>
          "The rpms backend's client source (#646): gateways get their client through " \
          "BackendRegistry.current, so the registry's registration resolves RpmsRpc.client " \
          "by design; ADR 0013 6e lists it, and it is exempt by name, not moved, so that no " \
          "synonym of RpmsRpc.client exists outside the door."
      }.freeze

      # The reference scanner. One instance per source string; `hits` are the
      # client-resolving references, `scope_openers` the with_client/new_client
      # calls, each as [line, ref]. Every site is reported once.
      class Scanner
        TYPE_CHECKS = %i[is_a? kind_of? instance_of?].freeze
        CLIENT_CLASSES = %w[MockClient CiaClient Client].freeze
        # Calls on the root module that resolve, build or install a client.
        # Any other `RpmsRpc.<name>` whose name mentions a client or starts
        # with `mock` is one too (`scoped_client`, `client_for`, `mock_fhir!`),
        # so a sibling accessor added to the gem is caught without a change
        # here. `RpmsRpc.configuration` and `RpmsRpc.respond_to?` are not:
        # one is a settings object (its client accessors are caught below),
        # the other a probe, like `defined?`.
        ROOT_MODULE_CALLS = %i[client fhir_client scoped_client client_for configure mock! mock_fhir! with_client].freeze
        # Reflective dispatch on the root module reaches any of those by a
        # name the scan cannot read, so the dispatch itself is the reference.
        REFLECTIVE_CALLS = %i[send __send__ public_send method public_method singleton_method instance_method const_get].freeze
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
          # Nodes already judged by their parent (a call's constant receiver,
          # a type check's argument), so the bare-constant rule does not
          # report the same site a second time.
          @judged = Set.new.compare_by_identity
        end

        def scan
          result = Prism.parse(@source)
          raise "#{@path}: #{result.errors.map(&:message).join('; ')}" if result.failure?

          walk(result.value)
          self
        end

        private

        def walk(node)
          return if node.nil? || @judged.include?(node)

          case node
          when Prism::DefinedNode then return # a constant probe, not a reference
          when Prism::ConstantPathNode, Prism::ConstantReadNode then return flag_bare_constant(node)
          when Prism::CallNode then visit_call(node)
          when Prism::WhenNode then visit_when(node)
          end

          node.compact_child_nodes.each { |child| walk(child) }
        end

        # A gem constant taken as a value: `via: RpmsRpc::Tribal`, `m =
        # RpmsRpc::Patient`, `in RpmsRpc::MockClient`, `x.class ==
        # RpmsRpc::MockClient`, `RpmsRpc::SessionPool`, the root module
        # itself. Error classes (a last segment ending in `Error`) and pure
        # parsers are allowed by rule; `defined?(...)` never reaches here.
        def flag_bare_constant(node)
          segs = segments(node)
          hit(node, segs.join("::")) if client_resolving_constant?(segs)
        end

        def visit_call(node)
          receiver = node.receiver
          receiver_segments = segments(receiver)
          # A constant receiver is judged with its call, here, not as a value.
          @judged << receiver if receiver_segments

          if receiver_segments && receiver_segments.first == "RpmsRpc"
            visit_rpms_rpc_call(node, receiver_segments)
          elsif node.name == :new_client && receiver_segments&.last == "RpmsSessions"
            scope_opener(node, "#{receiver_segments.join('::')}.new_client")
          elsif client_accessor?(node.name)
            visit_client_accessor(node, receiver)
          end

          flag_type_check(node)
        end

        def visit_rpms_rpc_call(node, receiver_segments)
          ref = "#{receiver_segments.join('::')}.#{node.name}"
          if receiver_segments.length == 1
            hit(node, ref) if root_module_call?(node.name)
            scope_opener(node, ref) if node.name == :with_client
          elsif client_resolving_constant?(receiver_segments)
            hit(node, ref)
          end
        end

        # A client accessor (`client`, `client=`, `fhir_client`, `fhir_client=`)
        # on `RpmsRpc.configuration`, or on anything reached from the registry
        # (`BackendRegistry.current.client`, `BackendRegistry.fetch(:rpms).client`),
        # whatever namespace prefix the registry carries. `r = BackendRegistry
        # .current; r.client` is not seen: the scan is by reference, and
        # tracking a local variable to its value is out of its scope.
        def visit_client_accessor(node, receiver)
          return unless receiver.is_a?(Prism::CallNode)

          inner = segments(receiver.receiver)
          return if inner.nil?

          if receiver.name == :configuration && inner == [ "RpmsRpc" ]
            hit(node, "RpmsRpc.configuration.#{node.name}")
          elsif inner.last == "BackendRegistry"
            hit(node, "#{inner.join('::')}.#{receiver.name}.#{node.name}")
          end
        end

        # `x.is_a?(RpmsRpc::MockClient)` and friends, named for what they are.
        # The bare-constant rule would catch the argument anyway; this gives
        # the site its name and judges the argument so it is reported once.
        # `RpmsRpc::Client === x` is a call on RpmsRpc::Client and is caught
        # by visit_rpms_rpc_call.
        def flag_type_check(node)
          return unless TYPE_CHECKS.include?(node.name)

          Array(node.arguments&.arguments).each do |argument|
            segs = segments(argument)
            next unless client_class?(segs)

            @judged << argument
            hit(node, "#{node.name}(#{segs.join('::')})")
          end
        end

        # `case x when RpmsRpc::Client` is an implicit ===. (`case x in
        # RpmsRpc::Client` is a pattern, and its constant is a value caught by
        # the bare-constant rule.)
        def visit_when(node)
          node.conditions.each do |condition|
            segs = segments(condition)
            next unless client_class?(segs)

            @judged << condition
            hit(condition, "when #{segs.join('::')}")
          end
        end

        def root_module_call?(name)
          ROOT_MODULE_CALLS.include?(name) || REFLECTIVE_CALLS.include?(name) || name.to_s.match?(/client|\Amock/)
        end

        def client_accessor?(name)
          name.to_s.include?("client")
        end

        def client_class?(segs)
          segs && segs.length == 2 && segs.first == "RpmsRpc" && CLIENT_CLASSES.include?(segs.last)
        end

        # `RpmsRpc`, or `RpmsRpc::<Const>[::...]`, unless an error class or a
        # pure parser.
        def client_resolving_constant?(segs)
          segs && segs.first == "RpmsRpc" && !error_class?(segs) && !pure_parser?(segs)
        end

        def error_class?(segs)
          segs.last.end_with?("Error")
        end

        def pure_parser?(segs)
          segs.length > 1 && PURE_PARSERS.include?(segs[1])
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

      test "every named exemption still holds a hit" do
        EXEMPTIONS.each do |path, reason|
          assert_not_empty scan_engine.fetch(path).hits,
                           "exemption #{path} is stale: the scan finds no client-resolving reference in it, " \
                           "so the reason (#{reason}) no longer applies; remove the exemption"
        end
      end

      test "the scanner flags every client-resolving form" do
        {
          # a call on a gem API module or client class
          "RpmsRpc::Patient.brief_header(1)" => "RpmsRpc::Patient.brief_header",
          "::RpmsRpc::Scheduling.clinic_setup" => "RpmsRpc::Scheduling.clinic_setup",
          "RpmsRpc::Tribal\n  .enrollment(dfn)" => "RpmsRpc::Tribal.enrollment",
          "RpmsRpc::A::B.m" => "RpmsRpc::A::B.m",
          "RpmsRpc::SessionPool.new" => "RpmsRpc::SessionPool.new",
          "RpmsRpc::MockClient.new" => "RpmsRpc::MockClient.new",
          # the root module's client accessors, their siblings and reflective dispatch
          "RpmsRpc.client" => "RpmsRpc.client",
          "RpmsRpc.fhir_client" => "RpmsRpc.fhir_client",
          "RpmsRpc.scoped_client" => "RpmsRpc.scoped_client",
          "RpmsRpc.client_for(key)" => "RpmsRpc.client_for",
          "RpmsRpc.configure { }" => "RpmsRpc.configure",
          "RpmsRpc.mock!" => "RpmsRpc.mock!",
          "RpmsRpc.mock_fhir!" => "RpmsRpc.mock_fhir!",
          "RpmsRpc.with_client(c) { }" => "RpmsRpc.with_client",
          "RpmsRpc.send(:client)" => "RpmsRpc.send",
          "RpmsRpc.__send__(:client)" => "RpmsRpc.__send__",
          "::RpmsRpc.public_send(name)" => "RpmsRpc.public_send",
          "RpmsRpc.method(:client).call" => "RpmsRpc.method",
          "RpmsRpc.const_get(:MockClient)" => "RpmsRpc.const_get",
          # the configuration's client accessors, reads and writes
          "RpmsRpc.configuration.client" => "RpmsRpc.configuration.client",
          "RpmsRpc.configuration.client = x" => "RpmsRpc.configuration.client=",
          "RpmsRpc.configuration.fhir_client" => "RpmsRpc.configuration.fhir_client",
          "RpmsRpc.configuration.fhir_client = x" => "RpmsRpc.configuration.fhir_client=",
          # the registry's client, under any prefix and through any lookup
          "BackendRegistry.current.client" => "BackendRegistry.current.client",
          "Lakeraven::EHR::BackendRegistry.current.client" => "Lakeraven::EHR::BackendRegistry.current.client",
          "BackendRegistry.fetch(:rpms).client" => "BackendRegistry.fetch.client",
          "::Lakeraven::EHR::BackendRegistry.fetch(name).client" => "Lakeraven::EHR::BackendRegistry.fetch.client",
          # a client class as a type check
          "x.is_a?(RpmsRpc::MockClient)" => "is_a?(RpmsRpc::MockClient)",
          "x.kind_of?(::RpmsRpc::CiaClient)" => "kind_of?(RpmsRpc::CiaClient)",
          "x.instance_of?(RpmsRpc::Client)" => "instance_of?(RpmsRpc::Client)",
          "RpmsRpc::Client === x" => "RpmsRpc::Client.===",
          "case x\nwhen RpmsRpc::MockClient then 1\nend" => "when RpmsRpc::MockClient",
          "case x\nin RpmsRpc::MockClient then 1\nend" => "RpmsRpc::MockClient",
          "x.class == RpmsRpc::MockClient" => "RpmsRpc::MockClient",
          "x.class <= RpmsRpc::Client" => "RpmsRpc::Client",
          # a gem module, client class or the root module taken as a value
          "pool = RpmsRpc::SessionPool" => "RpmsRpc::SessionPool",
          "def f(via: ::RpmsRpc::Tribal) = via.enrollment(1)" => "RpmsRpc::Tribal",
          "m = RpmsRpc::Patient" => "RpmsRpc::Patient",
          "klass = RpmsRpc::MockClient" => "RpmsRpc::MockClient",
          "use(RpmsRpc::Scheduling)" => "RpmsRpc::Scheduling",
          "MAX = ::RpmsRpc::Notifications::COMMENT_MAX" => "RpmsRpc::Notifications::COMMENT_MAX",
          "class Foo < RpmsRpc::Client; end" => "RpmsRpc::Client",
          "m = RpmsRpc" => "RpmsRpc",
          "f(::RpmsRpc)" => "RpmsRpc"
        }.each do |source, expected_ref|
          refs = Scanner.scan(source).hits.map(&:last)
          assert_includes refs, expected_ref, "expected the scanner to flag #{source.inspect}"
        end

        split_call = Scanner.scan("x = 1\nRpmsRpc::Tribal\n  .enrollment(dfn)").hits
        assert_equal [ [ 2, "RpmsRpc::Tribal.enrollment" ] ], split_call, "a split call is reported once, at its first line"
      end

      test "the scanner reports each site once" do
        {
          "RpmsRpc::Patient.brief_header(1)" => [ "RpmsRpc::Patient.brief_header" ],
          "x.is_a?(RpmsRpc::MockClient)" => [ "is_a?(RpmsRpc::MockClient)" ],
          "case x\nwhen RpmsRpc::MockClient then 1\nend" => [ "when RpmsRpc::MockClient" ],
          "RpmsRpc::Client === x" => [ "RpmsRpc::Client.===" ],
          "RpmsRpc.configuration.client" => [ "RpmsRpc.configuration.client" ],
          "RpmsRpc.send(:client)" => [ "RpmsRpc.send" ],
          "def f(via: RpmsRpc::Tribal) = via.enrollment(1)" => [ "RpmsRpc::Tribal" ]
        }.each do |source, expected_refs|
          assert_equal expected_refs, Scanner.scan(source).hits.map(&:last), "expected one hit for #{source.inspect}"
        end
      end

      test "the scanner leaves error classes, parsers, comments, strings and probes alone" do
        [
          # error classes rescued, raised, compared, built or checked
          "begin\n  x\nrescue RpmsRpc::Client::ConnectionError, RpmsRpc::NotConfiguredError => e\n  e\nend",
          "rescue_from RpmsRpc::SessionPool::PoolExhaustedError, with: :pool_exhausted",
          "rescue_from ::RpmsRpc::Error, with: :render_rpms_unavailable",
          "e.is_a?(::RpmsRpc::Client::RpcRefusedError)",
          "raise RpmsRpc::Client::RpcError, \"refused\"",
          "RpmsRpc::Client::ConnectionError.new(\"x\")",
          "raise RpmsRpc::NotConfiguredError.new(\"x\")",
          "RpmsRpc::Error === e",
          "case e\nwhen RpmsRpc::Error then 1\nend",
          "case e\nin RpmsRpc::Client::RpcError then 1\nend",
          "class Unreadable < RpmsRpc::Client::RpcError; end",
          "errors = [ RpmsRpc::Error, RpmsRpc::SessionPool::PoolExhaustedError ]",
          # pure parsers, called or held
          "RpmsRpc::FilemanDateParser.parse(x)",
          "::RpmsRpc::FilemanDateParser.to_fileman(date)",
          "parser = RpmsRpc::FilemanDateParser",
          # comments, strings and probes
          "# RpmsRpc::Patient.brief_header(1)",
          "\"RpmsRpc.client\"",
          "defined?(RpmsRpc::MockClient)",
          "defined?(RpmsRpc::SessionPool)",
          "defined?(RpmsRpc)",
          "RpmsRpc.respond_to?(:fhir_client)",
          # another namespace's RpmsRpc, and settings that are not a client
          "Other::RpmsRpc.client",
          "Other::RpmsRpc::Patient.brief_header(1)",
          "x = Other::RpmsRpc",
          "RpmsRpc.configuration.timeout",
          "RpmsRpc.configuration"
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
        EXEMPTIONS.each do |path, reason|
          assert File.file?(ROOT.join(path)), "exemption #{path} is not a file"
          assert_not door?(path), "exemption #{path} is inside the door and needs no exemption"
          assert_kind_of String, reason, "exemption #{path} has no reason"
          assert_not reason.strip.empty?, "exemption #{path} has no reason"
        end
      end

      test "the scan sees every ruby file" do
        scanned = scan_engine.keys
        # Walked independently of the scanner's glob, so the two cannot agree
        # by construction.
        expected = SCANNED_DIRECTORIES.flat_map do |dir|
          found = []
          Find.find(ROOT.join(dir).to_s) do |path|
            found << relative(path) if File.file?(path) && File.extname(path) == ".rb"
          end
          found
        end

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
