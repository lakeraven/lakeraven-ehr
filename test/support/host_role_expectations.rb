# frozen_string_literal: true

# Pinned expectations for the host's roles (#638) and its key table (#578).
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

  USER_TYPES_FOR_MATRIX = (
    %w[provider nurse clerk case_manager admin user] +
    [ :admin, :provider, "ADMIN", "Provider", " provider " ]
  ).freeze

  PERMISSIONS_FOR_MATRIX = (
    PERMISSION_SYMBOLS + [ "view_patients", "VIEW_PATIENTS", :VIEW_PATIENTS ]
  ).freeze

  UNKNOWN_USER_TYPE = "synthetic_unknown_role"

  # The key symbols in Roles::KEY_NAMES: every one a SECURITY KEY on the build.
  REGISTRY_KEY_SYMBOLS = %i[
    orders_sign orders_release orders_enter
    referrals_user referrals_supervisor referrals_manager
    scheduling_admin scheduling_user
    behavioral_health_user behavioral_health_manager
  ].freeze

  CHS_PRC_RELEVANT_KEYS = %i[referrals_user referrals_supervisor referrals_manager].freeze

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
      [ "referrals_manager" ],
      [ :unknown_key ]
    ]
  ).freeze

  AUTH_USER_TYPES_FOR_MATRIX = %w[admin provider nurse clerk user case_manager].freeze

  RPMS_KEY_STRING_BY_SYMBOL = {
    orders_sign: "ORES",
    orders_release: "ORELSE",
    orders_enter: "OREMAS",
    referrals_user: "BMCZMENU",
    referrals_supervisor: "BMCZSUPERVISOR",
    referrals_manager: "BMCZ MGR",
    scheduling_admin: "SD SUPERVISOR",
    scheduling_user: "SDZMENU",
    behavioral_health_user: "AMHZMENU",
    behavioral_health_manager: "AMHZMGR"
  }.freeze

  module_function

  def effective_user_type(user_type)
    user_type.nil? ? "user" : user_type
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
    holds_symbol_key?(key_set, :referrals_supervisor) || holds_symbol_key?(key_set, :referrals_manager)
  end

  def expected_can_process_chs?(key_set)
    holds_symbol_key?(key_set, :referrals_user) || holds_symbol_key?(key_set, :referrals_supervisor)
  end

  # No key decided for consults yet (#578).
  def expected_can_manage_consults?(_key_set)
    false
  end

  def expected_case_manager?(user_type, key_set)
    effective_user_type(user_type) == "case_manager" || holds_symbol_key?(key_set, :referrals_manager)
  end

  def expected_capabilities(user_type, key_set)
    caps = Set.new(role_permissions_for(user_type))

    if expected_can_approve_chs?(key_set)
      caps << :approve_referrals
      caps << :deny_referrals
    end
    caps << :process_claims if expected_can_process_chs?(key_set)
    caps << :manage_consults if expected_can_manage_consults?(key_set)
    caps << :manage_scheduling if holds_symbol_key?(key_set, :scheduling_admin)
    if holds_symbol_key?(key_set, :behavioral_health_user) || holds_symbol_key?(key_set, :behavioral_health_manager)
      caps << :access_behavioral_health
    end

    caps
  end

  def expected_resolved_user_type(auth_user_type, symbolic_keys)
    keys = Array(symbolic_keys)
    if keys.include?(:referrals_supervisor) || keys.include?(:referrals_manager)
      return "case_manager"
    end

    user_class = USER_CLASS_BY_AUTH_ROLE[auth_user_type.to_s]
    AUTH_ROLE_BY_USER_CLASS[user_class] || "user"
  end

  def raw_security_keys_for_symbolic(symbolic_keys)
    Array(symbolic_keys).filter_map { |sym| RPMS_KEY_STRING_BY_SYMBOL[sym] }
  end
end
