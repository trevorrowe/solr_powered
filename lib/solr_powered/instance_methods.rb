module SolrPowered::InstanceMethods

  def self.included base
    base.send(:attr_accessor, :solr_score)
  end

  # Returns a string containing this instance's class name and primary key
  # deliminated by a dash, e.g.
  #
  #   Listing-123
  #
  def solr_id
    "#{self.class}-#{self.send(self.class.primary_key)}"
  end

  # A pass-along-method, it in turn calls solr_type on its class, which 
  # returns the name of this instances class.  This is primarily used
  # for setting the solr_type attribute when calling solr_search on a
  # class.
  def solr_type
    self.class.solr_type
  end

  # Returns true if the objects class is solr_powered
  def solr_powered?
    self.class.solr_powered?
  end

  # Updates this record in the solr index
  def solr_save options = {}
    if self.solr_powered?
      if self.solr_saveable?
        SolrPowered.add(self.solr_document)
      else
        SolrPowered.delete(self.solr_id)
      end
    else
      raise "Called solr_save on an object whos class (#{self.class}) " +
        "is not solr_powered."
    end
  end

  # Returns true if an object should be inserted into the solr index.  This
  # is the case if all the following conditions are met:
  #
  # * the object's class is solr_powered
  # * the object meets the class'es solr_save_if condition (if any)
  # * the object does not meet the class'es solr_save_unless condition (if any)
  #
  def solr_saveable?
    return false unless self.solr_powered?
    if if_cond = self.solr_save_if_condition
      case if_cond
        when Symbol
         return false unless self.send(if_cond)
        when Proc
          return false unless if_cond.call(self)
      end
    end
    if unless_cond = self.solr_save_unless_condition
      case unless_cond
        when Symbol
          return false if self.send(unless_cond)
        when Proc
          return false if unless_cond.call(self)
      end
    end
    true
  end

  # Returns a hash representation of this object suitable for passing
  # through to a call to Solr#add -- it contains the key value pairs of
  # all the fields out of the solr index this object's class responds
  # to.
  def solr_document

    document = {
      'solr_id' => self.solr_id,
      'solr_type' => self.solr_type,
    }

    self.class.solr_document_fields.each_pair do |field,method|

      if method.is_a?(Array) # association
        assoc_objs = self.send(method.first)
        unless assoc_objs.is_a?(Array)
          assoc_objs = assoc_objs.nil? ? [] : [assoc_objs]
        end
        values = assoc_objs.collect{|obj| obj.send(method.last) }
      else
        value = self.send(method) # attribute or method
        values = value.is_a?(Array) ? value : [value]
      end

      # We want to drop out empty/blank values and convert dates to 
      # formats solr accepts.
      #
      # We can't just use .blank? because false (which is a valid index value)
      # is "blank" - e.g. flase.blank? == true ... we dont want to skip false
      # values.
      document[field] = []
      values.each do |value|
        if [nil, '', []].include?(value)
          next
        elsif [DateTime, Date, Time].any?{|klass| value.is_a?(klass) }
          document[field] << value.strftime('%Y-%m-%dT%TZ')
        else
          document[field] << value
        end
      end

    end
    document
  end

  protected

  # Called after a record is created, it forces solr saves for the object
  # and all records observing this object
  def auto_solr_create

    documents = []

    if self.class.solr_powered? and self.solr_saveable?
      documents << self.solr_document
    end

    SolrPowered.observers_for(self.class).each do |observer|
      assoc_objs = self.send(observer[:return_association])
      assoc_objs = [assoc_objs] unless assoc_objs.is_a?(Array)
      assoc_objs.each do |obj|
        documents << obj.solr_document if obj.solr_saveable?
      end
    end

    SolrPowered.add(*documents)
  end

  # called after an update, only re-indexes when observed attributes
  # are dirty (same goes for associations that observe this object)
  def auto_solr_update

    documents = []
    remove_self = false

    dirty_attrs = self.changes.keys.collect(&:to_s) 

    if self.class.solr_powered?
      if self.solr_saveable?
        if dirty_attrs & self.class.solr_watched_attributes != []
          documents << self.solr_document  
        end
      else
        # this is down here, not protected by the dirty attribute check
        # because the attributes that affect when a solr update is required
        # may have nothing to do with when the document is saveable or not
        #
        # for now, to be safe, we always remove when the document is not
        # saveable -- it might be possible to have a "saveable atttr"
        # or method (that is represented by attributes) and use that as
        # the litmus for when to actually remove (only when the saveable
        # attributes have been modified) -- for now this just works
        remove_self = true
      end
    end

    # Other models may be indexing this model via solr_association, so
    # even though this may not be a solr_powered and solr_saveable object
    # other objects might be interested in our changes:
    SolrPowered.observers_for(self.class).each do |observer|
      if observer[:observed_attributes].any?{|attr| dirty_attrs.include?(attr) }
        assoc_objs = self.send(observer[:return_association])
        assoc_objs = [assoc_objs] unless assoc_objs.is_a?(Array)
        assoc_objs.each do |obj|
          documents << obj.solr_document if obj.solr_saveable?
        end
      end
    end

    SolrPowered.add(*documents)
    SolrPowered.delete(self.solr_id) if remove_self

    true
  end

  # This method is called after destroy, it has three purposes:
  #
  # 1. re-index any records that index this obj via solr_association
  # 2. remove this records solr document from the index
  # 3. commit the changes
  #
  def auto_solr_destroy #:nodoc:

    # 1. re-index anyone that uses this object as part of their index
    observers = []
    SolrPowered.observers_for(self.class).each do |observer|
      assoc_objs = self.send(observer[:return_association])
      assoc_objs = [assoc_objs] unless assoc_objs.is_a?(Array)
      assoc_objs.each do |obj|
        observers << obj.solr_document if obj.solr_saveable?
      end
    end

    SolrPowered.add(*observers) 

    # 2. remove self from the index
    if self.class.solr_powered?
      SolrPowered.delete(self.solr_id)
    end

    true
  end

end
