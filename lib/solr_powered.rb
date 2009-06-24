module SolrPowered

  # installation path of this plugin
  PLUGIN_PATH = File.join(File.dirname(__FILE__), '..')

  mattr_accessor :solr_path, :log_dir, :auto_index, :stop_port

  mattr_reader :host, :port, :path, :auto_commit, 
    :model_paths, :observers, :indexes

  # installation path for apache solr
  @@solr_path = File.join(Rails.root, 'solr')

  # where the solr server keeps it logs
  @@log_dir = File.join(Rails.root, 'log', 'solr', Rails.env)

  # directories to scan for solr_powered models
  @@model_paths = ["#{Rails.root}/app/models"]

  ## client connection variables

  @@client = nil

  @@host = '127.0.0.1'

  @@port = 8982

  @@path = 'solr'

  @@auto_commit = true

  @@auto_index = true

  @@stop_port = 8981

  @@batching = false

  ## solr meta data on indexes and observers

  # A hash of "indexes" or solr fields.  This hash is used to build the 
  # solr/schema.xml file.
  @@indexes = {}

  # A hash of classes to index/field names that class indexes.
  # of all field the model uses and what methods it uses to get that
  # data
  @@model_indexes = {}

  # Due to single table inheritance, the hash of observers is not as simple
  # as it might appear.  It is a hash of classes to the observers.  However
  # You have to look up observers by the primary class and then all of the
  # ancestors.
  #
  #   SolrPowered.observers_for(klass).
  #
  # The above code will do just that.
  @@observers = Hash.new {|hash,key| hash[key] = [] }

  # This array hold class names instead of actual classes.  The getter
  # returns actual class objects instead of those names.  This behaviour is
  # required because of bizzare rails behaviour with class loading in 
  # development requirements.  If you hold a reference to a class object
  # it can cause issues.
  @@indexed_models = []

  # SolrPowered.find is a thin wrapper around a call to select from a solr server.
  # All select params are passed through unmodified to SolrPowered.client#select
  # except the following:
  # 
  # * fl - field list, solr_id and score are selected.
  # * wr - writer type, set to ruby
  #
  # The following are added as defaults if not set:
  #
  # * rows - the number of documents to return (limit), 10
  # * start - the document offset, 0 
  #
  # Instead of returning a raw ruby hash as formated by the solr sever,
  # SolrPowered.find fetches active record objects.  Any options passed
  # are passed to the ActiveRecord::Base.find calls made to fetch these objets.
  # This is useful for setting things like :include.
  #
  # TODO : finish documenting this method
  def self.find select_params, options = {}

    ## perform the search and get the ruby hash back

    select = HashWithIndifferentAccess.new(select_params)
    select['fl'] = 'solr_id,score'
    select['wt'] = 'ruby'
    select['rows'] ||= 10
    select['start'] ||= 0

    response = eval(SolrPowered.client.select(select))

    ## parse the ruby response hash

    scores = {}
    sorted_solr_ids = []
    ids_by_class = {}

    response['response']['docs'].each do |doc|

      solr_id = doc['solr_id'].first

      # save its score so we can add it to its ActiveRecord obj after its found
      # note: scores do not always indicate sort order
      scores[solr_id] = doc['score']
      
      # keep the solr_ids sorted so we can order the active record objects
      # we find by them
      sorted_solr_ids << solr_id

      # group docs by class so we can find them in groups instead of 1 at a time
      class_name = solr_id.split(/-/).first
      ids_by_class[class_name] ||= []
      ids_by_class[class_name] << solr_id.split(/-/).last.to_i

    end

    ## find the active record objects in groups (1 find per class)

    objs = []

    ids_by_class.each_pair do |class_name,ids|
      klass = class_name.constantize
      objs += klass.find(ids, options.dup)
      # TODO : handle ActiveRecord::RecordNotFound exceptions
    end

    ## populate object scores and sort them

    objs = objs.sort_by{|obj| 
      solr_id = obj.solr_id
      obj.solr_score = scores[solr_id]
      sorted_solr_ids.index(solr_id)
    }

    ## populate the will_paginate compat. collection

    per_page = select['rows'].to_i
    page = select['start'] / per_page + 1
    total = response['response']['numFound']

    collection = SolrPowered::Collection.new(objs, page, per_page, total)
    collection.response = response
    collection

  end

  # Called by the solr_powered plugin's init.rb file.  This method will
  # attempt to locate all models for the application.  SolrPowered.model_paths
  # is an array of paths where all **/*.rb files are loaded from.  Each
  # path is turned into a class name that is then constantized.  This allows
  # Rails to perform its own class loading.
  #
  # Why is this required?  That is a longer discussion, but it has to 
  # to with how solr_powered tracks changes across associations.  In a 
  # nutshell:
  #
  # * ClassA has has foo attribute
  # * ClassB solr indexes ClassA#foo through solr_assoc 
  # * ClassB must have been loaded (preloaded) before ClassA makes any
  #   changes to foo.
  #
  # If ClassB has not been preloaded then how are we to know if anybody
  # cares about changes to ClassA#foo?
  def self.preload_models #:nodoc:
    self.model_paths.each{|path| preload_models_from_path(path) }
  end

  # Add a path, besides the default path, where models are located.
  # The default path "RAILS_ROOT/app/models/**/*.rb" is loaded at plugin init.
  # If you need to add additional paths, use this method.
  # TODO : auto load models from RAILS_ROOT/vendor/plugins/**/models/**/*.rb
  # TODO   to support rails 2.3 engines behaviours.
  def self.add_model_path path
    preload_models_from_path(path)
    @@model_paths << path
  end

  # Guesses obvious class names from their path on disk and then 
  # constantizes the class to force Rails into loading it.  This 
  # allows the class the opportunity to setup solr indexing.
  def self.preload_models_from_path path #:nodoc:
    #puts "SolrPowerd: loading models from #{path}"
    Dir.glob("#{path.gsub(/\/$/, '')}/**/*.rb").each{|rb_file| 
      klass = File.basename(rb_file).gsub(/\.rb$/, '').camelize.constantize
      #puts " -- #{klass}"
      if klass.respond_to?('solr_powered') and klass.solr_powered?
        add_indexed_model(klass)
      end
    }
  end

  def self.data_dir
    File.join(self.solr_path, 'solr', 'data', Rails.env)
  end

  # Singleton http connection to the solr server, see SolrPowered::Client
  # for more information.
  def self.client
    if @@client.nil?
      @@client = SolrPowered::Client.new(
        :host => host,
        :port => port,
        :path => path,
        :auto_commit => auto_commit
      )
    end
    @@client
  end

  # The hostname of the solr server, defaults to 127.0.0.1
  def self.host= host
    client.host = host
    @@host = host
  end

  # The port number the solr server runs on, defaults to 8982
  def self.port= port
    client.port = port
    @@port = port
  end

  # The path within the host where the solr request handlers reside.
  # defaults to '/solr'.
  def self.path= path
    client.path = path
    @@path = path
  end

  # Lucene supports escaping special characters that are part of the query 
  # syntax. The current list special characters are:
  #
  #   + - ! ( ) { } [ ] ^ " ~ * ? : \ && ||
  # 
  # To escape these character we use the \ before the character. For example:
  #
  #   (1+1):2
  #
  # should become:
  #
  #   \(1\+1\)\:2
  #
  def self.escape_lucene term
    term.to_s.gsub(/([+\-!(){}[\]\^"~*?:\\]|&&|\|\|)/, '\\\\\\1')
  end

  ##
  ## tracking which classes are solr indexed
  ##

  def self.add_indexed_model klass #:nodoc:
    @@indexed_models = (@@indexed_models + [klass.to_s]).uniq
  end

  def self.indexed_models
    @@indexed_models.collect(&:constantize)
  end

  ##
  ## when auto indexing / commiting happens
  ##

  def self.disable_auto_index &block
    orig_state = self.auto_index
    self.auto_index = false
    begin
      yield
    ensure
      self.auto_index = orig_state
    end
  end

  def self.auto_commit= state
    client.auto_commit = state
    @@auto_commit = state
  end

  def self.disable_auto_commit &block
    orig_state = self.auto_commit
    self.auto_commit = false
    begin
      yield
    ensure
      self.auto_commit = orig_state
    end
  end

  def self.transaction &block
    @@add = {}
    @@remove = {}
    @@batching = true
    begin
      yield 
      client.add(*@@add.values)
      client.delete(*@@remove.keys)
    ensure
      @@add = {}
      @@remove = {}
      @@batching = false
    end
  end

  def self.add *solr_document_hashes
    if @@batching
      solr_document_hashes.each do |document|
        solr_id = document['solr_id']
        @@add[solr_id] = document
        @@remove.delete(solr_id)
      end
    else
      client.add(*solr_document_hashes)
    end
  end

  def self.delete *solr_id_strings
    if @@batching
      solr_id_strings.each do |solr_id|
        @@remove[solr_id] = true
        @@add.delete(solr_id)
      end
    else
      client.delete(*solr_id_strings)
    end
  end

  ##
  ## field methods
  ##

  def self.add_index name, options = {}
    
    # TODO : raise an exception anything besides the allowed options
    # TODO   are passed in, or if anything less than the same

    name = name.to_s

    options = {
      :name => name,
      :type => 'string',
      :indexed => true,
      :stored => false,
      :multi_valued => false,
      :required => false,
      :copy_to => nil,
    }.merge(options)

    #options[:type] = options[:type].to_s

    # make sure that if any other class has defined the same solr
    # index, that is has the same options.  If the options differ,
    # we will raise an exception.
    if @@indexes.has_key?(name)
      unless @@indexes[name] == options
        # TODO : deal with changing configurations
        err = "Invalid solr_index configuration.\n\nThe solr index '#{name}' "
        err << "has already been configured with different options.\n\n"
        err << "If you modified an existing index, try restarting."
        err << @@indexes[name].to_yaml
        err << options.to_yaml
        raise err
      end
    end

    @@indexes[name] = options

  end

  ##
  ## solr_assoc methods
  ##

  def self.observers_for klass
    observers = []
    current_klass = klass
    begin
      if @@observers.has_key?(current_klass.to_s)
        observers += @@observers[current_klass.to_s]
      end
      current_klass = current_klass.superclass
    end until current_klass == ActiveRecord::Base
    observers
  end

  def self.add_observer options
    @@observers[options[:observed_class_name]] << options
  end
  
end
