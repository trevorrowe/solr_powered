class SolrResponseError < Exception
end

class SolrPowered::Client

  attr_accessor :host, :port, :path, :auto_commit, :patron

  # we have to strip certain control characters from data being sent to 
  # solr for indexing, if we don't solr chokes on the reqeust
  # TODO : consider if this should be moved to ActiveRecord::Base#solr_document
  BAD_CHARS = ("\x00".."\x1F").to_a + ["\x7F"] - ["\r","\n","\t"]
  BAD_REGEX = /[#{BAD_CHARS.join('')}]/u

  def initialize options = {}

    @host = options[:host] || 'localhost'
    @port = options[:post] || 8982
    @path = options[:path] || 'solr'

    @auto_commit = options.has_key?(:auto_commit) ? options[:auto_commit] : true
    @logger = ActiveRecord::Base.logger
    @log_level = ActiveSupport::BufferedLogger::Severity::INFO

    @patron = Patron::Session.new
    @patron.timeout = options[:timeout] || 15
    
  end

  def port= port
    @port = port
    set_base_url
  end

  def host= host
    @host = host
    set_base_url
  end

  def timeout= timeout
    @patron.timeout = timeout
  end

  def set_base_url
    @patron.base_url = "http://#{@host}:#{@port}"
  end

  def select query = nil
    case query

      when Hash
        parts = []
        query.each do |key,value|
          if value.is_a?(Array)
            value.each do |v|
              parts << "#{key}=#{escape(v)}"
            end
          else
            parts << "#{key}=#{escape(value)}"
          end
        end
        query = parts.join('&')

      when String
        query = "q=#{escape(query)}"

      when nil
        query = 'q=*:*'

      else
        raise ArgumentError, "Solr#select accepts a Hash, String or nil"

    end
    request(:select, query)
  end

  def escape v
    URI.escape(URI.escape(v.to_s), '&')
  end

  def add *docs
    unless docs.empty?
      xml = "\n    <add>\n"
      docs.each do |doc|
        xml << "      <doc>\n"
        doc.each_pair do |k,v| 
          if v.is_a?(Array)
            v.each {|val| xml << "        <field name=\"#{k}\">#{::ERB::Util.h(val.to_s)}</field>\n" }
          else
            xml << "        <field name=\"#{k}\">#{::ERB::Util.h(v.to_s)}</field>\n"
          end
        end
        xml << "      </doc>\n"
      end
      xml << '    </add>'
      request(:update, xml)
      commit if @auto_commit
    end
  end

  def delete *ids
    unless ids.empty?
      ids.each do |id|
        request(:update, "<delete><id>#{id}</id></delete>")
      end
      commit if @auto_commit
    end
  end

  def delete_all query = nil
    query = "*:*" if query.nil?
    request(:update, "<delete><query>#{query}</query></delete>")
    commit if @auto_commit
  end

  # Send a commit command to the solr server.  Solr accepts 2 and only 
  # options for commits.  
  # Options
  #
  # * <tt>:waitFlush</tt> default is true — block until index changes are 
  #   flushed to disk
  # * <tt>:waitSearcher</tt> default is true — block until a new searcher
  #   is opened and registered as the main query searcher, making the changes 
  #   visible 
  #
  # You can get more information from the solr wiki:
  #
  # http://wiki.apache.org/solr/UpdateXmlMessages#head-46053fe98bb80f6d4a8138b4786aa0a0c83e28cf
  #
  # Normally you can ignore these options.
  def commit options = {}
    attributes = options.collect{|k,v| "#{k}=\"#{v}\"" }.join(' ')
    request(:update, "\n    <commit #{attributes}/>")
  end

  # Instructs the solr server to optimize its indexes.  It should be done after
  # any large number of changes to the indexes or on a daily basis.  This 
  # can take a while, so it is probably best to schedule as cron job.
  #
  # Options: 
  #
  # optimize accepts the same optional params as commit.  See Solr#commit 
  # for more information.
  def optimize options = {}
    SolrPowered.with_timeout(120) {
      attributes = options.collect{|k,v| "#{k}=\"#{v}\"" }.join(' ')
      request(:update, "\n    <optimize #{attributes}/>")
    }
  end

  def request action, msg, options = {}

    url = "/#{@path}/#{action}"

    start = Time.now

    case action
      when :update
        response  = @patron.post(url, msg.gsub(BAD_REGEX, ''), { 
          'Content-Type' => 'text/xml; charset=utf-8',
        })
      when :select
        response = @patron.get(url + '?' + msg, {
          'Content-Type' => 'application/x-www-form-urlencoded; charset=utf-8',
        })
      else
    end

    log_msg = action == :select ? URI.unescape(msg) : msg
    log(action, Time.now - start, log_msg)

    unless response.status == 200
      raise SolrResponseError, "#{response.status}: #{response.body}"
    end

    return response.body

    rescue Patron::ConnectionFailed
      url = "http://#{@host}:#{@port}#{url}"
      err = "Solr#request unreachable to reach #{url}"
      err << "\nTry running rake solr:start" 
      raise err

  end

  def log action, time, msg
    color1 = "\x1b[1m\x1b[33m"
    color2 = "\x1b[39m"
    reset = "\x1b[0m"
    log_msg = "  #{color1}Solr #{action} (#{time})  #{color2}#{msg}#{reset}"
    @logger.add(@log_level, log_msg, 'solr_powered')
  end

  # Returns true if the solr server this client want to connect to 
  # is up and running, false otherwise.
  def responds?
    begin
      @patron.head("/#{@path}/")
      true
    rescue Patron::ConnectionFailed
      false
    end
  end

end
