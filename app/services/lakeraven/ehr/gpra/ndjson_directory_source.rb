# frozen_string_literal: true

module Lakeraven
  module EHR
    module Gpra
      # A GPRA population read from a directory of FHIR Bulk Data NDJSON (one
      # resource per line, a file per resource type), such as a Bulk $export's
      # output. Shaped per rook's FHIR mapping (docs/measures/fhir-mapping.md).
      #
      #   config.gpra_source = Lakeraven::EHR::Gpra::NdjsonDirectorySource.new("/srv/gpra/export")
      class NdjsonDirectorySource
        def initialize(dir, source_id: "site-bulk-export", platform: :rpms)
          @dir = dir.to_s
          @descriptor = Rook::SourceDescriptor.new(id: source_id, platform: platform, channel: :primary_fhir)
        end

        # Every resource in the directory. Raises when it holds no NDJSON, so a
        # wrong path fails the run instead of reporting an empty population.
        def resources
          Rook::Ingest.load(Rook::Ingest::NdjsonFeed.directory(@dir, source: @descriptor))
        end
      end
    end
  end
end
