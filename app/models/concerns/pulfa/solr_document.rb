# frozen_string_literal: true

module Pulfa
  module SolrDocument
    def online_content?
      field_name = Solrizer.solr_name('digital_objects', :displayable)
      values = fetch(field_name, [])
      return false if values.empty?

      digital_objects = values.map { |value| JSON.parse(value) }
      digital_image_objects = digital_objects.select { |d_obj| d_obj['href'] && /\.jpe?g$/.match(d_obj['href']) }

      super && digital_image_objects.empty?
    end
  end
end
