# frozen_string_literal: true

module Lakeraven
  module EHR
    module DrugInteraction
      class BaseAdapter
        # Check drug-drug interactions for a set of medications.
        # Returns Array<InteractionAlert>
        def check_interactions(medications)
          raise NotImplementedError, "#{self.class}#check_interactions"
        end

        # Check drug-allergy cross-reactivity for a medication against known allergies.
        # Returns Array<InteractionAlert>
        def check_allergies(medication, allergies)
          raise NotImplementedError, "#{self.class}#check_allergies"
        end
      end
    end
  end
end
