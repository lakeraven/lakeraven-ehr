# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The patient's emergency contact and next of kin (rpms-ux S-REG-08).
      #
      # A save sends RPMS only the fields the clerk changed (ContactEntry#changes_from):
      # a new name clears the old contact's address and phones in RPMS, so the new
      # person never inherits them (S-REG-08.2).
      class ContactsController < PatientSectionController
        EDIT_ACTIONS = %w[edit update].freeze

        before_action :load_kind, only: %i[edit update]

        # GET /registration/patients/:dfn/contacts
        def show
          @contacts = PatientProfileGateway.contacts(@dfn)
        end

        # GET or POST /registration/patients/:dfn/contacts/:kind/edit. A POST is a
        # relationship or state look-up, and carries what the clerk typed.
        def edit
          @contact = request.post? ? ContactEntry.new(contact_params) : ContactEntry.from_rpms(current_contact)
          load_lookups
        end

        # POST /registration/patients/:dfn/contacts/:kind
        def update
          @contact = ContactEntry.new(contact_params)
          load_lookups
          return render(:edit, status: :unprocessable_content) unless @contact.valid?

          changes = @contact.changes_from(ContactEntry.from_rpms(current_contact))
          return redirect_to(registration_patient_contacts_path(@dfn), notice: "Nothing was changed.") if changes.empty?

          result = PatientProfileGateway.update_contact(@dfn, @kind, changes)
          if result.saved?
            redirect_to registration_patient_contacts_path(@dfn), notice: "#{ContactEntry::KINDS[@kind]} saved."
          else
            @contact.errors.add(form_field(result.field), result.message) if result.field && result.message.present?
            flash.now[:alert] = write_failure_message(result, ContactEntry::KINDS[@kind].downcase)
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        private

        def load_kind
          @kind = params[:kind].to_s
          head :not_found unless ContactEntry::KINDS.key?(@kind)
        end

        def current_contact
          PatientProfileGateway.contacts(@dfn).fetch(@kind.to_sym, {})
        end

        def load_lookups
          @relationships = PatientProfileGateway.relationships(params[:relationship_search])
          @states = PatientProfileGateway.states(params[:state_search])
          name_choice(:relationship, @relationships)
          name_choice(:state, @states)
        end

        # A choice picked from the look-up's matches carries the match's name.
        def name_choice(field, rows)
          row = rows.find { |r| r[:ien].to_s == @contact.public_send(:"#{field}_ien").to_s }
          @contact.public_send(:"#{field}_name=", row[:name]) if row
        end

        # The gem's field name, as the form names it.
        def form_field(field) = ContactEntry::FIELDS.key(field.to_sym) || field.to_sym

        def contact_params
          params.fetch(:contact, {}).permit(*ContactEntry.attribute_names.map(&:to_sym)).to_h
        end
      end
    end
  end
end
