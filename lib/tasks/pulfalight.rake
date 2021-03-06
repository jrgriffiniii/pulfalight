# frozen_string_literal: true

require Rails.root.join("app", "jobs", "application_job")
require Rails.root.join("app", "jobs", "index_job")
require Rails.root.join("app", "services", "robots_generator_service")

namespace :pulfalight do
  namespace :index do
    desc "Delete all Solr documents in the index"
    task :delete do
      delete_by_query("<delete><query>*:*</query></delete>")
    end

    desc "Index a single EAD file into Solr"
    task :file, [:file] => :environment do |_t, args|
      index_file(relative_path: args[:file], root_path: Rails.root)
    end

    desc "Index a directory of PULFA EAD files into Solr"
    task :directory, [:directory] => :environment do |_t, args|
      index_directory(name: args[:directory])
    end

    namespace :configs do
      desc "Updates solr config files from github"
      task :update, :solr_dir do |_t, args|
        solr_dir = args[:solr_dir] || Rails.root.join("solr")

        ["_rest_managed.json", "admin-extra.html", "elevate.xml",
         "mapping-ISOLatin1Accent.txt", "protwords.txt", "schema.xml",
         "scripts.conf", "solrconfig.xml", "spellings.txt", "stopwords.txt",
         "stopwords_en.txt", "synonyms.txt"].each do |file|
          response = Faraday.get url_for_file(file)
          File.open(File.join(solr_dir, "conf", file), "wb") { |f| f.write(response.body) }
        end
      end
    end

    desc "Index Princeton University Library Finding Aids (PULFA) into Solr"
    task :pulfa do
      Dir.glob("eads/**/*.xml").each do |file|
        index_file(relative_path: file, root_path: Rails.root)
      end
    end
  end

  desc "Run Solr and Arclight for interactive development"
  task :development do
    SolrWrapper.wrap(managed: true, verbose: true, port: 8983, instance_dir: "tmp/pulfalight-core-dev", persist: false, download_dir: "tmp") do |solr|
      solr.with_collection(name: "pulfalight-core-dev", dir: solr_conf_dir, persist: true) do
        puts "Setup solr"
        puts "Solr running at http://localhost:8983/solr/pulfalight-core-dev/, ^C to exit"
        begin
          sleep
        rescue Interrupt
          puts "\nShutting down..."
        end
      end
    end
  end

  desc "Run Solr and Arclight for testing"
  task :test do |_t, _args|
    SolrWrapper.wrap(managed: true, verbose: true, port: 8984, instance_dir: "tmp/pulfalight-core-test", persist: false, download_dir: "tmp") do |solr|
      solr.with_collection(name: "pulfalight-core-test", dir: solr_conf_dir) do
        puts "Setup solr"
        puts "Solr running at http://localhost:8984/solr/pulfalight-core-test/, ^C to exit"
        begin
          sleep
        rescue Interrupt
          puts "\nShutting down..."
        end
      end
    end
  end

  desc "Seed fixture data to Solr"
  task :seed do
    puts "Seeding index with data from spec/fixtures/ead..."

    Dir.glob("spec/fixtures/ead/**/*.xml").each do |file|
      index_file(relative_path: file, root_path: Rails.root)
    end
  end

  desc "Generate a robots.txt file"
  task :robots_txt do |_t, args|
    file_path = args[:file_path] || Rails.root.join("public", "robots.txt")
    robots = RobotsGeneratorService.new(path: file_path, disallowed_paths: Rails.configuration.robots.disallowed_paths)
    robots.insert_group(user_agent: "*")
    robots.insert_crawl_delay(10)
    robots.insert_sitemap(Rails.configuration.robots.sitemap_url)
    robots.generate
    robots.write
  end

  # Utility methods

  # Construct a new Logger for STDOUT
  # @return [Logger]
  def logger
    @logger ||= Logger.new(STDOUT)
  end

  # Retrieve the connection to the Solr index for Blacklight
  # @return [RSolr]
  def blacklight_connection
    repository = Blacklight.default_index
    repository.connection
  end

  # Retrieve the URL for the Blacklight Solr core
  # @return [String]
  def blacklight_url
    blacklight_connection.base_uri
  rescue StandardError
    ENV["SOLR_URL"] || "http://127.0.0.1:8983/solr/blacklight-core"
  end

  # Delete a set of Solr Documents using a query
  # @param [String] query
  # @return [Boolean]
  def delete_by_query(query)
    blacklight_connection.update(data: query, headers: { "Content-Type" => "text/xml" })
    blacklight_connection.commit
  end

  # Query Solr for a single Document by the ID
  # @param [String] id
  # @return [Hash]
  def query_by_id(id:)
    response = blacklight_connection.get("select", params: { q: "id:\"#{id}\"", fl: "*", rows: 1 })
    docs = response["response"]["docs"]
    docs.first
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

  # Search Solr for a Document corresponding to an EAD Document
  # @param [File] file
  # @return [Hash]
  def search_for_file(file)
    xml_doc = Nokogiri::XML(file)
    xml_doc.remove_namespaces!
    solr_document = indexer.map_record(xml_doc)
    query_by_id(id: solr_document["id"])
  end

  # Determines whether or not an EAD-XML Document has already been indexed in
  #   Solr
  # @param [String] file_path
  # @return [Boolean]
  def indexed?(file_path:)
    file = File.new(file_path)

    doc = search_for_file(file)
    doc.present?
  end

  # Generate the path for the EAD directory
  # @return [Pathname]
  def pulfa_root
    @pulfa_root ||= Rails.root.join("eads", "pulfa")
  end

  # Resolves the repository based upon the file path of a PULFA EAD file
  # @return [String]
  def resolve_repository_id(file_path)
    parent_path = File.expand_path("..", file_path)
    File.basename(parent_path)
  end

  # Index an EAD-XML Document into Solr
  # @param [String] relative_path
  def index_file(relative_path:, root_path: nil)
    root_path ||= pulfa_root
    ead_file_path = if File.exist?(relative_path)
                      relative_path
                    else
                      File.join(root_path, relative_path)
                    end
    repository_id = resolve_repository_id(ead_file_path)

    IndexJob.perform_later(file_paths: [ead_file_path], repository_id: repository_id)
  end

  # Index a directory of PULFA EAD-XML Document into Solr
  # Note: This assumes that the documents have been checked out into eads/pulfa
  # @param [String] relative_path
  def index_directory(name:, root_path: nil)
    root_path ||= pulfa_root
    dir = root_path.join(name)
    glob_pattern = File.join(dir, "**", "*.xml")
    file_paths = Dir.glob(glob_pattern)

    file_paths.each do |file_path|
      index_file(relative_path: file_path, root_path: root_path)
    end
  end

  def solr_conf_dir
    Rails.root.join("solr", "conf").to_s
  end

  def url_for_file(file)
    "https://raw.githubusercontent.com/pulibrary/pul_solr/master/solr_configs/pulfalight-staging/conf/#{file}"
  end
end
