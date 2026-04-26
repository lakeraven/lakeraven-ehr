# frozen_string_literal: true

# NcpdpScriptGenerator -- Generate NCPDP SCRIPT standard XML messages
#
# ONC criteria: 170.315(b)(3) -- Electronic Prescribing
#
# Produces NCPDP SCRIPT 10.6 messages for e-prescribing workflows:
#   - NewRx: New prescription transmission
#   - CancelRx: Prescription cancellation
#   - RxFill: Refill notification
#   - RxChangeRequest: Medication change request

module Lakeraven
  module EHR
    class NcpdpScriptGenerator
      SCRIPT_VERSION = "10.6"

      def self.new_rx(order, prescriber:)
        new(order, prescriber: prescriber).build_new_rx
      end

      def self.cancel_rx(order, transmission_id:, reason:, prescriber:)
        new(order, prescriber: prescriber).build_cancel_rx(
          transmission_id: transmission_id, reason: reason
        )
      end

      def self.rx_fill(order, transmission_id:, prescriber:)
        new(order, prescriber: prescriber).build_rx_fill(
          transmission_id: transmission_id
        )
      end

      def self.rx_change_request(order, transmission_id:, new_medication:, prescriber:)
        new(order, prescriber: prescriber).build_rx_change_request(
          transmission_id: transmission_id,
          new_medication: new_medication
        )
      end

      def initialize(order, prescriber:)
        @order = order
        @prescriber = prescriber
      end

      def build_new_rx
        build_message("NewRx") do |xml|
          xml.NewRx {
            build_prescriber_section(xml)
            build_patient_section(xml)
            build_medication_prescribed(xml)
          }
        end
      end

      def build_cancel_rx(transmission_id:, reason:)
        build_message("CancelRx") do |xml|
          xml.CancelRx {
            xml.RxReferenceNumber(transmission_id)
            build_prescriber_section(xml)
            build_patient_section(xml)
            build_medication_prescribed(xml)
            xml.Note(reason) if reason.present?
          }
        end
      end

      def build_rx_fill(transmission_id:)
        build_message("RxFill") do |xml|
          xml.RxFill {
            xml.RxReferenceNumber(transmission_id)
            build_prescriber_section(xml)
            build_patient_section(xml)
            build_medication_prescribed(xml)
          }
        end
      end

      def build_rx_change_request(transmission_id:, new_medication:)
        build_message("RxChangeRequest") do |xml|
          xml.RxChangeRequest {
            xml.RxReferenceNumber(transmission_id)
            build_prescriber_section(xml)
            build_patient_section(xml)
            build_medication_prescribed(xml)
            xml.MedicationRequested {
              xml.DrugDescription(new_medication[:display])
              xml.DrugCoded {
                xml.ProductCode(new_medication[:code])
                xml.ProductCodeQualifier("RxNorm")
              }
            }
          }
        end
      end

      private

      def build_message(message_type)
        builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
          xml.Message(version: SCRIPT_VERSION) {
            build_header(xml, message_type)
            xml.Body {
              yield xml
            }
          }
        end
        builder.to_xml
      end

      def build_header(xml, message_type)
        xml.Header {
          xml.To("Surescripts")
          xml.From("RPMS")
          xml.MessageID(SecureRandom.uuid)
          xml.SentTime(Time.current.iso8601)
          xml.MessageType(message_type)
          xml.Version(SCRIPT_VERSION)
        }
      end

      def build_prescriber_section(xml)
        xml.Prescriber {
          xml.Identification {
            xml.NPI(@prescriber[:npi]) if @prescriber[:npi]
            xml.DEANumber(@prescriber[:dea]) if @prescriber[:dea]
          }
          xml.Name {
            parts = @prescriber[:name].to_s.split(/\s+/, 2)
            if parts.length > 1
              xml.FirstName(parts.first)
              xml.LastName(parts.last)
            else
              xml.LastName(@prescriber[:name])
            end
          }
        }
      end

      def build_patient_section(xml)
        xml.Patient {
          xml.Identification {
            xml.PatientID(@order.patient_dfn)
          }
          xml.Name {
            xml.LastName("Patient")
          }
        }
      end

      def build_medication_prescribed(xml)
        xml.MedicationPrescribed {
          xml.DrugDescription(@order.medication_display)
          xml.DrugCoded {
            xml.ProductCode(@order.medication_code)
            xml.ProductCodeQualifier("RxNorm")
          }
          xml.Quantity {
            xml.Value(@order.dispense_quantity.to_s)
            xml.CodeListQualifier("EA")
          }
          xml.Refills {
            xml.Value(@order.refills.to_s)
            xml.Qualifier("R")
          }
          xml.DaysSupply(@order.days_supply.to_s) if @order.days_supply.present?
          xml.Sig {
            xml.SigText(@order.dosage_instruction)
          }
          xml.Directions(@order.dosage_instruction)
        }
      end
    end
  end
end
