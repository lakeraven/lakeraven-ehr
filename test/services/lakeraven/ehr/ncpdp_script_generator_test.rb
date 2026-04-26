# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class NcpdpScriptGeneratorTest < ActiveSupport::TestCase
      setup do
        @order = MedicationRequest.new(
          ien: "med-001",
          patient_dfn: "12345",
          requester_duz: "789",
          requester_name: "Dr. Smith",
          medication_display: "Lisinopril 10 MG Oral Tablet",
          medication_code: "197884",
          status: "active",
          intent: "order",
          dosage_instruction: "Take 1 tablet daily",
          route: "oral",
          frequency: "daily",
          dispense_quantity: 30,
          refills: 3,
          days_supply: 30,
          authored_on: Time.current
        )
        @prescriber = {
          duz: "789", name: "Dr. Smith", npi: "1234567890", dea: "AS1234567"
        }
      end

      # =====================================================================
      # NewRx MESSAGE
      # =====================================================================

      test "new_rx generates valid XML" do
        xml = NcpdpScriptGenerator.new_rx(@order, prescriber: @prescriber)
        doc = Nokogiri::XML(xml) { |config| config.strict }

        assert doc.errors.empty?, "Expected valid XML, got errors: #{doc.errors.map(&:message)}"
      end

      test "new_rx includes Message element with NewRx body" do
        doc = parse_new_rx

        message = doc.at_xpath("//Message")
        assert message.present?, "Expected Message root element"
        body = doc.at_xpath("//Body/NewRx")
        assert body.present?, "Expected Body/NewRx element"
      end

      test "new_rx includes header with message ID and timestamp" do
        doc = parse_new_rx

        header = doc.at_xpath("//Header")
        assert header.present?, "Expected Header element"
        msg_id = doc.at_xpath("//Header/MessageID")
        assert msg_id&.text.present?, "Expected MessageID"
        sent_time = doc.at_xpath("//Header/SentTime")
        assert sent_time&.text.present?, "Expected SentTime"
      end

      test "new_rx includes prescriber NPI and DEA" do
        doc = parse_new_rx

        npi = doc.at_xpath("//Prescriber//NPI")
        assert_equal "1234567890", npi&.text
        dea = doc.at_xpath("//Prescriber//DEANumber")
        assert_equal "AS1234567", dea&.text
      end

      test "new_rx includes prescriber name" do
        doc = parse_new_rx

        name = doc.at_xpath("//Prescriber//LastName") || doc.at_xpath("//Prescriber//Name")
        assert name&.text.present?, "Expected prescriber name"
      end

      test "new_rx includes patient demographics" do
        doc = parse_new_rx

        patient = doc.at_xpath("//Patient")
        assert patient.present?, "Expected Patient element"
        dfn = doc.at_xpath("//Patient//Identification") || doc.at_xpath("//Patient//PatientID")
        assert dfn.present?, "Expected patient identification"
      end

      test "new_rx includes medication with RxNorm code" do
        doc = parse_new_rx

        med = doc.at_xpath("//MedicationPrescribed")
        assert med.present?, "Expected MedicationPrescribed element"
        drug = doc.at_xpath("//MedicationPrescribed//DrugDescription")
        assert drug&.text&.include?("Lisinopril"), "Expected drug description"
        code = doc.at_xpath("//MedicationPrescribed//DrugCoded//ProductCode")
        assert_equal "197884", code&.text
      end

      test "new_rx includes quantity and refills" do
        doc = parse_new_rx

        quantity = doc.at_xpath("//MedicationPrescribed//Quantity//Value")
        assert_equal "30", quantity&.text
        refills = doc.at_xpath("//MedicationPrescribed//Refills//Value")
        assert_equal "3", refills&.text
      end

      test "new_rx includes days supply" do
        doc = parse_new_rx

        days = doc.at_xpath("//MedicationPrescribed//DaysSupply")
        assert_equal "30", days&.text
      end

      test "new_rx includes sig/directions" do
        doc = parse_new_rx

        sig = doc.at_xpath("//MedicationPrescribed//Sig//SigText") ||
              doc.at_xpath("//MedicationPrescribed//Directions")
        assert sig&.text&.include?("Take 1 tablet daily"), "Expected sig text"
      end

      # =====================================================================
      # CancelRx MESSAGE
      # =====================================================================

      test "cancel_rx generates valid XML with CancelRx body" do
        xml = NcpdpScriptGenerator.cancel_rx(
          @order,
          transmission_id: "erx-001",
          reason: "Patient allergy discovered",
          prescriber: @prescriber
        )
        doc = Nokogiri::XML(xml) { |config| config.strict }

        assert doc.errors.empty?
        body = doc.at_xpath("//Body/CancelRx")
        assert body.present?, "Expected Body/CancelRx"
      end

      test "cancel_rx includes reason" do
        xml = NcpdpScriptGenerator.cancel_rx(
          @order,
          transmission_id: "erx-001",
          reason: "Patient allergy discovered",
          prescriber: @prescriber
        )
        doc = Nokogiri::XML(xml)

        note = doc.at_xpath("//Note") || doc.at_xpath("//ReasonCode")
        assert note&.text&.include?("Patient allergy"), "Expected cancellation reason"
      end

      # =====================================================================
      # RxFill MESSAGE
      # =====================================================================

      test "rx_fill generates valid XML with RxFill body" do
        xml = NcpdpScriptGenerator.rx_fill(
          @order,
          transmission_id: "erx-002",
          prescriber: @prescriber
        )
        doc = Nokogiri::XML(xml) { |config| config.strict }

        assert doc.errors.empty?
        body = doc.at_xpath("//Body/RxFill")
        assert body.present?, "Expected Body/RxFill"
      end

      # =====================================================================
      # RxChangeRequest MESSAGE
      # =====================================================================

      test "rx_change_request generates valid XML with RxChangeRequest body" do
        xml = NcpdpScriptGenerator.rx_change_request(
          @order,
          transmission_id: "erx-003",
          new_medication: { code: "197885", display: "Lisinopril 20 MG Oral Tablet" },
          prescriber: @prescriber
        )
        doc = Nokogiri::XML(xml) { |config| config.strict }

        assert doc.errors.empty?
        body = doc.at_xpath("//Body/RxChangeRequest")
        assert body.present?, "Expected Body/RxChangeRequest"
      end

      test "rx_change_request includes new medication" do
        xml = NcpdpScriptGenerator.rx_change_request(
          @order,
          transmission_id: "erx-003",
          new_medication: { code: "197885", display: "Lisinopril 20 MG Oral Tablet" },
          prescriber: @prescriber
        )
        doc = Nokogiri::XML(xml)

        requested = doc.at_xpath("//MedicationRequested") || doc.at_xpath("//RequestedMedication")
        assert requested.present?, "Expected requested medication"
        desc = requested.at_xpath(".//DrugDescription")
        assert desc&.text&.include?("Lisinopril 20"), "Expected new medication description"
      end

      # =====================================================================
      # PERFORMANCE
      # =====================================================================

      test "new_rx generation completes within 2 seconds" do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        NcpdpScriptGenerator.new_rx(@order, prescriber: @prescriber)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

        assert elapsed < 2.0, "NCPDP SCRIPT generation took #{elapsed}s, expected < 2s"
      end

      private

      def parse_new_rx
        xml = NcpdpScriptGenerator.new_rx(@order, prescriber: @prescriber)
        Nokogiri::XML(xml)
      end
    end
  end
end
