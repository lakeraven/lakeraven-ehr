# frozen_string_literal: true

require "test_helper"

# Where the RPMS service account's codes come from (#996, ADR 0011 section 6):
# the host's credentials first, else its environment; never the repo. Both
# codes or nothing.
class LakeravenEhrServiceAccountTest < ActiveSupport::TestCase
  ENV_KEYS = %w[RPMS_SERVICE_ACCESS_CODE RPMS_SERVICE_VERIFY_CODE].freeze

  # Rails.application.credentials, as far as ServiceAccount reads it.
  class FakeCredentials
    def initialize(tree) = @tree = tree
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

  def codes_with_credentials(tree = {})
    with_stub(Rails.application, :credentials, FakeCredentials.new(tree)) { Lakeraven::EHR::ServiceAccount.codes }
  end

  def codes_with_unreadable_credentials(error)
    with_stub(Rails.application, :credentials, UnreadableCredentials.new(error)) { Lakeraven::EHR::ServiceAccount.codes }
  end

  test "nil when neither credentials nor ENV name a service account" do
    assert_nil codes_with_credentials
  end

  test "the ENV pair when both codes are set" do
    ENV["RPMS_SERVICE_ACCESS_CODE"] = "SVCACCT1"
    ENV["RPMS_SERVICE_VERIFY_CODE"] = "SVCACCT1!!"

    assert_equal [ "SVCACCT1", "SVCACCT1!!" ], codes_with_credentials
  end

  test "nil when only the access code is set" do
    ENV["RPMS_SERVICE_ACCESS_CODE"] = "SVCACCT1"

    assert_nil codes_with_credentials
  end

  test "nil when only the verify code is set" do
    ENV["RPMS_SERVICE_VERIFY_CODE"] = "SVCACCT1!!"

    assert_nil codes_with_credentials
  end

  test "blank strings count as missing" do
    ENV["RPMS_SERVICE_ACCESS_CODE"] = "SVCACCT1"
    ENV["RPMS_SERVICE_VERIFY_CODE"] = "   "
    assert_nil codes_with_credentials

    ENV["RPMS_SERVICE_ACCESS_CODE"] = ""
    ENV["RPMS_SERVICE_VERIFY_CODE"] = "SVCACCT1!!"
    assert_nil codes_with_credentials
  end

  test "the credentials pair when the host's credentials carry both codes" do
    tree = { rpms: { service_account: { access_code: "SVCCRED1", verify_code: "SVCCRED1!!" } } }

    assert_equal [ "SVCCRED1", "SVCCRED1!!" ], codes_with_credentials(tree)
  end

  test "credentials come before ENV" do
    ENV["RPMS_SERVICE_ACCESS_CODE"] = "SVCACCT1"
    ENV["RPMS_SERVICE_VERIFY_CODE"] = "SVCACCT1!!"
    tree = { rpms: { service_account: { access_code: "SVCCRED1", verify_code: "SVCCRED1!!" } } }

    assert_equal [ "SVCCRED1", "SVCCRED1!!" ], codes_with_credentials(tree)
  end

  test "a partial credentials entry is not a service account" do
    tree = { rpms: { service_account: { access_code: "SVCCRED1", verify_code: "" } } }

    assert_nil codes_with_credentials(tree)
  end

  # Credentials that cannot be read are no credentials: the ENV pair decides.
  UNREADABLE.each do |error|
    test "credentials that raise #{error.name} fall through to the ENV pair" do
      ENV["RPMS_SERVICE_ACCESS_CODE"] = "SVCACCT1"
      ENV["RPMS_SERVICE_VERIFY_CODE"] = "SVCACCT1!!"

      assert_equal [ "SVCACCT1", "SVCACCT1!!" ], codes_with_unreadable_credentials(error)
    end

    test "nil when credentials raise #{error.name} and ENV names no service account" do
      assert_nil codes_with_unreadable_credentials(error)
    end

    test "nil when credentials raise #{error.name} and ENV names only one code" do
      ENV["RPMS_SERVICE_ACCESS_CODE"] = "SVCACCT1"

      assert_nil codes_with_unreadable_credentials(error)
    end
  end
end
