# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientRegistrationTest < ActiveSupport::TestCase
      VALID = { name: "PROBE,ALPHA", sex: "F", dob: "1990-05-01", ssn: "", tribe_ien: "611", community_ien: "16379" }.freeze

      def registration(**changes) = PatientRegistration.new(VALID.merge(changes))

      test "a complete entry is valid and becomes what RpmsRpc::Patient.register takes" do
        reg = registration

        assert reg.valid?, reg.errors.full_messages.inspect
        assert_equal({ name: "PROBE,ALPHA", sex: "F", dob: Date.new(1990, 5, 1), ssn: "", tribe: 611,
                       community_ien: 16379, community_since: :birth }, reg.register_attrs)
      end

      test "S-REG-02.2 a missing required field is named" do
        reg = registration(name: "", sex: "", dob: "", tribe_ien: "", community_ien: "")

        refute reg.valid?
        assert_equal %i[community_ien dob name sex tribe_ien], reg.errors.attribute_names.sort
      end

      test "S-REG-02.4 a name that is not LAST,FIRST, or is too long, names the format" do
        [ "PROBE ALPHA", "PROBE,ALPHA,BETA", "P,", "A" * 20 + "," + "B" * 15 ].each do |name|
          reg = registration(name: name)

          refute reg.valid?, name
          assert reg.errors.of_kind?(:name, :invalid) || reg.errors.of_kind?(:name, :too_long) || reg.errors.of_kind?(:name, :too_short), name
        end
      end

      test "a name is filed upper-case with single spaces" do
        assert_equal "PROBE,ALPHA JO", registration(name: " probe,alpha  jo ").name
      end

      test "S-REG-02.5 a date of birth in the future or before 1871 is refused" do
        refute registration(dob: (Date.current + 1).iso8601).valid?
        refute registration(dob: "1870-12-31").valid?
        assert registration(dob: "1871-01-01").valid?
      end

      test "S-REG-02.7 a social security number that is not nine digits names the format" do
        reg = registration(ssn: "12345")

        refute reg.valid?
        assert_includes reg.errors[:ssn], "must be nine digits"
        assert registration(ssn: "123-45-6789").valid?
      end

      test "the digest changes with any detail, so a review cannot be replayed onto another entry" do
        digests = [ registration, registration(name: "PROBE,BETA"), registration(dob: "1990-05-02"),
                    registration(sex: "M"), registration(ssn: "123456789"), registration(tribe_ien: "612"),
                    registration(community_ien: "16380") ].map(&:digest)

        assert_equal digests.size, digests.uniq.size
        assert_equal registration.digest, registration.digest
      end
    end
  end
end
