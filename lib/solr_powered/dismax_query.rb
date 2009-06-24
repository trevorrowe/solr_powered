class SolrPowered::DismaxQuery
  
  attr_accessor :query_type, :filter_query, :query_fields, :minimum_match,
    :phrase_fields, :phrase_slop, :query_phrase_slop, :tie_breaker,
    :boost_query, :boost_functions

  attr_accessor :sorts, :default_sort, :per_pages, :simple_facets

  # param => method
  SCORE_MODIFIERS = {
    'qt'  => 'query_type',
    'qf'  => 'query_fields',
    'mm'  => 'minimum_match',
    'pf'  => 'phrase_fields',
    'ps'  => 'phrase_slop',
    'qs'  => 'query_phrase_slop',
    'tie' => 'tie_breaker',
    'bq'  => 'boost_query',
    'bf'  => 'boost_functions',
  }

  def initialize

    # which ResponseHandler to use
    @query_type = 'dismax' 

    # A list of filters to apply to the query that should not affect scoring,
    # only matching.  Use standard lucene query syntax
    @filter_query = []

    # A list of fields and the "boosts" to associate with each of them when 
    # building disjunction-max queries from the user's query. The format 
    # supported is:
    # 
    #   'fieldOne^2.3 fieldTwo fieldThree^0.4'
    #
    # Which indicates that fieldOne has a boost of 2.3, fieldTwo has the 
    # default boost, and fieldThree has a boost of 0.4 ... 
    # this indicates that matches in fieldOne are much more significant 
    # than matches in fieldTwo, which are more significant than matches in 
    # fieldThree.
    @query_fields = nil

    @minimum_match = '100%'

    # Boost the score of matching documents where all of the terms in the "q" 
    # param appear in close proximity.
    #
    # The format is the same as QUERY_FIELDS, a list of fields and boosts to 
    # associate with each of them when making phrase queries out of the entire
    # :q param. 
    @phrase_fields = nil

    # Amount of slop on phrase queries built for "pf" fields (affects boosting).
    @phrase_slop = 20

    # Amount of slop on phrase queries explicitly included in the user's query 
    # string (in qf fields; affects matching).
    @query_phrase_slop = 100

    # Float value to use as tiebreaker in DisjunctionMaxQueries (should be 
    # something much less than 1)
    #
    # When a term from the users input is tested against multiple fields, more 
    # than one field may match and each field will generate a different score 
    # based on how common that word is in that field (for each document 
    # relative to all other documents). The "tie" param let's you configure 
    # how much the final score of the query will be influenced by the scores 
    # of the lower scoring fields compared to the highest scoring field.
    #
    # A value of "0.0" makes the query a pure "disjunction max query" -- only 
    # the maximum scoring sub query contributes to the final score. A value of 
    # "1.0" makes the query a pure "disjunction sum query" where it doesn't 
    # matter what the maximum scoring sub query is, the final score is the sum 
    # of the sub scores. Typically a low value (ie: 0.1) is useful. 
    @tie_breaker = 0.1

    # A raw query string (in the SolrQuerySyntax) that will be included with 
    # the user's query to influence the score. 
    # 
    # If this is a BooleanQuery with a default boost (1.0f) then the individual 
    # clauses will be added directly to the main query. Otherwise, the query 
    # will be included as is.  
    # 
    # !!!! That latter part is deprecated behavior but still works. 
    # It can be problematic so avoid it. 
    @boost_query = nil

    # Functions (with optional boosts) that will be included in the user's 
    # query to influence the score. Any function supported natively by Solr 
    # can be used, along with a boost value, e.g.: 
    # 
    #   recip(rord(myfield),1,2,3)^1.5
    #
    # Specifying functions with the "bf" param is just shorthand for using the 
    # _val_:"...function..." syntax in a "bq" param.
    #
    # For example, if you want score recent documents higher, use:
    # 
    #   recip(rord(created_at),1,1000,1000) 
    #
    @boost_functions = nil

    # Named sorts, 'relevancy' is the default sort.  Add as many as you like
    # here.  Its up to the interface controls to choose which of these sort
    # orders is displayed.
    @sorts = { 'relevancy' => 'score desc' }

    @default_sort = 'relevancy'

    # A list of allowable :per_page values.  This affects how many objects
    # are found / returned for each page of a search
    @per_pages = [10, 25, 50]

    @simple_facets = []

    @static_select = {}

    @crumbs = []

  end

  def [] key
    @static_select[key.to_s]
  end

  def []= key, value
    @static_select[key.to_s] = value
  end

  def find search_params, options = {}
    self.build_select(search_params)
    collection = SolrPowered.find(@select, options)
    collection.crumbs = @crumbs
    collection
  end

  protected

  def escape term
    SolrPowered.escape_lucene term
  end

  alias_method :e, :escape

  def build_select search_params

    @params = HashWithIndifferentAccess.new(search_params)

    @select = {}

    self.filter_empty_params(@params)
    self.apply_scoring_modifiers
    self.apply_search_terms
    self.apply_paging_options
    self.apply_sorting_options
    @param_filters = self.parse_param_filters
    self.apply_filters
    self.apply_simple_facets
    self.apply_select

  end

  def filter_empty_params hash
    hash.each_pair do |key,values|
      case values
        when Hash
          hash[key] = self.filter_empty_params(values)
        when Array
          values.dup.each do |value|
            values.delete(value) if value.blank?
          end
      end
      hash.delete(key) if values.blank?
    end
    hash
  end

  def apply_scoring_modifiers #:nodoc:
    SCORE_MODIFIERS.each_pair do |param,method|
      value = self.send(method)
      @select[param] = value unless value.blank?  
    end
  end

  def apply_search_terms #:nodoc:
    if q = @params['q']
      @select['q'] = q
      @crumbs << 'q'
    end
  end

  # TODO : track invalid page and per_page options
  def apply_paging_options #:nodoc:

    if page = @params['page']
      page = page.to_i
      unless page > 0
        page = 1 
        # page was invalid
      end
    else
      page = 1
    end

    if per_page = @params['per_page']
      per_page = per_page.to_i
      unless @per_pages.include?(per_page)
        per_page = @per_pages.first 
        # per_page was invalid
      end
    else
      per_page = @per_pages.first
    end

    @select['start'] = (page - 1) * per_page
    @select['rows'] = per_page

  end

  # TODO : track invalid sort option
  def apply_sorting_options #:nodoc:

    if sort = @params['sort']
      unless @sorts.has_key?(sort)
        sort = @default_sort 
        # sort was invalid
      end
    else
      sort = @default_sort
    end

    @select['sort'] = @sorts[sort]

  end

  # this method should be overridden in any searcher that requires
  # additional filters based on url params
  def parse_param_filters #:nodoc:

    filters = []
    
    @params.each_pair do |field,values|

      # skip params that are not solr index field names
      next unless SolrPowered.indexes.has_key?(field)

      # convert date strings and objects into solr formatted dates
      if SolrPowered.indexes[field][:type].to_s == 'date'
        values = Array(values).collect{|value|
          Time.parse(value.to_s).strftime('%Y-%m-%dT%TZ')
        }
      end

      Array(values).each do |value|
        value = value.to_i if field =~ /id$/
        filters << "#{field}:#{e(value)}"
        @crumbs << field
      end

    end

    filters

  end

  def apply_filters #:nodoc:
    @select['fq'] = self.filter_query + @param_filters
  end

  def apply_simple_facets
    unless @simple_facets.blank?
      @select['facet'] = true
      @select['facet.field'] = @simple_facets
      @select['facet.limit'] = -1
      @select['facet.mincount'] = 1
    end
  end

  def apply_select
    @select = @select.merge(@static_select)
  end

end
