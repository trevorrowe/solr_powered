module SolrPowered::ControllerMethods

  def self.included base #:nodoc:
    base.hide_action :solr_find
    base.hide_action :hash_to_lql
  end

  def solr_find options = {}

    if options.has_key?(:sort)
      sort = options[:sort]
    elsif params.has_key?(:sort)
      sort = params[:sort]
    else
      sort = params.has_key?(:q) ? 'score desc' : options[:default_sort]
    end

    if options.has_key?(:query)
      query = options[:query]
    elsif options.has_key?(:params)
      query = hash_to_lql(options[:params])
    else
      query = '*:*'
    end

    @facets = Array(options[:facets])

    SolrPowered.find(query,
      :find => options[:find],
      :sort => sort,
      :page => params[:page],
      :per_page => options[:per_page] || 10,
      :facets => @facets
    )

  end

  def hash_to_lql hash = {}

    default_field = SolrPowered.default_search_field.to_s

    query = []
    args = []
    
    hash.each_pair do |field,values|

      field.to_s =~ /^(.+?)(-(.+))?$/
      field = $1
      suffix = $3

      unless 
        SolrPowered.indexes.has_key?(field) or
        ['solr_id', 'solr_type', default_field].include?(field)  
      then
        next # not a solr searchable param
      end

      Array(values).each do |value|

        # convert dates into solr date strings
        if 
          SolrPowered.indexes[field] and
          SolrPowered.indexes[field][:type].to_s == 'date'
        then
          unless [DateTime, Time, Date].any?{|klass| value.is_a?(klass) }
            value = Time.parse(value)
          end
          value = value.strftime('%Y-%m-%dT%TZ')
        end
        
        # TODO : how to handle quoting issues?
        case suffix

          when nil
            if field == default_field
              query << '?'
              args << value
            else
              query << "#{field}:?"
              args << value
            end

          when 'min'
            query << "#{field}:[? TO *]"
            args << value

          when 'max'
            query << "#{field}:[* TO ?]"
            args << value

          when 'range'
            query << "#{field}:[? TO ?]"
            min,max = value.split(',')
            args << min
            args << max

          when 'begins-with'
              query << "#{field}:?*"
              args << value

          when 'in'
            lql = '(' + values.collect{|v| "#{field}:?" }.join (' OR ') + ')'
            query << lql
            args += values

          else
            raise "unknown suffix type `#{suffix}` for hash_to_lql"

        end
      end
    end

    query = query.join(" #{SolrPowered.default_operator} ")
    SolrPowered.lql([query.blank? ? '*:*' : query, *args])

  end

end
