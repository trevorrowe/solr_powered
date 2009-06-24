module SolrPowered::ClassMethods

  # adding functionality to all classes that extend active record base
  def self.extended base #:nodoc:

    # A hash of solr field names and method names (field => method).
    # It is used for building a solr document.  The method is usually
    # a string/symbol, but can be an array when the method is an association.
    # 
    # If method is an array the first value is the association, the 2nd
    # value is the method to call on the object/objects returned by the
    # association.
    base.class_inheritable_accessor :solr_document_fields

    # TODO : rename this accessor to reflect these are attributes
    # this class watches on itself (but does not include attributes
    # other classes watch on it)
    base.class_inheritable_accessor :solr_watched_attributes

    # An array of association names this class uses for indexing
    # itself... this array is kept primarily for introspection and
    # for rebuilding an index.  These associations are eager loaded
    base.class_inheritable_accessor :solr_eager_loaded_associations

    # A boolean, does this class (in general) index itself?
    base.class_inheritable_accessor :solr_powered

    # A symbol (method name) or a proc.  The method / proc is evaluated
    # before save operations to determine if the record should be
    # inserted into the index or not.  
    base.class_inheritable_accessor :solr_save_if_condition

    # A symbol (method name) or a proc.  The method / proc is evaluated
    # before save operations to determine if the record should be
    # inserted into the index or not.  
    base.class_inheritable_accessor :solr_save_unless_condition

    base.solr_document_fields = {}
    base.solr_watched_attributes = []
    base.solr_eager_loaded_associations = []
    base.solr_powered = false
    base.solr_save_if_condition = nil
    base.solr_save_unless_condition = nil

    base.after_create :auto_solr_create, 
      :if => lambda{|obj| SolrPowered.auto_index }

    base.after_update :auto_solr_update, 
      :if => lambda{|obj| SolrPowered.auto_index }

    base.after_destroy :auto_solr_destroy, 
      :if => lambda{|obj| SolrPowered.auto_index }

  end

  # Returns true if this class has configured any solr powered indexes
  # (via solr_attr, solr_method or solr_assoc)
  def solr_powered?
    self.solr_powered
  end

  # A class level configuration method, call this to set under what 
  # condition a record should be indexed.  It accepts a single param
  # (the name of a method to call) or a block (executed after save).
  #
  # If a method name is passed in, that method must return false
  # after save or obj will no be reflected in the solr index.
  # It is okay to provide solr_save_unless along with this.
  #
  # A few examples:
  #
  #   class Foo < ActiveRecord::Base
  #     solr_attr :name
  #     solr_save_if :has_name?
  #   end
  #
  #   class Bar < ActiveRecord::Base
  #     solr_attr :name
  #     solr_save_if {|bar| bar.age.to_i > 21 }
  #   end
  #
  def solr_save_if method = nil, &block
    if block_given?
      self.solr_save_if_condition = block
    else
      self.solr_save_if_condition = method
    end
  end

  # A class level configuration method, call this to set under what 
  # condition a record should not be indexed.  It accepts a single param
  # (the name of a method to call) or a block (executed after save).
  #
  # If a method name is passed in, that method must return false
  # after save or obj will still end up in the index.  It is okay to 
  # provide both a solr_save_if along with this.
  #
  # A few examples:
  #
  #   class Foo < ActiveRecord::Base
  #     solr_attr :name
  #     solr_save_unless :deactivated?
  #   end
  #
  #   class Bar < ActiveRecoo::Base
  #     solr_attr :name
  #     solr_save_unless {|bar| bar.age.to_i < 21 }
  #   end
  #
  def solr_save_unless method = nil, &block
    if block_given?
      self.solr_save_unless_condition = block
    else
      self.solr_save_unless_condition = method
    end
  end

  # A class' solr_type is its class name as a string.  The solr_type is
  # used primarly when indexing and retrieving documents.
  def solr_type
    @solr_type ||= self.to_s
  end

  # Drops all records from the solr index for this class and then 
  # systematically rebuilds the index in batches of 1000 records at a time.  
  #
  # This method performs active record finds to fetch db records that need
  # to be indexed.  To speed up indexing, it will perform a :include (eager
  # load) for every indexed association
  def solr_reindex options = {}

    if options[:delete_first] != false
      # remove ALL of this class' records from the solr index
      SolrPowered.client.delete_all("solr_type:#{solr_type}")
    end

    # ActiveRecord handles STI find in a very odd way.  Given the following
    # STI setup:
    #
    #   Staff < Member < Person < ActiveRecord::Base
    #
    # If you perform a find on Member or Staff the find will be scoped with
    # the type column being the class name which is being searched.  However,
    # if you perform the same find on Person, instead of scoping where type
    # would = 'Person', it leaves the type column out, returning all objects
    # 
    # This is not desireable as we have different associations, different
    # solr_attrs, solr_methods and solr_assocs in each of the inherited 
    # classes, we need to eager load different columns, create different
    # documents, etc.
    # 
    # Therefor we ALWAYS add the class name (when type is present) to the
    # find.  This does result in a douple tpye condition in some STI
    # queries, but that is preferable to the alternative of not scoping.
    if self.column_names.include?('type')
      cond = ["#{self.table_name}.type = ?", self.to_s]
    end

    # re-index the records, one large chunk at a time
    page = 0
    batch_size = options[:batch_size] || 1000
    begin
      objects = find(:all,
        :conditions => cond,
        :include => self.solr_eager_loaded_associations,
        :limit => batch_size, 
        :offset => page * batch_size
      )
      documents = objects.select(&:solr_saveable?).collect(&:solr_document)
      SolrPowered.client.add(*documents) unless documents.empty?
      page += 1
    end until objects.length != batch_size
  end

  def solr_attr *attribute_names

    options = attribute_names.last.is_a?(Hash) ? attribute_names.pop : {}

    if options.has_key?(:multi_valued)
      raise ArgumentError, ':multi_valued is assumed false for model attributes.'
    end
    
    if attribute_names.empty?
      raise ArgumentError, 'At least 1 attribute name is required.'
    end

    if attribute_names.length > 1 and options.has_key?(:as)
      msg = ":as option only allowed with single attribute names."
      raise ArgumentError, msg
    end

    index_opts = index_options(options).merge(:multi_valued => false)
    attribute_names.each do |attribute_name|
      as = options[:as] || attribute_name
      SolrPowered.add_index(as, index_opts.dup)
      self.add_solr_document_method(as, attribute_name)
    end

    self.solr_powered = true
    self.add_solr_observed_attributes(*attribute_names)
  end

  # Creates a field in the solr index and configures this model to store the
  # return value of *solr_method* in that field.
  #
  # Options:
  #
  # * :as - The name of the solr index field, defaults to method_name
  # * :attributes - Attributes on this model that trigger a solr reindex
  #   when they are dirty on save.
  # * :associations - Association hash (:name, :attributes, :return_association)
  #   to watch.  When the observed association :name model saves with dirty 
  #   :attributes it will retrigger a reindex of the :return_association.
  #   :associations can be a single hash, or an array of hashes, but all must
  #   provide :name, :attributes and :return_association.
  # * TODO : document the other standard solr field options
  #
  def solr_method method_name, options = {}

    if options[:attributes]
      self.add_solr_observed_attributes(*Array(options[:attributes]))
    end

    Array(options[:associations]).each do |assoc|
      if association = self.reflect_on_association(assoc[:name])
        self.add_solr_observer_to_association(
          association, 
          assoc[:attributes],
          assoc[:return_association]
        )
        # TODO : consider adding the association to eager loads
      else
        raise "The association #{assoc[:name]} is not defined (yet?)."
      end
    end

    as = options[:as] || method_name

    self.solr_powered = true
    self.add_solr_document_method(as, method_name)
    SolrPowered.add_index(as, index_options(options))
  end

  # Options:
  #
  # * :as - (defaults to the parameter assoc_name)
  # * :association_attributes - (defaults to [remote_method])
  # * :attributes - (defaults to [])
  # * :return_association - guess (plural or singular of class name)
  #
  def solr_assoc assoc_name, remote_method, options = {}

    ## VALIDATE ARGS AND SETUP DEFAULTS

    as = options[:as] || assoc_name.to_s

    unless association = self.reflect_on_association(assoc_name)
      raise "Unable to solr index #{assoc_name}, it has not been defined."
    end

    supported = [:has_many, :has_one, :belongs_to, :has_and_belongs_to_many]
    unless supported.include?(association.macro)
      raise "SolrPowered does not support #{association.macro} associations."
    end

    unless options.has_key?(:multi_valued)
      case association.macro
        when :belongs_to, :has_one
          options[:muti_valued] = false
        when :has_many, :has_and_belongs_to_many
          options[:muti_valued] = true
      end
    end

    ## ADD ASSOCIATION CALLBACKS (as needed)

    # :dependent => :delete_all + association#clear
    #
    # :depenedent => :delete_all associations normally execute direct sql
    # deletes against the database when .clear is called against them.
    # If this association is watched, then we need to add a callback on the
    # association so we can reindex when .clear is called.
    if association.options[:dependent] == :delete_all
      add_association_callback(association, :after_remove, proc{|o1,o2|
        if SolrPowered.auto_index
          SolrPowered.add(o1.solr_document) 
          SolrPowered.delete(o2) if o2.class.solr_powered?
        end
        true
      })
    end

    # has_and_belongs_to_many associations
    #
    # We  have to add callbacks for after_add and after_remove as there is
    # no direct class to observe to watch for changes.
    if association.macro == :has_and_belongs_to_many
      add_association_callback(association, :after_add, proc{|o1,o2|
        o1.solr_save if SolrPowered.auto_index
        true
      })
      add_association_callback(association, :after_remove, proc{|o1,o2|
        o1.solr_save if SolrPowered.auto_index
        true
      })
    end

    ## ADD INDEX COLUMN (field) TO SOLR

    SolrPowered.add_index(as, index_options(options))

    ## ADD METHOD(s) TO THE LIST OF METHODS REQUIRED TO BUILD A SOLR DOCUMENT

    self.add_solr_document_method(as, [association.name, remote_method])

    ## SETUP ASSOCIATION OBSERVER

    observed_attributes = options[:association_attributes] || [remote_method]

    if options.has_key?(:return_association)
      return_association = options[:return_association]
    else
      return_association = case association.macro
        when :has_one, :has_many
          self.to_s.downcase.to_sym
        when :belongs_to, :has_and_belongs_to_many
          # this default could be incorrect if the belongs to maps to 
          # a has_one reverse association instead of a has_many
          self.to_s.underscore.pluralize.to_sym
        else
          raise "oops, shouldn't get here"
      end
    end

    self.add_solr_observer_to_association(
      association, 
      observed_attributes, 
      return_association
    )

    # TODO : why is this here? should solr_assoc ever accpet local attributes?!?
    # allows solr_assoc to accept :attributes option (local attributes
    # to force reindexing by
    if attributes = options[:attributes]
      self.add_solr_observed_attributes(*Array(attributes))
    end

    ## ADD THIS ASSOCIATION TO EAGERLOADING (for faster reindexing)

    self.add_solr_eager_loaded_association(association.name)
    self.solr_powered = true
  end

  protected

  # Returns a hash of options suitable for SolrPowered.add_index
  def index_options options
    defaults = {
      :type => 'string',
      :indexed => true,
      :stored => false,
      :multi_valued => false,
      :required => false,
      :copy_to => nil,
    }
    index_options = {}
    defaults.each_pair do |opt_name,default|
      if options.has_key?(opt_name)
        index_options[opt_name] = options[opt_name]
      else
        index_options[opt_name] = default  
      end
    end
    index_options[:type] = index_options[:type].to_s
    index_options
  end

  # Tracks the mapping of solr index field => model method names.
  # When a model is indexed into solr a "document" is build, these
  # methods tell solr how to build this document.
  #
  # If method is a 2-element array, each part will be called in turn,
  # this allows indexing methods on associated objects like:
  #
  #   [:account_manager, :name]
  #
  # Would be the same as calling
  #
  #   model.account_manager.name
  #
  def add_solr_document_method field, method
    
    field = field.to_s
    if self.solr_document_fields.has_key?(field)
      msg = "The solr index field '#{field}' is already configured for this class."
      raise ArgumentError, msg
    end

    if method.is_a?(Array)
      method = method.collect(&:to_s)
    else
      method = method.to_s
    end

    self.solr_document_fields[field] = method

  end

  # After save, if any of the added attributes are dirty, this model
  # will get solr_saved to the index again.
  def add_solr_observed_attributes *attribute_names
    self.solr_watched_attributes += attribute_names.collect(&:to_s)
    self.solr_watched_attributes.uniq!
  end

  def add_solr_observer_to_association association, attributes, return_association

    # polymorphic associations are broken (can't be fixed)
    if association.options[:polymorphic] or association.options[:as]
      raise "SolrPowered can't observe changes to polymorphic associations."
    end

    # has_many :through associations are broken (can be fixed)
    if association.options[:through]
      raise "SolrPowered can't observe changes to :through associations (yet)."
    end

    SolrPowered.add_observer(
      :observing_class_name => self.to_s,
      :association          => association.name, 
      :observed_class_name  => association.class_name,
      :observed_attributes  => Array(attributes),
      :return_association   => return_association
    )

  end

  # Any associations added here will be eager loaded when reindexing all
  # records of the same class.
  def add_solr_eager_loaded_association association_name
    name = association_name.to_s
    unless self.solr_eager_loaded_associations.include?(name)
      self.solr_eager_loaded_associations << name
    end
  end

  # association - an relfected association
  # hook        - :before_add, :after_add, :before_remove, :after_remove
  # callback    - a proc to eval at the hook time, gets 2 params,
  #               o1, o2, the parent object and the associated object
  def add_association_callback association, hook, callback

    if association.options[hook]
      old_callbacks = Array(association.options[hook])
      association.options[hook] = [callback] + old_callbacks
    else
      association.options[hook] = [callback]
    end

    association.active_record.send(
      :add_association_callbacks,
      association.name,
      association.options
    )

  end

end
