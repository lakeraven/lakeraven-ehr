# frozen_string_literal: true

require "test_helper"

# VitalGateway.template (#1153): the vital-entry grid's fields for a patient's
# visit, read through RpmsRpc::Vital.template.
module Lakeraven
  module EHR
    class VitalGatewayTest < ActiveSupport::TestCase
      DFN = "4"
      VISIT = "349;3260514.09;A;2090059"

      # The grid's first two vital types for DFN 4 on that visit, as
      # RpmsRpc::Vital.template returns them from the reply a container of the
      # build rpms-rpc pins answered (rpms-rpc test/fixtures/captured_replies/
      # read-call-formals.yml, behovm_template).
      TEMPLATE = [
        { ien: 3, measurement_type_ien: 3, name: "TEMPERATURE", abbreviation: "TMP", units: "F", low: nil, high: nil,
          percentile_rpc: nil, has_qualifiers: true, decimal_places: 2 },
        { ien: 5, measurement_type_ien: 5, name: "PULSE", abbreviation: "PU", units: "/min", low: "60", high: "100",
          percentile_rpc: nil, has_qualifiers: true, decimal_places: 2 }
      ].freeze

      setup { RpmsStandIn.answer(RpmsRpc::Vital, :template, with: TEMPLATE) }

      test "template asks for the patient and the visit string in the site's units and returns the grid's vital types" do
        assert_equal TEMPLATE, VitalGateway.template(DFN, VISIT)
        assert_equal [ { args: [ DFN, VISIT ], kwargs: { metric: -1 } } ], RpmsStandIn.calls(RpmsRpc::Vital, :template)
      end

      test "template asks for metric units when told to" do
        VitalGateway.template(DFN, VISIT, metric: 1)

        assert_equal [ { args: [ DFN, VISIT ], kwargs: { metric: 1 } } ], RpmsStandIn.calls(RpmsRpc::Vital, :template)
      end
    end
  end
end
