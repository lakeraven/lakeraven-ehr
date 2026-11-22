# frozen_string_literal: true

# Makes Unicode normalisation fail for the length of a block (#906 owner
# continue): String#unicode_normalize and String#unicode_normalize! raise the
# given error. The classifier must read a failed normalisation as
# :unclassified (fail closed), never as clean and never as an exception.
#
#   with_failing_unicode_normalisation(ArgumentError) do |fired|
#     ...
#     refute_empty fired, "the synthetic normalisation failure never fired"
#   end
#
# only: when given, only a receiver equal to that text fails, so a whole
# request can run inside the block without disturbing anything else that
# normalises a String. The original methods are always restored.
module SudNormalisationFailure
  METHODS = %i[unicode_normalize unicode_normalize!].freeze
  SYNTHETIC_MESSAGE = "synthetic: unicode normalisation failed"

  def with_failing_unicode_normalisation(error_class, only: nil)
    fired = []
    originals = METHODS.to_h { |name| [ name, String.instance_method(name) ] }
    METHODS.each do |name|
      original = originals.fetch(name)
      String.send(:define_method, name) do |*args|
        return original.bind_call(self, *args) unless only.nil? || self == only

        fired << name
        raise error_class, SYNTHETIC_MESSAGE
      end
    end
    yield fired
  ensure
    originals&.each { |name, original| String.send(:define_method, name, original) }
  end
end
