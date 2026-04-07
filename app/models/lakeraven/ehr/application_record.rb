module Lakeraven
  module Ehr
    class ApplicationRecord < ActiveRecord::Base
      self.abstract_class = true
    end
  end
end
