# frozen_string_literal: true

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR
    end
  end
end
