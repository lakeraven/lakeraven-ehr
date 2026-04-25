# frozen_string_literal: true

module Lakeraven
  module EHR
    # Terminology Service - Abstraction for ValueSet Operations
    # Ported from rpms_redux TerminologyService.
    #
    # Provides a unified interface for terminology operations backed by:
    #   1. VSAC (NLM's Value Set Authority Center) - production
    #   2. Local ValueSets (extracted from GPRA) - fallback
    #   3. IRIS for Health terminology server - future
    #
    # Usage:
    #   service = Lakeraven::EHR::TerminologyService.new
    #   service.expand_valueset("gpra-diabetes-dx")
    #   service.code_in_valueset?("E11.9", "gpra-diabetes-dx")
    class TerminologyService
      BACKEND_VSAC = :vsac
      BACKEND_LOCAL = :local
      BACKEND_IRIS = :iris

      CACHE_NAMESPACE = "terminology"
      EXPANSION_CACHE_EXPIRY = 15.minutes
      VALUESET_CACHE_EXPIRY = 1.hour

      class ValueSetNotFoundError < StandardError; end

      # Configurable valueset search paths.
      # Allows host apps to contribute additional valueset directories.
      cattr_accessor :additional_valueset_paths, default: []

      def initialize(backend: nil, use_distributed_cache: true)
        @backend = backend || detect_backend
        @use_distributed_cache = use_distributed_cache && defined?(Rails) && Rails.cache.present?
        @local_cache = {}
      end

      # Expand a ValueSet to get all codes
      def expand_valueset(valueset_id)
        cached = @local_cache[valueset_id]
        return cached if cached

        if @use_distributed_cache
          cache_key = expansion_cache_key(valueset_id)
          codes = Rails.cache.fetch(cache_key, expires_in: EXPANSION_CACHE_EXPIRY) do
            fetch_valueset_codes(valueset_id)
          end
        else
          codes = fetch_valueset_codes(valueset_id)
        end

        @local_cache[valueset_id] = codes
        codes
      end

      # Check if a code is in a ValueSet
      def code_in_valueset?(code, valueset_id, system: nil, prefix: false)
        codes = expand_valueset(valueset_id)
        codes.any? do |c|
          code_matches = if prefix
                           code.to_s.upcase.start_with?(c[:code].to_s.upcase)
          else
                           c[:code] == code
          end
          code_matches && (system.nil? || c[:system] == system)
        end
      end

      # Get ValueSet metadata (without expansion)
      def get_valueset(valueset_id)
        case @backend
        when BACKEND_LOCAL
          load_local_valueset(valueset_id)
        else
          raise NotImplementedError, "get_valueset not available for #{@backend}"
        end
      end

      # Search for ValueSets
      def search(query)
        case @backend
        when BACKEND_LOCAL
          search_local(query)
        else
          raise NotImplementedError, "search not available for #{@backend}"
        end
      end

      # List all available ValueSets
      def list_valuesets
        case @backend
        when BACKEND_LOCAL
          list_local_valuesets
        else
          raise NotImplementedError, "list_valuesets not available for #{@backend}"
        end
      end

      # Clear the cache (both local and distributed)
      def clear_cache!
        @local_cache = {}
        clear_distributed_cache! if @use_distributed_cache
      end

      def clear_distributed_cache!
        return unless @use_distributed_cache

        if Rails.cache.respond_to?(:delete_matched)
          Rails.cache.delete_matched("#{CACHE_NAMESPACE}:*")
        end
      end

      attr_reader :backend

      def distributed_cache_enabled?
        @use_distributed_cache
      end

      private

      def expansion_cache_key(valueset_id)
        "#{CACHE_NAMESPACE}:#{@backend}:expansion:#{valueset_id}"
      end

      def fetch_valueset_codes(valueset_id)
        case @backend
        when BACKEND_LOCAL
          expand_from_local(valueset_id)
        else
          raise "Unknown backend: #{@backend}"
        end
      end

      def detect_backend
        if ENV["IRIS_TERMINOLOGY_URL"].present?
          BACKEND_IRIS
        elsif ENV["UMLS_API_KEY"].present?
          BACKEND_VSAC
        else
          BACKEND_LOCAL
        end
      end

      # ==========================================================================
      # Local Backend (GPRA-extracted ValueSets)
      # ==========================================================================

      def expand_from_local(valueset_id)
        valueset = load_local_valueset(valueset_id)
        raise ValueSetNotFoundError, "Local ValueSet not found: #{valueset_id}" unless valueset

        includes = valueset.dig("compose", "include") || []
        includes.flat_map do |include_set|
          system = include_set["system"]
          concepts = include_set["concept"] || []
          concepts.map do |concept|
            {
              system: system,
              code: concept["code"],
              display: concept["display"]
            }
          end
        end
      end

      def load_local_valueset(valueset_id)
        filename = "#{valueset_id}.json"
        all_valueset_paths.each do |path|
          filepath = path.join(filename)
          return JSON.parse(File.read(filepath)) if File.exist?(filepath)
        end
        nil
      end

      def search_local(query)
        list_local_valuesets.select do |vs|
          vs["title"]&.downcase&.include?(query.downcase) ||
            vs["name"]&.downcase&.include?(query.downcase)
        end
      end

      def list_local_valuesets
        all_valueset_paths.flat_map do |path|
          Dir.glob(path.join("*.json")).map { |f| JSON.parse(File.read(f)) }
        end.uniq { |vs| vs["id"] || vs["name"] }
      end

      # Ordered list of paths to search for ValueSet JSON files.
      # Engine root first, then any additional paths configured by host app.
      def all_valueset_paths
        paths = [ Lakeraven::EHR::Engine.root.join("db", "valuesets") ]
        paths.concat(self.class.additional_valueset_paths.map { |p| Pathname.new(p) })
        paths.select { |p| p.exist? }
      end

      # ==========================================================================
      # GPRA to VSAC Mapping
      # ==========================================================================

      def resolve_oid(valueset_id)
        return valueset_id if valueset_id.match?(/^\d+\.\d+/)

        mapping = gpra_to_vsac_mapping[valueset_id]
        raise ValueSetNotFoundError, "No VSAC mapping for: #{valueset_id}" unless mapping

        mapping[:oid]
      end

      def gpra_to_vsac_mapping
        @gpra_to_vsac_mapping ||= {
          "gpra-bgpmu-diabetes-dx" => { oid: "2.16.840.1.113883.3.464.1003.103.12.1001", name: "Diabetes" },
          "gpra-bgpmu-gestational-diabetes-dx" => { oid: "2.16.840.1.113883.3.464.1003.103.12.1010", name: "Gestational Diabetes" },
          "gpra-bgpmu-steroid-diabetes-dx" => { oid: "2.16.840.1.113883.3.464.1003.103.12.1001", name: "Diabetes" },
          "gpra-bgpmu-a1c-loinc" => { oid: "2.16.840.1.113883.3.464.1003.198.12.1013", name: "HbA1c Laboratory Test" },
          "gpra-bgpmu-hypertension-dx" => { oid: "2.16.840.1.113883.3.464.1003.104.12.1011", name: "Essential Hypertension" },
          "gpra-bgpmu-ischemic-stroke-dx" => { oid: "2.16.840.1.113883.3.117.1.7.1.247", name: "Ischemic Stroke" },
          "gpra-bgpmu-hemorrhagic-stroke-dx" => { oid: "2.16.840.1.113883.3.117.1.7.1.212", name: "Hemorrhagic Stroke" },
          "gpra-bgpmu-atrial-fib-dx" => { oid: "2.16.840.1.113883.3.526.3.1184", name: "Atrial Fibrillation/Flutter" },
          "gpra-bgpmu-atherosclerosis-dx" => { oid: "2.16.840.1.113883.3.464.1003.104.12.1003", name: "Atherosclerotic Heart Disease" },
          "gpra-bgpmu-vte-dx" => { oid: "2.16.840.1.113883.3.117.1.7.1.279", name: "Venous Thromboembolism" },
          "gpra-bgpmu-esrd-dx" => { oid: "2.16.840.1.113883.3.464.1003.109.12.1028", name: "End Stage Renal Disease" },
          "gpra-bgpmu-esrd-cpt" => { oid: "2.16.840.1.113883.3.464.1003.109.12.1013", name: "Dialysis Services" },
          "gpra-bgpmu-depression-dx" => { oid: "2.16.840.1.113883.3.600.145", name: "Major Depression" },
          "gpra-bgpmu-colonoscopy-cpt" => { oid: "2.16.840.1.113883.3.464.1003.108.12.1038", name: "Colonoscopy" },
          "gpra-bgpmu-colon-cancer-dx" => { oid: "2.16.840.1.113883.3.464.1003.108.12.1001", name: "Malignant Neoplasm of Colon" },
          "gpra-bgpmu-mammogram-cpt" => { oid: "2.16.840.1.113883.3.464.1003.108.12.1018", name: "Mammography" },
          "gpra-bgpmu-cervical-cytology-cpt" => { oid: "2.16.840.1.113883.3.464.1003.108.12.1017", name: "Pap Test" },
          "gpra-bgpmu-flu-vaccine" => { oid: "2.16.840.1.113883.3.464.1003.110.12.1030", name: "Influenza Vaccine" },
          "gpra-bgpmu-ldl-loinc" => { oid: "2.16.840.1.113883.3.464.1003.198.12.1016", name: "LDL Cholesterol" },
          "gpra-bgpmu-bmi-loinc" => { oid: "2.16.840.1.113762.1.4.1", name: "Body Mass Index (BMI) Ratio" },
          "gpra-bgp-microalbum-loinc-codes" => { oid: "2.16.840.1.113883.3.464.1003.109.12.1024", name: "Urine Albumin Tests" },
          "gpra-bgpmu-lab-loinc-inr" => { oid: "2.16.840.1.113883.3.117.1.7.1.213", name: "INR" },
          "gpra-bgpmu-tobacco-dx" => { oid: "2.16.840.1.113883.3.526.3.1170", name: "Tobacco Use" },
          "gpra-bgpmu-hiv-dx" => { oid: "2.16.840.1.113883.3.464.1003.120.12.1003", name: "HIV" },
          "gpra-bgpmu-hiv-prenatal-scrn-loinc" => { oid: "2.16.840.1.113883.3.464.1003.120.12.1002", name: "HIV Viral Load" },
          "gpra-bgpmu-statin-ndcs" => { oid: "2.16.840.1.113883.3.464.1003.196.12.1253", name: "Statin Therapy" },
          "gpra-bgpmu-warfarin-ndcs" => { oid: "2.16.840.1.113883.3.117.1.7.1.232", name: "Warfarin" },
          "gpra-bgpmu-anticoag-ndcs" => { oid: "2.16.840.1.113883.3.117.1.7.1.200", name: "Anticoagulant Therapy" }
        }.freeze
      end
    end
  end
end
