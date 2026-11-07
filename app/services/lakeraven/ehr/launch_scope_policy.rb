# frozen_string_literal: true

module Lakeraven
  module EHR
    # The scopes a SMART App Launch grants (#839): what the app asked for,
    # narrowed by what the app is registered for, narrowed again by what the
    # signed-in user's own RPMS options and keys allow (ADR 0010,
    # SessionScopePolicy). An app never gets more than its user holds.
    #
    # The user's allowance is the scope set of their browser session's token,
    # which SessionScopePolicy minted at sign-on. It is written in the user/
    # context; a patient/ request is measured against it type by type, because
    # reading one patient's record is a narrower act than reading any patient's.
    #
    # v1 scopes are accepted and come back in v2 (SmartScope). A wildcard
    # request is granted as the user's own per-type scopes, never as a wildcard
    # the user does not hold. Anything not understood is dropped, not guessed:
    # the token response's `scope` tells the app what it got.
    class LaunchScopePolicy
      def initialize(requested:, registered:, user_scopes:, contexts: %w[user])
        @requested = SmartScope.parse_all(requested.to_s).select { |s| contexts.include?(s.context) }
        @registered = SmartScope.parse_all(registered.to_s)
        @user = SmartScope.parse_all(user_scopes.to_s).select { |s| s.context == "user" }
      end

      # The granted clinical scopes, v2, one per context and type.
      def granted
        narrowed = @requested.flat_map do |requested|
          @registered.flat_map { |registered| intersect(requested, registered, same_context: true) }
                     .flat_map { |allowed| @user.flat_map { |held| intersect(allowed, held) } }
        end

        narrowed.group_by { |s| [ s.context, s.resource_type ] }
                .map { |_, same| same.reduce(:merge) }
                .map(&:to_s).sort
      end

      private

      # What both scopes allow, in a's context: the narrower type, the
      # permissions both name. Empty when they share no type or permission.
      def intersect(a, b, same_context: false)
        return [] if same_context && a.context != b.context

        type = narrower_type(a, b)
        common = a.permissions & b.permissions
        return [] if type.nil? || common.empty?

        [ SmartScope.build(a.context, type, common.join) ]
      end

      # The type both cover: a wildcard yields to a named type. Nil when none.
      def narrower_type(a, b)
        return b.resource_type if a.covers_type?(b.resource_type)

        a.resource_type if b.covers_type?(a.resource_type)
      end
    end
  end
end
