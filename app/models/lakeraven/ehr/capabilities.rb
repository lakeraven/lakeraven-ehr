# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a signed-in user may do in the app's own screens, from the RPMS
    # security keys they hold (ADR 0010). One table: every screen and action
    # checks a capability by name, on the server, and the views show or hide
    # controls from the same names, so what a user sees and what the server
    # allows cannot drift. RPMS checks again inside each RPC it runs as the
    # user; a capability only ever narrows what RPMS allows.
    #
    # Each rule names the keys by their symbolic names in Roles::KEY_NAMES,
    # which a test checks against the pinned build. A rule is met when the user
    # holds any of its keys and none of its deny keys. The rows follow the
    # policies BPRM 4.0 gates the same screens on; where a row differs from
    # BPRM's, its comment says so. Programmer mode grants nothing here (ADR
    # 0010 rule 7), although BPRM let XUPROG and XUPROGMODE edit patients.
    module Capabilities
      Rule = Data.define(:any, :deny) do
        def met_by?(keys) = any.intersect?(keys) && !deny.intersect?(keys)
      end

      def self.rule(any:, deny: []) = Rule.new(any: any.freeze, deny: deny.freeze)

      TABLE = {
        # Find a patient with AG's own lookup (AGG LOOKUP PATIENTS), which RPMS
        # runs for registration users only. BPRM: CanAccessPatientProfile.
        "registration.search" => rule(any: %i[registration_menu registration_manager registration_view_only]),
        # Open a patient's registration. Schedulers open it too, from a
        # booking. BPRM: CanViewPatient.
        "registration.view" => rule(any: %i[registration_menu registration_manager registration_view_only
                                            scheduling_user scheduling_supervisor]),
        # Register a new patient. BPRM: CanRegisterPatient, AGZMENU and not
        # AGZVIEWONLY. AGZMGR also registers here, as it edits patients in BPRM.
        "patient.register" => rule(any: %i[registration_menu registration_manager], deny: %i[registration_view_only]),
        # Open scheduling: resources whose BSDX rights let the user see them.
        # BPRM: CanAccessScheduling.
        "scheduling.open" => rule(any: %i[scheduling_user scheduling_supervisor]),
        # Every resource of the facility, and booking on any of them, whatever
        # its BSDX rights say. BPRM: SchedulingSupervisor.
        "scheduling.supervise" => rule(any: %i[scheduling_supervisor])
      }.freeze

      NAMES = TABLE.keys.freeze

      # The capability names the symbolic keys meet. keys: Roles' symbolic
      # names, as symbols or strings (the session keeps strings).
      def self.for(keys)
        held = Array(keys).map(&:to_sym)
        TABLE.filter_map { |name, rule| name if rule.met_by?(held) }
      end

      # Whether the keys meet the named capability. An unknown name raises, so
      # a misspelled check never quietly refuses (or allows) everyone.
      def self.allows?(keys, name)
        TABLE.fetch(name) { raise ArgumentError, "unknown capability #{name.inspect}" }.met_by?(Array(keys).map(&:to_sym))
      end
    end
  end
end
