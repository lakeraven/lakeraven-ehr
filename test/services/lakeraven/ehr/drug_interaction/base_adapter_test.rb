# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class BaseAdapterTest < ActiveSupport::TestCase
        test "BaseAdapter#backend raises NotImplementedError" do
          adapter = BaseAdapter.new
          assert_respond_to adapter, :backend, "BaseAdapter must define #backend"
          assert_raises(NotImplementedError) { adapter.backend }
        end
      end
    end
  end
end
