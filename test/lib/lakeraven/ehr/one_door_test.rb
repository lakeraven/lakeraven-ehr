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
    # test. What is scanned: every .rb and .rake file under app/ and lib/, and
    # every .erb template under app/views, compiled to Ruby by Rails' own ERB
    # handler, with a strict-locals signature (`<%# locals: (...) %>`) placed
    # in the method's parameter list as Rails places it. Two discovery tests
    # keep that list complete: a file under app/views with any other
    # executable template handler fails, and so does an .erb outside
    # app/views. The scan is by reference over the Prism AST, never a grep:
    # comments, strings and template text do not match, a call split across
    # lines does, and `::RpmsRpc::X.y` and `Object::RpmsRpc::X.y` are the same
    # reference as `RpmsRpc::X.y`.
    #
    # Not seen, by design of a scan by reference: a gem module or client
    # reached through a value the scan would have to track (a local variable,
    # `RpmsRpc.itself.client`, `.then`, `instance_eval`, `send` on
    # RpmsSessions).
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
      # Plain Ruby by either name; rake tasks run in the engine like any code.
      RUBY_EXTENSIONS = %w[.rb .rake].freeze
      # ERB templates are executable Ruby too; every .erb under here is scanned.
      TEMPLATE_DIRECTORY = "app/views"
      # Registered ActionView handlers that render a file as text and run no
      # Ruby from it. A file under app/views with any other registered
      # handler but ERB is executable and unscanned, and fails the test.
      STATIC_TEMPLATE_HANDLERS = [ ActionView::Template::Handlers::Raw, ActionView::Template::Handlers::Html ].freeze

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

        # The source does not parse as Ruby, or a template's strict-locals
        # signature is one Rails refuses to compile. Nothing was scanned, so
        # the scan fails rather than report a clean file.
        ParseError = Class.new(RuntimeError)

        # A template as the Ruby Rails compiles it to: `ruby` is the method
        # definition, `line_of` maps a Prism node in it to its line in the
        # template, `strict_locals` says whether the template has a
        # strict-locals signature.
        CompiledTemplate = Struct.new(:ruby, :line_of, :strict_locals)

        attr_reader :hits, :scope_openers

        def self.scan(source, path: "(inline)")
          new(source, path).tap(&:scan)
        end

        # An ERB template, compiled to Ruby as Rails compiles it, then scanned
        # like any Ruby. Template text becomes a string literal and a `<%# %>`
        # comment is dropped, with one exception: the strict-locals magic
        # comment is not a comment (see compile_erb). A hit's line is its
        # line in the template.
        def self.scan_erb(source, path: "(inline erb)")
          compiled = compile_erb(source, path: path)
          new(compiled.ruby, path, line_of: compiled.line_of, strict_locals: compiled.strict_locals).tap(&:scan)
        end

        # What ActionView::Template#compiled_source does, step for step (the
        # parity self-test compares the two, so a Rails upgrade that changes
        # either step fails there):
        #
        # 1. The strict-locals signature is lifted out of the source by
        #    ActionView's own STRICT_LOCALS_REGEX (Template#strict_locals!):
        #    the first `# locals: (...)` that ends a tag or a line, wherever
        #    it stands. Its text becomes the parameters of the compiled
        #    method, so a default written there runs at every render. An
        #    empty signature is `**nil`, and `&_` is added unless the
        #    signature names a block itself.
        # 2. The rest goes through the registered ERB handler, which applies
        #    Rails' ERB implementation, trim mode and encoding tag.
        # 3. The handler's Ruby is the body of a method (a template may
        #    `yield`, which is not valid at the top level) that takes
        #    local_assigns, output_buffer and the signature.
        #
        # One deliberate difference, which changes no code: Rails deletes the
        # signature from the source, newlines included, and opens the method
        # on a line of its own. Here the signature's newlines stay in the
        # body and the method opens on the body's first line, so that
        # `line_of` can give every node its template line: a node in the
        # signature is as far below the signature's first line as it is in
        # the template, and the body, whose compiler keeps every newline, is
        # pushed down only by the newlines inside the signature.
        def self.compile_erb(source, path: "(inline erb)")
          body = source.dup
          match = ActionView::Template::STRICT_LOCALS_REGEX.match(body)
          locals = nil
          signature_line = 1
          if match
            locals = match[1].rstrip
            locals = "**nil" if locals.blank?
            signature_line += match.pre_match.count("\n") + body[match.begin(0)...match.begin(1)].count("\n")
            body[match.begin(0)...match.end(0)] = "\n" * match[0].count("\n")
          end

          handler = ActionView::Template.registered_template_handler(:erb)
          template = ActionView::Template.new(body, path.to_s, handler, locals: [], format: :html)
          parameters = [ "local_assigns, output_buffer", locals, (locals&.include?("&") ? nil : "&_") ].compact.join(", ")
          opening = "def _template(#{parameters}); "
          pushed_down = opening.count("\n")
          line_of = lambda do |node|
            line = node.location.start_line
            node.location.start_offset < opening.bytesize ? line + signature_line - 1 : line - pushed_down
          end

          CompiledTemplate.new("#{opening}#{handler.call(template, body)}\nend", line_of, !locals.nil?)
        end

        def initialize(source, path, line_of: nil, strict_locals: false)
          @source = source
          @path = path
          @line_of = line_of || ->(node) { node.location.start_line }
          @strict_locals = strict_locals
          @hits = []
          @scope_openers = []
          # Nodes already judged by their parent (a call's constant receiver,
          # a type check's argument), so the bare-constant rule does not
          # report the same site a second time.
          @judged = Set.new.compare_by_identity
        end

        def scan
          result = Prism.parse(@source)
          raise ParseError, "#{@path}: #{result.errors.map(&:message).join('; ')}" if result.failure?

          check_strict_locals(result.value) if @strict_locals
          walk(result.value)
          self
        end

        private

        # Rails compiles a strict-locals signature only when every parameter
        # is a keyword (Template#compile raises ArgumentError otherwise, and
        # the template never renders). A signature that adds a positional
        # parameter is malformed, and the scan fails as it does for a
        # signature that does not parse.
        def check_strict_locals(program)
          parameters = program.statements.body.first.parameters
          positional = parameters.requireds.drop(2) + parameters.optionals + [ parameters.rest ].compact + parameters.posts
          return if positional.empty?

          raise ParseError, "#{@path}: strict locals can only be keyword arguments, got #{positional.map(&:slice).join(', ')}"
        end

        def walk(node)
          return if node.nil? || @judged.include?(node)

          case node
          when Prism::DefinedNode then return probe(node.value) # judged by what `defined?` evaluates
          when Prism::ConstantPathNode, Prism::ConstantReadNode
            # `expr::Const` is not a constant taken as a value: Ruby
            # evaluates `expr` and looks Const up in the result, so `expr` is
            # walked as ordinary code. This covers the path as a write target
            # too (`expr::X = 1`, `expr::X ||= 1`), whose target is this node.
            return segments(node) ? flag_bare_constant(node) : walk(node.parent)
          when Prism::CallNode then visit_call(node)
          when Prism::WhenNode then visit_when(node)
          end

          node.compact_child_nodes.each { |child| walk(child) }
        end

        # The operand of `defined?`, judged by what CRuby evaluates of it
        # (compile.c, defined_expr0), which is not "nothing":
        #
        # - A static constant path (`A`, `A::B`, `::A::B`) is a probe: looked
        #   up, never called. Exempt.
        # - `expr::Const` is not: once `expr` is defined CRuby evaluates it to
        #   look Const up in the result, so `expr` is walked as ordinary code:
        #   `defined?(RpmsRpc.client::FOO)` resolves a client.
        # - A call is not made (`defined?(RpmsRpc.client)` only asks whether
        #   the method exists), but its receiver IS evaluated. A receiver
        #   that is itself a call is really called, so it is walked as
        #   ordinary code and judged by every rule, scope openers included:
        #   `defined?(RpmsRpc.client.object_id)` resolves a client. A static
        #   constant receiver is a probe, not a value. Each argument is checked for
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
          when nil, Prism::ConstantReadNode then nil
          when Prism::ConstantPathNode then walk(node) unless segments(node)
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
        # parsers are allowed by rule. Only a static constant path reaches
        # here: one probed by `defined?(...)` does not, and `expr::Const` is
        # judged by its `expr` (see walk).
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

        # The constant path as names, with the prefixes that name the top
        # level dropped: `::RpmsRpc::A::B`, `Object::RpmsRpc::A::B`,
        # `::Object::RpmsRpc::A::B` and `RpmsRpc::A::B` are all ["RpmsRpc",
        # "A", "B"], because a top-level constant is a constant of Object.
        # `Other::RpmsRpc` keeps its prefix: it is another constant. nil for
        # anything that is not a static constant path (`self.class::X`,
        # `x.y::Z`, a variable, a call).
        def segments(node)
          case node
          when Prism::ConstantReadNode then [ node.name.to_s ]
          when Prism::ConstantPathNode
            return [ node.name.to_s ] if node.parent.nil?

            parent = segments(node.parent)
            return if parent.nil?

            parent == [ "Object" ] ? [ node.name.to_s ] : parent + [ node.name.to_s ]
          end
        end

        def hit(node, ref)
          @hits << [ @line_of.call(node), ref ]
        end

        def scope_opener(node, ref)
          @scope_openers << [ @line_of.call(node), ref ]
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
          "defined?(f(&RpmsRpc.client))" => "RpmsRpc.client",
          # `expr::Const` evaluates `expr`, in ordinary code, as a write target and under `defined?`
          "x = RpmsRpc.client::FOO" => "RpmsRpc.client",
          "RpmsRpc.configuration.client.class::TIMEOUT" => "RpmsRpc.configuration.client",
          "(RpmsRpc::Patient.brief_header(dfn))::X" => "RpmsRpc::Patient.brief_header",
          "Foo.new(RpmsRpc.client)::Bar" => "RpmsRpc.client",
          "RpmsRpc.client::A::B" => "RpmsRpc.client",
          "RpmsRpc.client::X.y" => "RpmsRpc.client",
          "RpmsRpc.client::X = 1" => "RpmsRpc.client",
          "RpmsRpc.client::X ||= 1" => "RpmsRpc.client",
          "RpmsRpc.client::X &&= 1" => "RpmsRpc.client",
          "RpmsRpc.client::X += 1" => "RpmsRpc.client",
          "RpmsRpc.client::X, y = 1, 2" => "RpmsRpc.client",
          "f(via: RpmsRpc::Patient)::X" => "RpmsRpc::Patient",
          "defined?(RpmsRpc.client::FOO)" => "RpmsRpc.client",
          "defined?(RpmsRpc.client::A::B)" => "RpmsRpc.client",
          "defined?(RpmsRpc.client::X.y)" => "RpmsRpc.client",
          "defined?(f(RpmsRpc.client::X))" => "RpmsRpc.client",
          "x.is_a?(RpmsRpc.client::Z)" => "RpmsRpc.client",
          # `Object::RpmsRpc` is the gem
          "Object::RpmsRpc.client" => "RpmsRpc.client",
          "::Object::RpmsRpc.client" => "RpmsRpc.client",
          "Object::RpmsRpc::Patient.brief_header(1)" => "RpmsRpc::Patient.brief_header",
          "m = Object::RpmsRpc::Patient" => "RpmsRpc::Patient",
          "m = ::Object::RpmsRpc" => "RpmsRpc",
          "Object::RpmsRpc.configuration.client" => "RpmsRpc.configuration.client",
          "x.is_a?(Object::RpmsRpc::MockClient)" => "is_a?(RpmsRpc::MockClient)",
          "defined?(Object::RpmsRpc.client.object_id)" => "RpmsRpc.client"
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
          "defined?(f(RpmsRpc.client.x))" => [ "RpmsRpc.client" ],
          "x = RpmsRpc.client::FOO" => [ "RpmsRpc.client" ],
          "RpmsRpc.client::X = 1" => [ "RpmsRpc.client" ],
          "RpmsRpc.client::X ||= 1" => [ "RpmsRpc.client" ],
          "defined?(RpmsRpc.client::FOO)" => [ "RpmsRpc.client" ],
          "defined?(RpmsRpc.client::X.y)" => [ "RpmsRpc.client" ],
          "x.is_a?(RpmsRpc.client::Z)" => [ "RpmsRpc.client" ],
          "Object::RpmsRpc.client" => [ "RpmsRpc.client" ],
          "Object::RpmsRpc::Patient.brief_header(1)" => [ "RpmsRpc::Patient.brief_header" ]
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
          # a constant path, static or not, that reaches no gem reference
          "Foo::Bar",
          "defined?(Foo::Bar)",
          "x.class::Y",
          "defined?(x.y::Z)",
          "x.class::Y = 1",
          "defined?(Object::RpmsRpc::MockClient)",
          "defined?(Object::RpmsRpc.client)",
          "rescue_from Object::RpmsRpc::Error, with: :render_rpms_unavailable",
          "Object::RpmsRpc::FilemanDateParser.parse(x)",
          # another namespace's RpmsRpc, and settings that are not a client
          "Other::RpmsRpc.client",
          "Other::RpmsRpc::Patient.brief_header(1)",
          "x = Other::RpmsRpc",
          "Other::Object::RpmsRpc.client",
          "Object::Other::RpmsRpc.client",
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
          "Lakeraven::EHR::RpmsSessions.new_client" => "Lakeraven::EHR::RpmsSessions.new_client",
          "RpmsSessions.new_client::Foo" => "RpmsSessions.new_client",
          "RpmsSessions.new_client::X = 1" => "RpmsSessions.new_client",
          "RpmsRpc.with_client(c) { }::X" => "RpmsRpc.with_client",
          "Object::RpmsRpc.with_client(c) {}" => "RpmsRpc.with_client",
          "Object::RpmsSessions.new_client" => "RpmsSessions.new_client"
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
          "defined?(f(RpmsSessions.new_client.x))" => "RpmsSessions.new_client",
          "defined?(RpmsSessions.new_client::X)" => "RpmsSessions.new_client",
          "defined?(RpmsRpc.with_client(c)::X)" => "RpmsRpc.with_client"
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
          "<%= tag.div do %><%= BackendRegistry.current.client %><% end %>" => "BackendRegistry.current.client",
          "<%= RpmsRpc.client::Foo %>" => "RpmsRpc.client",
          "<%= Object::RpmsRpc::Patient.brief_header(dfn) %>" => "RpmsRpc::Patient.brief_header",
          # a strict-locals default is code that runs at render
          "<%# locals: (c: RpmsRpc.client) -%>\n<%= c %>" => "RpmsRpc.client",
          "<%# locals: (via: RpmsRpc::Patient) %>\n<%= via.brief_header(1) %>" => "RpmsRpc::Patient",
          "<%# locals: (dfn:, c: RpmsRpc.client::X) %>" => "RpmsRpc.client",
          "<%# locals: (c: BackendRegistry.current.client, &block) %>x" => "BackendRegistry.current.client",
          "<% # locals: (c: RpmsRpc.fhir_client) %>x" => "RpmsRpc.fhir_client",
          "<p>x</p>\n<%#\n  locals: (c: RpmsRpc.client)\n%>" => "RpmsRpc.client"
        }.each do |template, expected_ref|
          refs = Scanner.scan_erb(template).hits.map(&:last)
          assert_equal [ expected_ref ], refs, "expected the scanner to flag the template #{template.inspect}"
        end

        template = "<h1>Header</h1>\n<%# a comment\n     over two lines %>\n<p>\n  <%= RpmsRpc::Patient\n        .brief_header(dfn) %>\n</p>\n"
        assert_equal [ [ 5, "RpmsRpc::Patient.brief_header" ] ], Scanner.scan_erb(template).hits,
                     "a template hit is reported once, at its line in the template"
      end

      test "a strict-locals default and the code after it keep their template lines" do
        {
          "<%# locals: (c: RpmsRpc.client) -%>\n<%= c %>" => [ [ 1, "RpmsRpc.client" ] ],
          "<%# locals: (dfn:) %>\n<p>\n  <%= RpmsRpc::Patient.brief_header(dfn) %>\n</p>" => [ [ 3, "RpmsRpc::Patient.brief_header" ] ],
          "<h1>x</h1>\n\n<%# locals: (c: RpmsRpc.client) %>\n<p>\n<%= RpmsRpc.fhir_client %>" =>
            [ [ 3, "RpmsRpc.client" ], [ 5, "RpmsRpc.fhir_client" ] ],
          "<p>x</p>\n<%# locals: (a: 1,\n               c: RpmsRpc.client,\n               d: RpmsRpc.fhir_client) %>\n<p>\n<%= RpmsRpc::Tribal.enrollment(a) %>" =>
            [ [ 3, "RpmsRpc.client" ], [ 4, "RpmsRpc.fhir_client" ], [ 6, "RpmsRpc::Tribal.enrollment" ] ],
          "<%= RpmsRpc::Tribal.enrollment(1) %>\n<%#\n\n  locals: (c: RpmsRpc.client)\n%>\n<%= RpmsRpc.fhir_client %>" =>
            [ [ 4, "RpmsRpc.client" ], [ 1, "RpmsRpc::Tribal.enrollment" ], [ 6, "RpmsRpc.fhir_client" ] ]
        }.each do |template, expected_hits|
          assert_equal expected_hits, Scanner.scan_erb(template).hits, "expected template lines for #{template.inspect}"
        end

        opener = Scanner.scan_erb("<p>x</p>\n<%# locals: (a: 1,\n  c: RpmsSessions.new_client) %>\n<% RpmsRpc.with_client(c) do %>x<% end %>")
        assert_equal [ [ 3, "RpmsSessions.new_client" ], [ 4, "RpmsRpc.with_client" ] ], opener.scope_openers
      end

      # scan_erb builds the method Rails builds. Compared on what the scan
      # depends on, the parsed parameters and the call sites of the body, not
      # on the text: a Rails upgrade that moves the signature, changes the
      # handler or stops lifting the magic comment fails here.
      test "the Ruby scanned for a template is the Ruby ActionView compiles" do
        assert_equal ActionView::Template::Handlers::ERB, ActionView::Template.registered_template_handler(:erb).class
        [
          "<%# locals: (dfn:, can_edit: false, via: Foo::Bar, rows: helper.rows(1)) -%>\n<p><%= dfn %></p>\n<% rows.each do |row| %>\n  <%= render \"row\", row: row, via: via %>\n<% end %>",
          "<%# locals: () %>\n<p><%= helper(1) %></p>",
          "<%# locals: (title: \"x\", &block) %>\n<%= tag.div(title, &block) %>",
          "<%# locals: (a: 1, **rest) %><%= f(a, rest) %>",
          "<% # locals: (a: g(1)) %>\n<%= f(a) %>",
          "<p>x</p>\n<%#\n  locals: (a: g(1),\n           b: h(a))\n%>\n<%= f(a, b) -%>\n<%== k %>",
          "<%# encoding: utf-8 %>\n<%# locals: (a: 1) %>\n<%= f(a) %>",
          "<%# a comment %>\n<p><%= f(x) %></p>\n<%- if y -%>\n  <%= yield %>\n<%- end -%>\n",
          "<%# Locals: (a: g(1)) %><%= f(a) %>",
          "plain text\n"
        ].each do |source|
          handler = ActionView::Template.registered_template_handler(:erb)
          rails = ActionView::Template.new(source, "inline.html.erb", handler, locals: [], format: :html).send(:compiled_source)
          ours = Scanner.compile_erb(source)

          assert_equal method_shape(rails), method_shape(ours.ruby), "scan_erb and ActionView disagree on #{source.inspect}"
          assert_equal !source.match?(/#\s+locals:/), method_shape(ours.ruby).fetch(:parameters) == [ "local_assigns", "output_buffer", "&_" ],
                       "expected a strict-locals signature exactly where the template has one: #{source.inspect}"
        end
      end

      test "a malformed strict-locals signature fails the scan" do
        view = "app/views/lakeraven/ehr/x/_y.html.erb"
        [
          "<%# locals: (a b) %>\n<%= a %>",
          "<%# locals: (c: RpmsRpc.client( ) %>",
          "<%# locals: (a: 1, 2) %>",
          "<%# locals: (dfn) %>\n<%= dfn %>",
          "<%# locals: (dfn = RpmsRpc.client) %>",
          "<%# locals: (*rows) %>"
        ].each do |template|
          error = assert_raises(Scanner::ParseError, "expected the scan to refuse #{template.inspect}") do
            Scanner.scan_erb(template, path: view)
          end
          assert_includes error.message, view
        end
      end

      test "the scanner flags with_client and new_client in an ERB template as scope openers" do
        {
          "<% RpmsRpc.with_client(c) do %>\n  <p>x</p>\n<% end %>" => "RpmsRpc.with_client",
          "<% client = RpmsSessions.new_client %>" => "RpmsSessions.new_client",
          "<%# locals: (c: RpmsSessions.new_client) %>x" => "RpmsSessions.new_client",
          "<%= RpmsSessions.new_client::Foo %>" => "RpmsSessions.new_client"
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
          "<main><%= yield %></main>",
          # a strict-locals signature whose defaults reach no gem reference
          "<%# locals: (dfn:, can_edit: false) %>\n<p><%= dfn %></p>",
          "<%# locals: () %>\n<p>RpmsRpc.client</p>",
          "<%# locals: (klass: Foo::Bar, error: RpmsRpc::Error, label: \"RpmsRpc.client\") -%>\n<%= klass %>",
          "<%# locals: (dfn:) %>\n<%# RpmsRpc.client %>\n<%= dfn %>",
          # not the magic comment: Rails does not lift it, so it stays a comment
          "<%# Locals: (c: RpmsRpc.client) %>",
          "<%# locals (c: RpmsRpc.client) %>",
          "<%# locals: c: RpmsRpc.client %>"
        ].each do |template|
          scanner = Scanner.scan_erb(template)
          assert_empty scanner.hits, "expected the scanner not to flag the template #{template.inspect}"
          assert_empty scanner.scope_openers, "expected no scope opener in the template #{template.inspect}"
        end
      end

      test "a template that does not compile to valid Ruby fails the scan" do
        assert_raises(RuntimeError) { Scanner.scan_erb("<% if x %>", path: "app/views/lakeraven/ehr/x/_y.html.erb") }

        view = "app/views/lakeraven/ehr/x/_y.html.erb"
        error = assert_raises(Scanner::ParseError) { Scanner.scan_erb("<% if x %>", path: view) }
        prism_errors = Prism.parse(Scanner.compile_erb("<% if x %>").ruby).errors.map(&:message)

        assert_not_empty prism_errors, "the template is expected not to parse"
        assert_equal "#{view}: #{prism_errors.join('; ')}", error.message,
                     "the failure names the template and carries Prism's parse errors"

        error = assert_raises(Scanner::ParseError) { Scanner.scan("def f(", path: "app/models/x.rb") }
        assert_operator error.message, :start_with?, "app/models/x.rb: "
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
        # by construction: .rb and .rake under app/ and lib/, .erb under
        # app/views.
        expected = SCANNED_DIRECTORIES.flat_map { |dir| files_under(dir, ".rb") }
        rake = SCANNED_DIRECTORIES.flat_map { |dir| files_under(dir, ".rake") }
        templates = files_under(TEMPLATE_DIRECTORY, ".erb")

        assert_operator scanned.length, :>, 0, "the scan parsed no files"
        assert_operator templates.length, :>, 0, "the walk found no templates under #{TEMPLATE_DIRECTORY}"
        assert_operator rake.length, :>, 0, "the walk found no rake files under #{SCANNED_DIRECTORIES.join(' or ')}"
        assert_empty expected & templates, "a file is counted once"
        assert_empty rake - scanned, "every rake file is scanned"
        assert_equal (expected + rake + templates).sort, scanned.sort
      end

      # Completeness of discovery, fail closed: the scan compiles ERB and
      # nothing else, so a template in any other executable language must not
      # be addable without this test noticing.
      test "every file under app/views is a template the scan covers" do
        executable = ActionView::Template::Handlers.extensions.map(&:to_s).reject do |extension|
          handler = ActionView::Template.registered_template_handler(extension)
          STATIC_TEMPLATE_HANDLERS.any? { |static| handler == static || handler.is_a?(static) }
        end
        assert_includes executable, "erb", "ActionView no longer registers an erb handler"
        assert_operator executable.length, :>, 1, "expected ActionView to register executable handlers besides erb"

        unscanned = all_files_under(TEMPLATE_DIRECTORY).select do |path|
          extension = File.extname(path).delete_prefix(".")
          extension != "erb" && executable.include?(extension)
        end

        assert_empty unscanned,
                     "executable and unscanned: these files under #{TEMPLATE_DIRECTORY} have a registered ActionView " \
                     "handler other than erb, so they run Ruby the one-door scan does not read; write them in ERB " \
                     "or teach the scan their handler:\n  #{unscanned.join("\n  ")}"
      end

      test "no ERB template lives outside app/views" do
        stray = SCANNED_DIRECTORIES.flat_map { |dir| files_under(dir, ".erb") }
                                   .reject { |path| path.start_with?("#{TEMPLATE_DIRECTORY}/") }

        assert_empty stray,
                     "executable and unscanned: an .erb outside #{TEMPLATE_DIRECTORY} is not scanned by the one-door " \
                     "test; move it under #{TEMPLATE_DIRECTORY} or add its directory to the scan:\n  #{stray.join("\n  ")}"
      end

      private

      # Every Ruby file (.rb, .rake) under the engine's app/ and lib/ and
      # every ERB template under app/views, as { relative path => Scanner }.
      def scan_engine
        @scan_engine ||= scan_ruby_files.merge(scan_templates)
      end

      def scan_ruby_files
        SCANNED_DIRECTORIES.product(RUBY_EXTENSIONS)
                           .flat_map { |dir, extension| Dir[ROOT.join(dir, "**", "*#{extension}").to_s] }
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

      def all_files_under(dir)
        found = []
        Find.find(ROOT.join(dir).to_s) { |path| found << relative(path) if File.file?(path) }
        found
      end

      # The first method definition in a compiled template, as what the scan
      # depends on: its parameters as source text, and the call sites of its
      # body in order, each as its receiver's source text and its name.
      def method_shape(ruby)
        result = Prism.parse(ruby)
        assert result.success?, "expected valid Ruby: #{result.errors.map(&:message).join('; ')}"
        definition = result.value.statements.body.grep(Prism::DefNode).first
        calls = []
        pending = [ definition.body ]
        while (node = pending.shift)
          calls << [ node.receiver&.slice, node.name ] if node.is_a?(Prism::CallNode)
          pending.unshift(*node.compact_child_nodes)
        end

        { parameters: definition.parameters.compact_child_nodes.map { |parameter| parameter.slice.squish }, calls: calls }
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
