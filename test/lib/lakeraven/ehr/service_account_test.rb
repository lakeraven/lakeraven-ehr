# frozen_string_literal: true

require "test_helper"

# Where a backend client's RPMS service-account codes come from (#996, ADR 0011
# section 6, ADR 0013 decision 4: one account per backend client). The codes
# are looked up for the token's client application, by its client_id (the
# Doorkeeper application's uid): the host's credentials at
# rpms.service_accounts.<client_id> first, else the ENV pair, which belongs
# only to the one client RPMS_SERVICE_CLIENT_ID names. Never the repo, never a
# deployment-wide account. Both codes or nothing.
class LakeravenEhrServiceAccountTest < ActiveSupport::TestCase
  ENV_KEYS = %w[RPMS_SERVICE_ACCESS_CODE RPMS_SERVICE_VERIFY_CODE RPMS_SERVICE_CLIENT_ID].freeze
  CLIENT_A = "synthetic-backend-a"
  CLIENT_B = "synthetic-backend-b"

  # Rails.application.credentials, as far as ServiceAccount reads it. The real
  # one holds symbol keys; a client_id may be dug as a symbol or a string.
  class FakeCredentials
    def initialize(tree) = @tree = tree.with_indifferent_access
    def dig(*keys) = @tree.dig(*keys)
  end

  # Credentials the host cannot read: every read raises.
  class UnreadableCredentials
    def initialize(error) = @error = error
    def dig(*) = raise(@error, "synthetic unreadable credentials")
  end

  UNREADABLE = [ TypeError, ActiveSupport::MessageEncryptor::InvalidMessage ].freeze

  setup do
    @saved_env = ENV_KEYS.to_h { |key| [ key, ENV.key?(key) ? ENV[key] : :missing ] }
    ENV_KEYS.each { |key| ENV.delete(key) }
  end

  teardown do
    @saved_env.each { |key, value| value == :missing ? ENV.delete(key) : ENV[key] = value }
  end

  def codes_with_credentials(tree = {}, client_id: CLIENT_A)
    with_stub(Rails.application, :credentials, FakeCredentials.new(tree)) do
      Lakeraven::EHR::ServiceAccount.codes_for(client_id)
    end
  end

  def codes_with_unreadable_credentials(error, client_id: CLIENT_A)
    with_stub(Rails.application, :credentials, UnreadableCredentials.new(error)) do
      Lakeraven::EHR::ServiceAccount.codes_for(client_id)
    end
  end

  # The ENV pair, for the client it names.
  def env_account(access: "SVCA1", verify: "SVCA1!!", client_id: CLIENT_A)
    ENV["RPMS_SERVICE_ACCESS_CODE"] = access if access
    ENV["RPMS_SERVICE_VERIFY_CODE"] = verify if verify
    ENV["RPMS_SERVICE_CLIENT_ID"] = client_id if client_id
  end

  def per_client(entries) = { rpms: { service_accounts: entries } }

  test "nil when neither credentials nor ENV name a service account" do
    assert_nil codes_with_credentials
  end

  test "the ENV pair when both codes are set" do
    env_account

    assert_equal [ "SVCA1", "SVCA1!!" ], codes_with_credentials
  end

  test "nil when only the access code is set" do
    env_account(verify: nil)

    assert_nil codes_with_credentials
  end

  test "nil when only the verify code is set" do
    env_account(access: nil)

    assert_nil codes_with_credentials
  end

  test "blank strings count as missing" do
    env_account(access: "SVCA1", verify: "   ")
    assert_nil codes_with_credentials

    env_account(access: "", verify: "SVCA1!!")
    assert_nil codes_with_credentials
  end

  test "the credentials pair when the host's credentials carry both codes" do
    tree = per_client(CLIENT_A => { access_code: "SVCCRED1", verify_code: "SVCCRED1!!" })

    assert_equal [ "SVCCRED1", "SVCCRED1!!" ], codes_with_credentials(tree)
  end

  test "credentials come before ENV" do
    env_account
    tree = per_client(CLIENT_A => { access_code: "SVCCRED1", verify_code: "SVCCRED1!!" })

    assert_equal [ "SVCCRED1", "SVCCRED1!!" ], codes_with_credentials(tree)
  end

  test "a partial credentials entry is not a service account" do
    tree = per_client(CLIENT_A => { access_code: "SVCCRED1", verify_code: "" })

    assert_nil codes_with_credentials(tree)
  end

  # Credentials that cannot be read are no credentials: the ENV rule decides.
  UNREADABLE.each do |error|
    test "credentials that raise #{error.name} fall through to the ENV pair" do
      env_account

      assert_equal [ "SVCA1", "SVCA1!!" ], codes_with_unreadable_credentials(error)
    end

    test "nil when credentials raise #{error.name} and ENV names no service account" do
      assert_nil codes_with_unreadable_credentials(error)
    end

    test "nil when credentials raise #{error.name} and ENV names only one code" do
      env_account(verify: nil)

      assert_nil codes_with_unreadable_credentials(error)
    end

    test "nil when credentials raise #{error.name} and the ENV pair is another client's" do
      env_account(client_id: CLIENT_B)

      assert_nil codes_with_unreadable_credentials(error)
    end

    test "nil when credentials raise #{error.name} and no client is named for the ENV pair" do
      env_account(client_id: nil)

      assert_nil codes_with_unreadable_credentials(error)
    end
  end

  # 1. One account per backend client: there is no deployment-wide account.
  test "the argument-less codes is gone" do
    refute_respond_to Lakeraven::EHR::ServiceAccount, :codes
  end

  # 1a.
  test "each client gets its own credentials entry, and only its own" do
    tree = per_client(
      CLIENT_A => { access_code: "SVCA1", verify_code: "SVCA1!!" },
      CLIENT_B => { access_code: "SVCB1", verify_code: "SVCB1!!" }
    )

    assert_equal [ "SVCA1", "SVCA1!!" ], codes_with_credentials(tree, client_id: CLIENT_A)
    assert_equal [ "SVCB1", "SVCB1!!" ], codes_with_credentials(tree, client_id: CLIENT_B)
    assert_nil codes_with_credentials(tree, client_id: "synthetic-backend-c")
  end

  test "a partial credentials entry for the client does not fall through to the ENV pair" do
    env_account

    [ { access_code: "SVCCRED1", verify_code: "" },
      { access_code: "SVCCRED1" },
      { access_code: "  ", verify_code: "SVCCRED1!!" },
      { access_code: "", verify_code: "" } ].each do |entry|
      assert_nil codes_with_credentials(per_client(CLIENT_A => entry)), "entry #{entry.inspect}"
    end
  end

  test "another client's credentials entry leaves the ENV pair to the client it names" do
    env_account
    tree = per_client(CLIENT_B => { access_code: "SVCB1", verify_code: "SVCB1!!" })

    assert_equal [ "SVCA1", "SVCA1!!" ], codes_with_credentials(tree, client_id: CLIENT_A)
    assert_equal [ "SVCB1", "SVCB1!!" ], codes_with_credentials(tree, client_id: CLIENT_B)
  end

  # 1b.
  test "the ENV pair is nil for any client other than the one RPMS_SERVICE_CLIENT_ID names" do
    env_account(client_id: CLIENT_A)

    assert_nil codes_with_credentials(client_id: CLIENT_B)
    assert_nil codes_with_credentials(client_id: "#{CLIENT_A}-2"), "an exact match, not a prefix"
    assert_nil codes_with_credentials(client_id: CLIENT_A.upcase), "an exact match, not a case-folded one"
  end

  test "the ENV pair is nil when RPMS_SERVICE_CLIENT_ID is unset or blank" do
    env_account(client_id: nil)
    assert_nil codes_with_credentials

    [ "", "   " ].each do |blank|
      ENV["RPMS_SERVICE_CLIENT_ID"] = blank
      assert_nil codes_with_credentials, "RPMS_SERVICE_CLIENT_ID=#{blank.inspect}"
      assert_nil codes_with_credentials(client_id: blank), "a blank client_id is nobody's"
    end
  end

  test "RPMS_SERVICE_CLIENT_ID is matched after strip" do
    env_account(client_id: "  #{CLIENT_A}\n")

    assert_equal [ "SVCA1", "SVCA1!!" ], codes_with_credentials
  end

  test "nil for a nil or blank client_id whatever is configured" do
    env_account
    tree = per_client(CLIENT_A => { access_code: "SVCA1", verify_code: "SVCA1!!" })

    [ nil, "", "  " ].each do |client_id|
      assert_nil codes_with_credentials(tree, client_id: client_id), "client_id #{client_id.inspect}"
    end
  end

  # 1d.
  test "a deployment-wide rpms.service_account entry is no client's account" do
    tree = { rpms: { service_account: { access_code: "SVCWIDE1", verify_code: "SVCWIDE1!!" } } }

    [ CLIENT_A, CLIENT_B, "service_account" ].each do |client_id|
      assert_nil codes_with_credentials(tree, client_id: client_id), "client #{client_id}"
    end
  end

  test "a deployment-wide entry does not shadow the client's own entry or the ENV pair" do
    wide = { access_code: "SVCWIDE1", verify_code: "SVCWIDE1!!" }
    tree = { rpms: { service_account: wide,
                     service_accounts: { CLIENT_B => { access_code: "SVCB1", verify_code: "SVCB1!!" } } } }
    env_account(client_id: CLIENT_A)

    assert_equal [ "SVCB1", "SVCB1!!" ], codes_with_credentials(tree, client_id: CLIENT_B)
    assert_equal [ "SVCA1", "SVCA1!!" ], codes_with_credentials(tree, client_id: CLIENT_A)
  end
end
