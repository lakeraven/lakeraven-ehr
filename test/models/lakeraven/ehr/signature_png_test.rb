# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/consent_write_test_helper"

module Lakeraven
  module EHR
    class SignaturePngTest < ActiveSupport::TestCase
      include ConsentWriteTestHelper

      test "blank opaque white RGBA and grey+alpha pads are not acceptable ink" do
        refute SignaturePng.acceptable?(blank_opaque_white_rgba_pad_png),
               "solid opaque white RGBA must not count as a signature stroke"
        refute SignaturePng.acceptable?(blank_opaque_white_graya_pad_png),
               "solid opaque white grey+alpha must not count as a signature stroke"
      end

      test "near-white opaque strokes on transparent paper are not acceptable ink" do
        refute SignaturePng.acceptable?(near_white_ink_on_transparent_pad_png),
               "near-white ink on transparent paper must not contrast with a white page background"
      end

      test "dark strokes on transparent or on white remain acceptable" do
        assert SignaturePng.acceptable?(pad_sized_visible_signature_png)
        assert SignaturePng.acceptable?(dark_stroke_on_white_pad_png)
      end

      test "decoded dimensions above 1800 by 600 are refused before accept" do
        refute SignaturePng.acceptable?(overwide_pad_signature_png),
               "width above 1800 must be refused"
        refute SignaturePng.acceptable?(overtall_pad_signature_png),
               "height above 600 must be refused"
        assert SignaturePng.acceptable?(max_pad_dimension_signature_png(width: 1800, height: 600)),
               "1800×600 with a visible stroke must be accepted"
      end
    end
  end
end
