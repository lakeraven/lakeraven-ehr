# frozen_string_literal: true

require "test_helper"

# VitalGateway.template (#1153): the vital-entry grid's fields for a patient's
# visit, read through RpmsRpc::Vital.template.
module Lakeraven
  module EHR
    class VitalGatewayTest < ActiveSupport::TestCase
      include BrokerStubbing

      DFN = "4"
      VISIT = "349;3260514.09;A;2090059"

      # BEHOVM TEMPLATE for DFN 4 on that visit, as a container of the build
      # rpms-rpc pins answered it (rpms-rpc test/fixtures/captured_replies/
      # read-call-formals.yml, behovm_template), the first rows after its
      # count header "20^0^0".
      CAPTURED_TEMPLATE = [
        "20^0^0",
        "3^3^TEMPERATURE^TMP^F^^^^1^2",
        "5^5^PULSE^PU^/min^60^100^^1^2",
        "15^15^RESPIRATIONS^RS^/min^^^^1^2",
        "4^4^BLOOD PRESSURE^BP^mmHg^90^150^^1^2",
        "344^22^O2 SATURATION^O2^%^^^^1^2",
        "21^21^PAIN^PA^^^^^0^2",
        "1^1^HEIGHT^HT^in^^^BEHOVM PCTILE^1^2",
        "2^2^WEIGHT^WT^lb^^^BEHOVM PCTILE^1^3",
        "9^9^VISION CORRECTED^VC^^^^^0^2",
        "8^8^VISION UNCORRECTED^VU^^^^^0^2",
        "10^10^AUDIOMETRY^AUD^^^^^0^2",
        "6^6^HEAD CIRCUMFERENCE^HC^in^^^BEHOVM PCTILE^1^2",
        "47^60^ESTIMATED GESTATIONAL AGE^EGA^^^^^0^2",
        "13^13^FUNDAL HEIGHT^FH^cm^^^^0^2",
        "14^14^FETAL HEART TONES^FT^^^^^1^2",
        "16^16^EDEMA^ED^^^^^0^2",
        "46^59^MINI MENTAL STATUS EXAM^MMSE^^^^^0^2",
        "27^41^PHQ2^PHQ2^^^^^0^2",
        "28^42^PHQ9^PHQ9^^^^^0^2",
        "31^25^ANKLE BLOOD PRESSURE^AKBP^mmHg^90^150^^1^2"
      ].join("\n").freeze

      test "template sends the patient and the visit string and returns the grid's vital types" do
        broker = FakeBroker.new.on("BEHOVM TEMPLATE", CAPTURED_TEMPLATE)

        rows = use_broker(broker) { VitalGateway.template(DFN, VISIT) }

        assert_equal [ DFN, VISIT, "-1" ], broker.calls_for("BEHOVM TEMPLATE").last[:params]
        assert_equal 20, rows.length, "the count header names the 20 vital rows, and is not one of them"
        assert_includes rows.map(&:values).flatten.map(&:to_s), "TEMPERATURE"
      end

      test "template asks for metric units when told to" do
        broker = FakeBroker.new.on("BEHOVM TEMPLATE", CAPTURED_TEMPLATE)

        use_broker(broker) { VitalGateway.template(DFN, VISIT, metric: 1) }

        assert_equal [ DFN, VISIT, "1" ], broker.calls_for("BEHOVM TEMPLATE").last[:params]
      end
    end
  end
end
