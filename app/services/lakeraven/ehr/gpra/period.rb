# frozen_string_literal: true

module Lakeraven
  module EHR
    module Gpra
      # The GPRA year a date falls in: 1 July to 30 June, as CRS reports it.
      module Period
        def self.containing(date)
          start_year = date.month >= 7 ? date.year : date.year - 1
          Date.new(start_year, 7, 1)..Date.new(start_year + 1, 6, 30)
        end
      end
    end
  end
end
