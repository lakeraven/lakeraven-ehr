# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/consent_write_test_helper"

module Lakeraven
  module EHR
    class SignaturePngRound4Test < ActiveSupport::TestCase
      include ConsentWriteTestHelper

      {
        "APNG acTL fcTL fdAT" => :apng_extra_blank_frame_pad_png,
        "gAMA extreme" => :gama_extreme_pad_png,
        "iCCP" => :iccp_pad_png,
        "tEXt" => :text_pad_png,
        "sRGB" => :srgb_pad_png
      }.each do |label, builder|
        test "pad inked PNG with disallowed #{label} chunk is not acceptable" do
          refute SignaturePng.acceptable?(send(builder)),
                 "expected #{label} ancillary chunk to be refused by allow-list"
        end
      end

      test "plain pad-sized visible and dark-on-white PNGs stay acceptable" do
        assert SignaturePng.acceptable?(pad_sized_visible_signature_png)
        assert SignaturePng.acceptable?(dark_stroke_on_white_pad_png)
      end
    end
  end
end
