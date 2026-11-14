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
        # Register a new patient, and edit a registered one (S-REG-20, S-REG-21).
        # BPRM gates both on one policy, CanEditPatients: AGZMENU or AGZMGR, and
        # not AGZVIEWONLY.
        "patient.register" => rule(any: %i[registration_menu registration_manager], deny: %i[registration_view_only]),
        # Open scheduling: resources whose BSDX rights let the user see them.
        # BPRM: CanAccessScheduling.
        "scheduling.open" => rule(any: %i[scheduling_user scheduling_supervisor]),
        # Every resource of the facility, and booking on any of them, whatever
        # its BSDX rights say. BPRM: SchedulingSupervisor.
        "scheduling.supervise" => rule(any: %i[scheduling_supervisor]),
        # Register a caller with no chart while booking them: name, date of
        # birth, sex and SSN, and a temporary chart number (rpms-ux S-REG-05).
        # RPMS: option BSDAM MINI REGISTRATION, locked by SDZREGMENU. BPRM
        # implies the same key for its mini-registration (ADR 0010).
        "patient.quick_register" => rule(any: %i[scheduling_registration], deny: %i[registration_view_only]),
        # Revoke an in-clinic consent. Physician (ORES) and nurse (ORELSE) may
        # revoke; OREMAS (clerk/medical assistant), registration and scheduling
        # keys may not. The registration clerk may still start a handover (the
        # CIAV VUECENTRIC user/Consent.c scope is unchanged).
        "consent.revoke" => rule(any: %i[orders_sign orders_release]),
        # Work the facility's referrals: list the ones still pending across
        # patients (#873). RPMS: RCIS's menu key BMCZMENU, or its supervisor
        # and manager keys, the same keys Roles.can_process_chs? reads.
        "referrals.work" => rule(any: %i[referrals_user referrals_supervisor referrals_manager]),
        # Open the registration tables a site keeps itself: anyone who may edit one
        # of them. BPRM: CanAccessSettings, narrowed to the tables lakeraven-ehr has.
        "registration.setup" => rule(any: %i[registration_manager record_flags_manager]),
        # Add and rename the eligibility modifiers a clerk picks as proof of a name
        # change, a legal document or legal sex (#982). BPRM:
        # CanAccessRegistrationTableMaintenance, AGZMGR on AG's menu.
        "registration.table_maintenance" => rule(any: %i[registration_manager]),
        # Define the site's local (Category II) patient record flags (#983). BPRM:
        # CanAccessLocalFlagsTableMaintenance, DGPF MANAGER. Assigning a flag to a
        # patient is another capability (DGPF ASSIGNMENT), not this one.
        "record_flags.define" => rule(any: %i[record_flags_manager])
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
