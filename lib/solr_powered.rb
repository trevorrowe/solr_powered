
# TODO : rfuzz/http_client does a lousey job of letting us know when the
# TODO   response is anything but a 200.  Fix curl on monaco or fix rfuzz

# TODO : cleanup the massize SolrPowered module.  Maybe break it up into a few
# TODO   more specific modules/classes, maybe get rid of client configuraiton

# TODO : improve escaping, right now it escapes 100% of solr special characters
# TODO   which makes it difficult to allow the user to enter more powerful
# TODO   search terms like "foo*"

# TODO : more documentation

# TODO : write tests

# TODO : release!

module SolrPowered

  ## constants

  PLUGIN_PATH = File.join(File.dirname(__FILE__), '..')

  APACHE_SOLR_PATH = File.join(PLUGIN_PATH, 'apache_solr')

  mattr_accessor :log_dir, :data_dir, :auto_index, :stop_port,
    :default_operator, :default_search_field, :default_search_field_type

  mattr_reader :host, :port, :path, :auto_commit, 
    :model_paths, :observers, :indexes

  ## client connection variables

  @@client = nil

  @@host = '127.0.0.1'

  @@port = 8982

  @@path = 'solr'

  @@auto_commit = true

  @@auto_index = true

  @@stop_port = 8981

  @@batching = false

  ## pathing variables for models and logs

  @@model_paths = ["#{Rails.root}/app/models"]

  @@log_dir = "#{Rails.root}/log/solr"

  @@data_dir = "#{Rails.root}/solr/#{Rails.env}"

  ## solr schema values

  @@default_operator = 'AND'

  @@default_search_field = 'q'

  @@default_search_field_type = 'text'

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

  ##
  ## building lql queries
  ##

  def self.lql query
    case query

      when String
        query

      when Array
        parts = query.dup
        lql = parts.shift
        args = parts.collect{|part| 
          if part.nil? or part.to_s == ''
            '*:*'
          elsif part.is_a?(Array)
            '(' + part.collect{|term| self.escape_lucene(term) }.join(' OR ') + ')'
          else
            self.escape_lucene(part.to_s)
          end
        }
        lql.gsub(/\?/, '%s') % args

      when Hash
        lql = []
        args = []
        query.each_pair do |field,value|
          lql << "#{field}:?"
          args << value
        end
        self.lql([lql.join(' AND '), *args])

      else
        raise "Don\'t know how to build lql from #{query.class}"
    end
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

  # TODO : write an escape method that allows search modifiers pass through
  # TODO   like *, -, !, (, ), etc

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

  def self.find query, options = {}

    ##
    ## RESPONSE FORMAT
    ##

    case options[:format].to_s
      when 'active_record', ''
        format = 'active_record'
        fl = 'solr_id,score'
      when 'document'
        format = 'document'
        fl = '*,score'
      when 'hash'
        format = 'hash'
        fl = '*,score'
      when 'ids'
        format = 'ids'
        fl = 'solr_id'
      else
        raise ArgumentError, "Invalid :format option `#{options[:format]}`"
    end

    select = {}

    ##
    ## FACETING
    ##
    
    if options[:facets]

      select[:facet] = true
      select['facet.field'] = options[:facets]
      select['facet.limit'] = -1
      select['facet.missing'] = false
      #select['facet.mincount'] = 2 # not working as understood
      select['facet.zeros'] = false

      facets = options[:facets]
      options[:facets] = []
    end

    ##
    ## PAGING
    ##

    # page number
    page = options[:page]
    page = 1 if page.blank?
    page = page.to_i
    unless page > 0
      raise ArgumentError, ':page option must be blank or an integer > 0'
    end

    # per page
    per_page = options[:per_page]
    per_page = 10 if per_page.blank?
    per_page = per_page.to_i
    unless per_page.to_i > 0
      raise ArgumentError, ':per_page option must be blank or an integer > 0'
    end

    # query offset
    offset = ((page - 1) * per_page)

    ##
    ## SEARCH THE SOLR INDEX
    ##

    select.merge!({
      :q => self.lql(query),
      :start => offset,
      :rows => per_page,
      :sort => options[:sort],
      :wt => 'ruby',
      :fl => fl,
    })

    response = eval(client.select(select))

    ##
    ## PARSE RESPONSE
    ##

    docs = response['response']['docs']
    total = response['response']['numFound']

    case format

      when 'ids'
        # TODO : this collects a bunch of "solr_ids", which are
        # TODO   encoded with the class-name prefix
        # TODO : we should probably only allow selecting ids from
        # TODO   the class level, not this level (it gets mixed)
        docs = docs.collect{|doc| doc['solr_id'].first } 

      when 'active_record' # default format
        
        sorted_ids = []
        ids_by_klass = {}
        objs = []

        # group the ids by class so we can perform exactly 1 activerecord
        # find per klass, instead of 1 find per id
        docs.each do |doc|
          solr_id = doc['solr_id'].first
          klass_name = solr_id.split(/-/).first
          sorted_ids << solr_id
          ids_by_klass[klass_name] ||= []
          ids_by_klass[klass_name] << solr_id
        end

        # perform 1 find per class, then sort the collected results
        find_opts = options[:find] || {}
        ids_by_klass.each_pair do |klass_name,solr_ids|
          klass = klass_name.constantize
          ids = solr_ids.collect{|id| id.split(/-/).last }
          # find modifieds the hash of find options passed in, so we have to dup
          objs += klass.find(ids, find_opts.dup)
          # TODO : rescue ActiveRecord::RecordNotFound and give a better excep
        end

        #raise docs.to_yaml + sorted_ids.to_yaml + ids_by_klass.to_yaml

        # this can fail if the index returns an id not found by the above
        # active record .find call - it fails <=> on nil because index returns
        # nil in the block below
        docs = objs.sort_by{|obj| sorted_ids.index(obj.solr_id) }

      when 'document'
        docs = docs.collect{|doc| SolrPowered::Document.new(doc) }

      when 'hash'
        # no processing required, the user requested solrs native
        # response format w/out processing

    end

    collection = SolrPowered::Collection.new(docs, page, per_page, total)
    collection.response = response

    if options[:facets]
      collection.facets = response['facet_counts']
    end

    collection

  end

  def self.find_ids query, options = {}
    self.find(query, options.merge(:format => 'ids'))
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
      :copy_to_default => false,
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
