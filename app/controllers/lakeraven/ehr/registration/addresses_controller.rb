# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The front desk keeps a patient's address, phones and email current
      # (rpms-ux S-REG-21) through AG's Address window. A change of address keeps
      # the old one, ended on the date the patient moved (S-REG-21.1,
      # RpmsRpc::Registration.change_address); phones and email alone go through
      # RpmsRpc::Patient.update.
      class AddressesController < PatientEditsController
        rate_limit only: %i[edit update]

        # GET /registration/patients/:dfn/address/edit
        def edit
          @address = PatientAddress.from_record(@record)
          render_form(:ok)
        end

        # PATCH /registration/patients/:dfn/address
        def update
          @address = PatientAddress.new(address_params)
          return render_form(:unprocessable_content) unless @address.valid?

          save(@address, PatientAddress.from_record(@record), "Address and phones saved.") do |changes|
            if @address.moves?(changes)
              PatientRecordGateway.change_address(dfn, changes, moved_on: @address.moved_on)
            else
              PatientRecordGateway.update(dfn, changes)
            end
          end
        end

        private

        def render_form(status)
          @states = PatientRecordGateway.choices(:state)
          render :edit, status: status
        end

        def address_params
          params.fetch(:address, {}).permit(*PatientAddress::FIELDS, :moved_on).to_h
        end
      end
    end
  end
end
