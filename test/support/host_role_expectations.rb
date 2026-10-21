# frozen_string_literal: true

# Pinned expectations for issue #638 — mirrors rpms-rpc Capabilities/UserRoles
# behaviour without calling those modules (they are being removed).
module HostRoleExpectations
  ROLE_PERMISSIONS = {
    "provider" => %i[view_patients view_referrals create_referrals edit_own_referrals],
    "nurse" => %i[view_patients view_referrals update_referral_status],
    "clerk" => %i[view_patients view_referrals],
    "case_manager" => %i[view_patients view_referrals approve_referrals deny_referrals manage_referrals],
    "admin" => %i[view_patients view_referrals create_referrals approve_referrals deny_referrals manage_referrals],
    "user" => %i[view_own_referrals]
  }.freeze

  DEFAULT_ROLE_PERMISSIONS = ROLE_PERMISSIONS.fetch("user").freeze

  USER_CLASS_BY_AUTH_ROLE = {
    "admin" => "1",
    "provider" => "3",
    "nurse" => "4",
    "clerk" => "5"
  }.freeze

  AUTH_ROLE_BY_USER_CLASS = USER_CLASS_BY_AUTH_ROLE.invert.freeze

  PERMISSION_SYMBOLS = %i[
    view_patients view_referrals create_referrals edit_own_referrals
    update_referral_status approve_referrals deny_referrals manage_referrals
    view_own_referrals
  ].freeze

  UNKNOWN_PERMISSION = :not_a_real_permission

  USER_TYPES_FOR_MATRIX = %w[provider nurse clerk case_manager admin user].freeze

  UNKNOWN_USER_TYPE = "synthetic_unknown_role"

  # Mirrors the key symbols in the pinned rpms-rpc SecurityKeys registry.
  REGISTRY_KEY_SYMBOLS = %i[
    prc_supervisor prc_tech prc_manager chs_approve chs_clerk
    consult_manager eligibility_verify scheduling_admin
    bh_provider bh_supervisor dental_provider dental_supervisor
    cprs_gui_chart
  ].freeze

  CHS_PRC_RELEVANT_KEYS = %i[
    prc_supervisor prc_manager prc_tech chs_approve chs_clerk consult_manager
  ].freeze

  CHS_PRC_KEY_PAIRS = CHS_PRC_RELEVANT_KEYS
    .combination(2)
    .map { |left, right| [ left, right ] }
    .freeze

  KEY_SETS_FOR_MATRIX = (
    [
      [],
      nil,
      *REGISTRY_KEY_SYMBOLS.map { |symbol| [ symbol ] },
      *CHS_PRC_KEY_PAIRS,
      REGISTRY_KEY_SYMBOLS.dup,
      [ "prc_manager" ],
      [ :unknown_key ]
    ]
  ).freeze

  AUTH_USER_TYPES_FOR_MATRIX = %w[admin provider nurse clerk].freeze

  RPMS_KEY_STRING_BY_SYMBOL = {
    prc_supervisor: "PRCFA SUPERVISOR",
    prc_tech: "PRCFA TECH",
    prc_manager: "BPRC MANAGER",
    chs_approve: "BGOZ CHS APPROVE",
    chs_clerk: "BGOZ CHS CLERK",
    consult_manager: "GMRC MGR",
    eligibility_verify: "APCL VERIFY",
    scheduling_admin: "SD SUPERVISOR",
    bh_provider: "BGMH PROVIDER",
    bh_supervisor: "BGMH SUPERVISOR",
    dental_provider: "DENTP PROVIDER",
    dental_supervisor: "DENTP SUPERVISOR",
    cprs_gui_chart: "OR CPRS GUI CHART"
  }.freeze

  module_function

  def effective_user_type(user_type)
    user_type.nil? ? "user" : user_type.to_s
  end

  def role_permissions_for(user_type)
    ROLE_PERMISSIONS.fetch(effective_user_type(user_type), DEFAULT_ROLE_PERMISSIONS)
  end

  def security_keys_array(key_set)
    key_set.nil? ? [] : Array(key_set)
  end

  def holds_symbol_key?(key_set, symbol)
    security_keys_array(key_set).include?(symbol)
  end

  def expected_can?(user_type, key_set, permission)
    role_permissions_for(user_type).include?(permission.to_sym)
  end

  def expected_can_approve_chs?(key_set)
    holds_symbol_key?(key_set, :prc_supervisor) || holds_symbol_key?(key_set, :prc_manager)
  end

  def expected_can_process_chs?(key_set)
    holds_symbol_key?(key_set, :prc_tech) || holds_symbol_key?(key_set, :prc_supervisor)
  end

  def expected_can_manage_consults?(key_set)
    holds_symbol_key?(key_set, :consult_manager)
  end

  def expected_case_manager?(user_type, key_set)
    effective_user_type(user_type) == "case_manager" || holds_symbol_key?(key_set, :prc_manager)
  end

  def expected_capabilities(user_type, key_set)
    caps = Set.new(role_permissions_for(user_type))

    if expected_can_approve_chs?(key_set)
      caps << :approve_referrals
      caps << :deny_referrals
    end
    caps << :process_claims if expected_can_process_chs?(key_set)
    caps << :verify_eligibility if holds_symbol_key?(key_set, :eligibility_verify)
    caps << :manage_consults if expected_can_manage_consults?(key_set)
    caps << :manage_scheduling if holds_symbol_key?(key_set, :scheduling_admin)
    if holds_symbol_key?(key_set, :bh_provider) || holds_symbol_key?(key_set, :bh_supervisor)
      caps << :access_behavioral_health
    end
    if holds_symbol_key?(key_set, :dental_provider) || holds_symbol_key?(key_set, :dental_supervisor)
      caps << :access_dental
    end

    caps
  end

  def expected_resolved_user_type(auth_user_type, symbolic_keys)
    keys = Array(symbolic_keys)
    if keys.include?(:prc_supervisor) || keys.include?(:prc_manager)
      return "case_manager"
    end

    user_class = USER_CLASS_BY_AUTH_ROLE[auth_user_type.to_s]
    AUTH_ROLE_BY_USER_CLASS[user_class] || "user"
  end

  def raw_security_keys_for_symbolic(symbolic_keys)
    Array(symbolic_keys).filter_map { |sym| RPMS_KEY_STRING_BY_SYMBOL[sym] }
  end
end
