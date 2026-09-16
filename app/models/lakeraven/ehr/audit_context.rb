# frozen_string_literal: true

module Lakeraven
  module EHR
    # WHO is acting, for code that is nowhere near a controller.
    #
    # The HTTP boundary knows the actor; the RPMS broker, three layers down,
    # does not — and a backend action recorded with no actor is the
    # "who opened this chart" question going unanswered. So the audited
    # request PUBLISHES its actor here and anything further down reads it.
    #
    # Deliberately a resolver, not a value: identity is established by the
    # authentication before_action, which runs INSIDE the audit wrapper, so
    # the actor is not yet known at the moment the context is published.
    #
    # Nothing here is ever guessed. Outside a request — a job, a rake task,
    # a console — there is no resolver and the access is recorded as
    # UNATTRIBUTED, which is worth more than a misattributed row.
    class AuditContext < ActiveSupport::CurrentAttributes
      attribute :agent_resolver, :network_address, :tenant_identifier,
                :facility_identifier, :inside_audited_request

      UNATTRIBUTED = { agent_who_type: "Unknown", agent_who_identifier: nil }.freeze

      class << self
        # The agent attributes for an AuditEvent written outside a controller.
        def agent_attributes
          return UNATTRIBUTED.dup unless agent_resolver.respond_to?(:call)

          attrs = agent_resolver.call
          attrs.is_a?(Hash) && attrs[:agent_who_identifier].present? ? attrs : UNATTRIBUTED.dup
        rescue StandardError => e
          Rails.logger.error("[audit] could not resolve the acting identity: #{e.message}")
          UNATTRIBUTED.dup
        end

        # True while an audited HTTP request is in flight. Backend actions
        # taken outside one are the ones with nobody to answer for them.
        def inside_audited_request?
          inside_audited_request.present?
        end
      end
    end
  end
end
