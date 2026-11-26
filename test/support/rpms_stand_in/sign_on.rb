# frozen_string_literal: true

module RpmsStandIn
  # Who can sign on to the stand-in, and what the engine's sign-on reads about
  # them (AuthenticationService): the user, their class, their idle limit, and
  # which security keys and options they hold.
  #
  # Each is answered where the engine asks rpms-rpc, as the typed answer
  # rpms-rpc gives, for the user this connection signed on: the question
  # ADR 0013 asks of a test double is "which user's session did this call run
  # on", and a real broker answers these reads for the signed-on user only.
  module SignOn
    User = Struct.new(:duz, :access, :verify, :name, :role, :keys, :options, :idle_seconds, keyword_init: true)

    INVALID = { success: false, duz: nil, error: "Invalid A/V code.", error_code: 0, verify_needs_change: false }.freeze

    # A user who signs on with access;verify. role is the user type the
    # engine resolves ("provider", "nurse", "clerk", "user"); keys and options
    # are the SECURITY KEY and OPTION names the user holds.
    def user(duz, access:, verify:, name:, role:, keys: [], options: [], idle_seconds: 300)
      answer_sign_on_reads unless state.key?(:users)
      users[duz.to_i] = User.new(duz: duz.to_i, access: access.to_s.upcase, verify: verify.to_s.upcase, name: name,
                                  role: role.to_s, keys: Array(keys), options: Array(options), idle_seconds: idle_seconds)
      self
    end

    # The user this connection is signed on as, or nil.
    def signed_on_user = users[connection.duz.to_i]

    private

    def users = (state[:users] ||= {})

    def answer_sign_on_reads
      auth = RpmsRpc::Authentication
      answer(auth, :authenticate) { |access_code: nil, verify_code: nil| sign_on(access_code, verify_code) }
      answer(auth, :user_info) { |duz| session_user(duz)&.then { |u| user_facts(u) } }
      answer(auth, :user_type) { |duz| read_as(duz).role }
      answer(auth, :timed_read) { |duz| read_as(duz).idle_seconds }
      answer(auth, :held_keys) { |names| signed_on_user && (Array(names) & signed_on_user.keys) }
      answer(auth, :option_access) { |names| signed_on_user && (Array(names) & signed_on_user.options) }
    end

    def sign_on(access_code, verify_code)
      return { success: false, error: "Access code is required" } if access_code.to_s.strip.empty?
      return { success: false, error: "Verify code is required" } if verify_code.to_s.strip.empty?

      connection.clear_authenticated
      found = users.each_value.find { |u| u.access == access_code.to_s.strip.upcase && u.verify == verify_code.to_s.strip.upcase }
      return INVALID.dup unless found

      connection.set_authenticated(found.duz.to_s)
      { success: true, duz: found.duz, provider_ien: found.duz, message: "Welcome #{found.name}",
        verify_needs_change: false, post_signon_message_count: 0, name: found.name }
    end

    def user_facts(user)
      { duz: user.duz, name: user.name, display_name: user.name, current_site: nil, dtime: user.idle_seconds }
    end

    # The signed-on user when DUZ is theirs, as XUS GET USER INFO answers.
    def session_user(duz) = signed_on_user&.then { |u| u if u.duz == duz.to_i }

    # ORWU USERINFO answers for the signed-on user and nobody else.
    def read_as(duz)
      raise RpmsRpc::Client::RpcError, "ORWU USERINFO answered nothing" unless signed_on_user

      session_user(duz) || raise(RpmsRpc::Client::RpcError, "ORWU USERINFO answered for another user, not DUZ #{duz}")
    end
  end

  extend SignOn
end
