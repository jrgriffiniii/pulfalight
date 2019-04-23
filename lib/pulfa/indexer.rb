# frozen_string_literal: true

require_relative 'normalized_title'
require_relative 'normalized_date'

module Pulfa
  class Indexer < Arclight::Indexer
    def normalize_title(data)
      Pulfa::NormalizedTitle.new(
        data[:title],
        Pulfa::NormalizedDate.new(
          data[:unitdate_inclusive],
          data[:unitdate_bulk],
          data[:unitdate_other]
        ).to_s
      ).to_s
    end
  end
end
