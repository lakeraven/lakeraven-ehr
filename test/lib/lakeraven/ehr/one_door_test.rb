# frozen_string_literal: true

require "test_helper"
require "prism"
require "find"

module Lakeraven
  module EHR
    # ADR 0013, decision 6e ("One door, with its real reach"), first slice of #762.
    #
    # The code that opens and holds an RPMS scope is one layer (the door), and
    # a client-resolving reference anywhere else in the engine fails this
    # test. What is scanned: every .rb file under app/ and lib/, and every
    # .erb template under app/views, compiled to Ruby the way Rails compiles
    # it. The scan is by reference over the Prism AST, never a grep: comments,
    # strings and template text do not match, a call split across lines does,
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
      # ERB templates are executable Ruby too; every .erb under here is scanned.
      TEMPLATE_DIRECTORY = "app/views"

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

        # An ERB template, compiled to Ruby by the implementation and trim
        # mode Rails' own ERB handler uses, then scanned like any Ruby. Only
        # code inside `<% %>` and `<%= %>` reaches the AST: template text
        # becomes a string literal and `<%# %>` comments are dropped. The
        # compiler keeps every newline, so a hit's line is the template's.
        # Rails compiles the result as the body of a method (a template may
        # `yield`, which is not valid at the top level), so it is scanned as
        # one, opened on the template's first line to keep the lines true.
        def self.scan_erb(source, path: "(inline erb)")
          handler = ActionView::Template::Handlers::ERB
          ruby = handler.erb_implementation.new(source.dup, trim: handler.erb_trim_mode == "-").src
          scan("def _template(local_assigns, output_buffer, &_); #{ruby}\nend", path: path)
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
          when Prism::DefinedNode then return probe(node.value) # judged by what `defined?` evaluates
          when Prism::ConstantPathNode, Prism::ConstantReadNode then return flag_bare_constant(node)
          when Prism::CallNode then visit_call(node)
          when Prism::WhenNode then visit_when(node)
          end

          node.compact_child_nodes.each { |child| walk(child) }
        end

        # The operand of `defined?`, judged by what CRuby evaluates of it
        # (compile.c, defined_expr0), which is not "nothing":
        #
        # - A constant is a probe: looked up, never called. Exempt.
        # - A call is not made (`defined?(RpmsRpc.client)` only asks whether
        #   the method exists), but its receiver IS evaluated. A receiver
        #   that is itself a call is really called, so it is walked as
        #   ordinary code and judged by every rule, scope openers included:
        #   `defined?(RpmsRpc.client.object_id)` resolves a client. A constant
        #   receiver is a probe, not a value. Each argument is checked for
        #   definedness in turn, which evaluates its receivers the same way,
        #   so each argument is probed by this same rule.
        # - Anything else fails closed and is walked as ordinary code: a
        #   call's block or `&block` argument, any other receiver, and every
        #   other kind of operand (parentheses, `a && b`, an assignment, a
        #   literal). CRuby evaluates none of several of these (it answers
        #   "expression" or "assignment" from the syntax alone), but no
        #   door-side code needs a gem reference there, so the scan does not
        #   depend on that.
        def probe(node)
          case node
          when nil, Prism::ConstantReadNode, Prism::ConstantPathNode then nil
          when Prism::CallNode then probe_call(node)
          else walk(node)
          end
        end

        def probe_call(node)
          receiver = node.receiver
          walk(receiver) unless segments(receiver)
          Array(node.arguments&.arguments).each { |argument| probe(argument) }
          walk(node.block)
        end

        # A gem constant taken as a value: `via: RpmsRpc::Tribal`, `m =
        # RpmsRpc::Patient`, `in RpmsRpc::MockClient`, `x.class ==
        # RpmsRpc::MockClient`, `RpmsRpc::SessionPool`, the root module
        # itself. Error classes (a last segment ending in `Error`) and pure
        # parsers are allowed by rule; a constant probed by `defined?(...)`
        # never reaches here.
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
        leaks = leaks_in(scan_engine)

        assert_empty leaks,
                     "client-resolving references outside the door (ADR 0013 decision 6e); move each " \
                     "behind a gateway or name the path with its reason in EXEMPTIONS:\n  #{leaks.join("\n  ")}"
      end

      test "with_client and new_client only in RpmsSessions and AuthenticationService" do
        openers = scope_openers_in(scan_engine)

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
          "f(::RpmsRpc)" => "RpmsRpc",
          # a receiver or an argument's receiver that `defined?` evaluates
          "defined?(RpmsRpc.client.object_id)" => "RpmsRpc.client",
          "defined?(::RpmsRpc.client.object_id)" => "RpmsRpc.client",
          "defined?(RpmsRpc.fhir_client.x.y)" => "RpmsRpc.fhir_client",
          "defined?(RpmsRpc::Patient.brief_header(1).x)" => "RpmsRpc::Patient.brief_header",
          "defined?(f(RpmsRpc.client.x))" => "RpmsRpc.client",
          "defined?(x.f(1, RpmsRpc::Patient.brief_header(1).y))" => "RpmsRpc::Patient.brief_header",
          "defined?(RpmsRpc.configuration.client.x)" => "RpmsRpc.configuration.client",
          "defined?(BackendRegistry.current.client.x)" => "BackendRegistry.current.client",
          # fail closed: an operand that is neither a constant nor a call, and a call's block
          "defined?((RpmsRpc.client))" => "RpmsRpc.client",
          "defined?(x = RpmsRpc.client)" => "RpmsRpc.client",
          "defined?(f { RpmsRpc.client })" => "RpmsRpc.client",
          "defined?(f(&RpmsRpc.client))" => "RpmsRpc.client"
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
          "def f(via: RpmsRpc::Tribal) = via.enrollment(1)" => [ "RpmsRpc::Tribal" ],
          "defined?(RpmsRpc.client.object_id)" => [ "RpmsRpc.client" ],
          "defined?(RpmsRpc::Patient.brief_header(1).x)" => [ "RpmsRpc::Patient.brief_header" ],
          "defined?(f(RpmsRpc.client.x))" => [ "RpmsRpc.client" ]
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
          "defined?(::RpmsRpc::MockClient)",
          "RpmsRpc.respond_to?(:fhir_client)",
          # `defined?` of a call asks whether the method exists and does not
          # make the call; a constant receiver or argument is only probed
          "defined?(RpmsRpc.client)",
          "defined?(::RpmsRpc.client)",
          "defined?(RpmsRpc.fhir_client)",
          "defined?(RpmsRpc::Patient.brief_header(1))",
          "defined?(RpmsRpc.with_client(c))",
          "defined?(RpmsSessions.new_client)",
          "defined?(Lakeraven::EHR::RpmsSessions.new_client)",
          "defined?(RpmsRpc.configuration.client)",
          "defined?(f(RpmsRpc::MockClient))",
          "defined?(f(RpmsRpc.client))",
          "defined?(x.y.z)",
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

      test "the scanner flags a scope opener that defined? evaluates" do
        {
          "defined?(RpmsSessions.new_client.object_id)" => "RpmsSessions.new_client",
          "defined?(Lakeraven::EHR::RpmsSessions.new_client.object_id)" => "Lakeraven::EHR::RpmsSessions.new_client",
          "defined?(RpmsRpc.with_client(c).x)" => "RpmsRpc.with_client",
          "defined?(f(RpmsSessions.new_client.x))" => "RpmsSessions.new_client"
        }.each do |source, expected_ref|
          refs = Scanner.scan(source).scope_openers.map(&:last)
          assert_equal [ expected_ref ], refs, "expected the scope-opener detector to flag #{source.inspect}"
        end

        [ "defined?(RpmsSessions.new_client)", "defined?(RpmsRpc.with_client(c))" ].each do |source|
          assert_empty Scanner.scan(source).scope_openers, "expected no scope opener in #{source.inspect}"
        end
      end

      test "the scanner flags client-resolving references in an ERB template" do
        {
          "<%= RpmsRpc::Patient.brief_header(dfn) %>" => "RpmsRpc::Patient.brief_header",
          "<% x = RpmsRpc.client %>" => "RpmsRpc.client",
          "<%- x = ::RpmsRpc.fhir_client -%>" => "RpmsRpc.fhir_client",
          "<p><%== RpmsRpc::Tribal.enrollment(dfn) %></p>" => "RpmsRpc::Tribal.enrollment",
          "<%= render \"row\", via: RpmsRpc::Scheduling %>" => "RpmsRpc::Scheduling",
          "<% if defined?(RpmsRpc.client.object_id) %>x<% end %>" => "RpmsRpc.client",
          "<%= tag.div do %><%= BackendRegistry.current.client %><% end %>" => "BackendRegistry.current.client"
        }.each do |template, expected_ref|
          refs = Scanner.scan_erb(template).hits.map(&:last)
          assert_equal [ expected_ref ], refs, "expected the scanner to flag the template #{template.inspect}"
        end

        template = "<h1>Header</h1>\n<%# a comment\n     over two lines %>\n<p>\n  <%= RpmsRpc::Patient\n        .brief_header(dfn) %>\n</p>\n"
        assert_equal [ [ 5, "RpmsRpc::Patient.brief_header" ] ], Scanner.scan_erb(template).hits,
                     "a template hit is reported once, at its line in the template"
      end

      test "the scanner flags with_client and new_client in an ERB template as scope openers" do
        {
          "<% RpmsRpc.with_client(c) do %>\n  <p>x</p>\n<% end %>" => "RpmsRpc.with_client",
          "<% client = RpmsSessions.new_client %>" => "RpmsSessions.new_client"
        }.each do |template, expected_ref|
          refs = Scanner.scan_erb(template).scope_openers.map(&:last)
          assert_equal [ expected_ref ], refs, "expected a scope opener in the template #{template.inspect}"
        end
      end

      test "the scanner leaves ERB comments and template text alone" do
        [
          "<%# RpmsRpc::Patient.brief_header(1) %>",
          "<%#\n  Locals: dfn, rows (RpmsRpc::Patient.brief_header), RpmsRpc.client\n%>\n<p><%= dfn %></p>",
          "RpmsRpc.client",
          "<p>RpmsRpc::Patient.brief_header(1) and RpmsRpc.with_client(c) { }</p>",
          "<%% RpmsRpc.client %>",
          "<%= \"RpmsRpc.client\" %>",
          "<% # RpmsRpc.client %>",
          "<% if defined?(RpmsRpc::MockClient) %>x<% end %>",
          "<% begin %><%= row %><% rescue RpmsRpc::Error %>x<% end %>",
          "<main><%= yield %></main>"
        ].each do |template|
          scanner = Scanner.scan_erb(template)
          assert_empty scanner.hits, "expected the scanner not to flag the template #{template.inspect}"
          assert_empty scanner.scope_openers, "expected no scope opener in the template #{template.inspect}"
        end
      end

      test "a template that does not compile to valid Ruby fails the scan" do
        assert_raises(RuntimeError) { Scanner.scan_erb("<% if x %>", path: "app/views/lakeraven/ehr/x/_y.html.erb") }
      end

      # The filters the engine-wide tests use, run on a synthetic scan: a
      # template is outside the door like any other file.
      test "a direct gem call in a template outside the door fails the leak check" do
        view = "app/views/lakeraven/ehr/x/_y.html.erb"
        scans = {
          view => Scanner.scan_erb("<p>\n  <%= RpmsRpc::Patient.brief_header(dfn) %>\n</p>\n<% RpmsRpc.with_client(c) do %>x<% end %>", path: view),
          "app/gateways/lakeraven/ehr/x_gateway.rb" => Scanner.scan("RpmsRpc::Patient.brief_header(dfn)"),
          EXEMPTIONS.keys.first => Scanner.scan("RpmsRpc.client"),
          SCOPE_OPENERS.first => Scanner.scan("RpmsRpc.with_client(c) { }")
        }

        assert_equal [ "#{view}:2 RpmsRpc::Patient.brief_header", "#{view}:4 RpmsRpc.with_client" ], leaks_in(scans)
        assert_equal [ "#{view}:4 RpmsRpc.with_client" ], scope_openers_in(scans)
        assert_not door?(view), "a template is not inside the door"
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
        # Walked independently of the scanner's globs, so the two cannot agree
        # by construction: .rb under app/ and lib/, .erb under app/views.
        expected = SCANNED_DIRECTORIES.flat_map { |dir| files_under(dir, ".rb") }
        templates = files_under(TEMPLATE_DIRECTORY, ".erb")

        assert_operator scanned.length, :>, 0, "the scan parsed no files"
        assert_operator templates.length, :>, 0, "the walk found no templates under #{TEMPLATE_DIRECTORY}"
        assert_empty expected & templates, "a file is counted once"
        assert_equal (expected + templates).sort, scanned.sort
      end

      private

      # Every Ruby file under the engine's app/ and lib/ and every ERB
      # template under app/views, as { relative path => Scanner }.
      def scan_engine
        @scan_engine ||= scan_ruby_files.merge(scan_templates)
      end

      def scan_ruby_files
        SCANNED_DIRECTORIES.flat_map { |dir| Dir[ROOT.join(dir, "**", "*.rb").to_s] }
                           .sort
                           .to_h { |path| [ relative(path), Scanner.scan(File.read(path), path: path) ] }
      end

      def scan_templates
        Dir[ROOT.join(TEMPLATE_DIRECTORY, "**", "*.erb").to_s]
          .sort
          .to_h { |path| [ relative(path), Scanner.scan_erb(File.read(path), path: path) ] }
      end

      # The leak filter: hits in any file that is neither in the door nor
      # exempt by name, as "path:line ref".
      def leaks_in(scans)
        scans.reject { |path, _scanner| door?(path) || EXEMPTIONS.key?(path) }
             .flat_map { |path, scanner| scanner.hits.map { |line, ref| "#{path}:#{line} #{ref}" } }
      end

      # Scope openers in any file but the two permitted, as "path:line ref".
      def scope_openers_in(scans)
        scans.reject { |path, _scanner| SCOPE_OPENERS.include?(path) }
             .flat_map { |path, scanner| scanner.scope_openers.map { |line, ref| "#{path}:#{line} #{ref}" } }
      end

      # Engine-relative paths of the files with this extension under dir,
      # found by walking the tree, not by the scan's globs.
      def files_under(dir, extension)
        found = []
        Find.find(ROOT.join(dir).to_s) do |path|
          found << relative(path) if File.file?(path) && File.extname(path) == extension
        end
        found
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
