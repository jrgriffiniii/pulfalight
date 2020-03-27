
# frozen_string_literal: true
# Asynchronous job used to index EAD Documents
class IndexJob < ApplicationJob
  # Class for capturing the output of the Traject indexer
  class EADArray < Array
    # Appends the output of the Traject indexer
    # (Used by Traject#foo)
    # @param context [Traject::Context]
    def put(context)
      push(context.output_hash)
    end
  end

  # Retrieve the file path for the ArcLight core Traject configuration
  # @return [String]
  def arclight_config_path
    pathname = Rails.root.join("lib", "pulfalight", "traject", "ead2_config.rb")
    pathname.to_s
  end

  # Construct a Traject indexer object for building Solr Documents from EADs
  # @return [Traject::Indexer::NokogiriIndexer]
  def indexer
    indexer = Traject::Indexer::NokogiriIndexer.new
    indexer.tap do |i|
      i.load_config_file(arclight_config_path)
    end
  end

  # Retrieve the connection to the Solr index for Blacklight
  # @return [RSolr]
  def blacklight_connection
    repository = Blacklight.default_index
    repository.connection
  end

  # Generate the XML Documents from a set of EAD file paths
  # @return [Array<Nokogiri::XML::Document>]
  def xml_documents
    @xml_documents ||= @file_paths.map do |file_path|
      doc_string = File.open(file_path)
      document = Nokogiri::XML.parse(doc_string)
      document.remove_namespaces!
      document
    end
  end

  def logger
    Rails.logger || Logger.new(STDOUT)
  end

  def build_navigation_tree(solr_document)
    tree = {}

    collection_ids = solr_document['id']
    collection_id = collection_ids.first
    components = solr_document['components']

    # Empty the components
    solr_document['components'] = nil

    # Set the children to empty
    solr_document['children'] = []
    tree['root'] = solr_document
    tree[collection_id] = tree['root']

    components.each do |component|
      logger.info "Processing #{component['id']}"

      parent_ids = component['parent_ssi']
      parent_id = parent_ids.first

      component_ids = component['id']
      component_id = component_ids.first

      if parent_id == collection_id
        tree[collection_id]['children'] << component

        parent_document = solr_document.clone
        parent_document['children'] = []
        component['parents'] = [parent_document]
      else
        # This assumes that the document is being parsed in order
        parent_document = tree[parent_id]
        tree[parent_id]['children'] = tree[parent_id]['children'] || []
        tree[parent_id]['children'] << component

        parent_document = tree[parent_id].clone
        parent_document['children'] = []
        parent_document['parents'] = []
        component['parents'] = [parent_document]
      end
      tree[component_id] = component
    end

    tree
  end

  def perform(file_paths)
    @file_paths = file_paths
    solr_documents = EADArray.new

    logger.info("Transforming the Documents for Solr...")
    indexer.process_with(xml_documents, solr_documents)

    logger.info("Requesting a batch Solr update...")

    solr_documents.each do |solr_document|
      # Index the string-serialized tree of the documents
      tree_solr_document = solr_document.clone
      tree = build_navigation_tree(tree_solr_document)
      solr_document['navigation_tree_tesim'] = tree.to_json
    end

    blacklight_connection.add(solr_documents)
    logger.info("Successfully indexed the EADs for #{file_paths.join(', ')}")
  end
end
