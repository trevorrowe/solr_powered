class SolrPowered::Document

  def initialize solr_document
    @hash = solr_document
  end

  def id
    self[:solr_id].split('-').last.to_i
  end

  # CAUTION : to param only works if the solr documents has all of the 
  # required data to construct the to_param method on an instance.  Its
  # flakey at best even then.  
  # 
  # In its current state, I would rerecomend not using SolrPowered::Documents
  # if you have an advanced to_param method.
  def to_param
    dummy = self.klass.new
    dummy[:id] = self.id
    @hash.keys.each do |field| 
      dummy[field] = self[field] if dummy.respond_to?(field)
    end
    dummy.to_param
  end

  def klass_name
    self[:solr_id].split('-').first
  end

  def klass
    klass_name.constantize
  end

  def score
    @hash['score']
  end

  def [] method

    method = method.to_s.gsub(/\?$/, '') # strip ? from boolean methods

    # short cut for solr_id, which is always present, and is used by other
    # internal methods (for things like getting at the id or class)
    return @hash['solr_id'].first if method == 'solr_id'
    
    # these method are defined already, but we can allow the user to access 
    # them via the doc[:method] notation for consistancy's sake
    return send(method) if [:id, :klass_name, :klass, :score].include?(method)

    # TODO : rewrite this method from here down to check against only the
    #        fields indexed for the class represented here -- e.g. if 
    #        this document is of type "Recipe" only fields stored by
    #        recipe can be retrieved via this function.

    unless field = SolrPowered.indexes[method]
      raise ArgumentError, "Undefined solr field: #{method}"
    end

    # TODO : test this code -- untested as of yet
    unless field[:stored] == true
      err = "Attempting to access solr field #{method} which is not stored."
      raise ArgumentError, err
    end

    # The document, as returned by solr stores ALL values as arrays.  We don't
    # want to return the value as an array unless the field was configured to
    # store multiple values.  We can determine which type to return by 
    # introspecting the SolrPowered.fields configuration hash.
    #
    # There is also a chance the document did not save that field (it was 
    # not set in the model after validation during the last save operation).
    # In such case the field will return null.
    #
    # NOTE: this method raises an exception if you attempt to access a field
    # that has NOT been configured as a valid solr_field.  It can also return
    # null if the document does not have a value for the field.
    #
    # TODO : move this to function level documentation and clean it up

    unless @hash.has_key?(method.to_s)
      if SolrPowered.indexes[method][:multi_valued]
        return []
      else
        return nil
      end
    end

    value = field[:multi_valued] ? @hash[method.to_s] : @hash[method.to_s].first

    # convert date strings from the YYYY-mm-ddTHH:MM:SSZ string format
    # to native time objects
    if value =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
      Time.parse(value)
    else
      value
    end

  end

  def method_missing method, *args
    self[method]
  end

end
