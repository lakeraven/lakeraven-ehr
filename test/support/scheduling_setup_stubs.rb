# frozen_string_literal: true

# RpmsRpc::SchedulingSetup stood in for in a scheduling test's with_rpms stubs
# table ({ singleton_class => { method => body } }): a clinic with no booking
# rules, no holiday and one access type that does not prevent access, unless the
# test passes its own. The shapes are SchedulingSetup's, as a live rpms-ydb
# 7c3119b build answered them.
module SchedulingSetupStubs
  GENERAL = { id: 1, name: "DEMO GENERAL", inactive: false, prevent_access: false }.freeze

  def scheduling_setup_stubs(rules: nil, holidays: [], access_types: [ GENERAL ])
    {
      RpmsRpc::SchedulingSetup.singleton_class => {
        clinic_rules: ->(_id) { rules },
        holidays: ->(start_date:, end_date:) { holidays.select { |h| (start_date..end_date).cover?(h[:date]) } },
        access_types: ->(*) { access_types }
      }
    }
  end
end
