module Lakeraven
  module EHR
    class ApplicationRecord < ActiveRecord::Base
      self.abstract_class = true
    end
  end
end
