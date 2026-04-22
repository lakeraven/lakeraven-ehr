# frozen_string_literal: true

module Lakeraven
  module EHR
    class KernelUser
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :duz, :integer
      attribute :name, :string
      attribute :title, :string

      def display_name
        return name if name.blank?

        parts = name.split(",")
        last = parts[0]&.strip
        first = parts[1]&.strip
        first.present? ? "#{first} #{last}" : last
      end

      def to_param = duz.to_s
    end
  end
end
