# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # A ValueSet id that may be one file name inside a ValueSet directory.
      #
      # MeasureImportService#safe_valueset_id and LocalAdapter share this
      # rule. The pattern is the one MeasureImportService already used.
      # ".", "..", and a leading dot match that pattern too; they name this
      # directory, its parent, or a hidden file, so they are not ids.
      # A resolved file also has to stay inside the directory, including
      # when the name is a symlink.
      module ValueSetId
        PATTERN = /\A[A-Za-z0-9._-]+\z/

        def self.safe?(valueset_id)
          id = valueset_id.to_s
          id.match?(PATTERN) && id != "." && id != ".." && !id.start_with?(".")
        end

        def self.file_for(directory, valueset_id)
          id = valueset_id.to_s
          return unless safe?(id)

          contained_file(directory, File.join(directory.to_s, "#{id}.json"))
        end

        # Real path of filepath when it is a regular file inside directory.
        # nil when it is missing or the resolved path leaves the directory.
        def self.contained_file(directory, filepath)
          root = File.expand_path(directory.to_s)
          candidate = File.expand_path(filepath.to_s)
          return unless inside?(root, candidate)

          real_file_inside(root, candidate)
        end

        def self.real_file_inside(root, candidate)
          real_root = File.realpath(root)
          real_candidate = File.realpath(candidate)
          return unless inside?(real_root, real_candidate)
          return unless File.file?(real_candidate)

          real_candidate
        rescue SystemCallError
          nil
        end
        private_class_method :real_file_inside

        def self.inside?(directory, candidate)
          prefix = "#{directory.chomp(File::SEPARATOR)}#{File::SEPARATOR}"
          candidate.start_with?(prefix)
        end
        private_class_method :inside?
      end
    end
  end
end
