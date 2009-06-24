namespace :solr do

  desc <<-DESC
  Attempts to preload all of this applications models that might be
  solr_powered.  If this method fails to load all of your models, you
  will have to provide solr_powered with the additional model paths.

  By default it will load all .rb files inside your app/models 
  directory.  If you would like to replace the default path, or 
  add additional paths you will need to see SolrPowered.model_paths
  for more information.
  DESC
  task :preload_models => ['environment'] do
    SolrPowered.preload_models 
  end

  desc <<-DESC
  Outputs a solr schema file.  This schema file is customized for
  this application, and is based on the combination of all of your
  solr powered classes.

  It is generated based of a sample template, which you can copy
  to RAILS_ROOT/config/solr_powered/schema.xml.erb (you can find
  the primary schema template in vendor/plugins/solr_powered/config.

  Be cautious when making modifications to the schema.
  DESC
  task :schema => ['solr:preload_models'] do
    puts schema_xml
  end

  namespace :schema do 
    desc <<-DESC
    The solr_powered plugin includes a bundled version of apache solr
    and all of the files required to run a solr server (java 1.5 + 
    is required).  

    One requirement of starting a solr server is to start it with
    a schema file that describes your indexes.  solr_powered auto
    generates this schema file based on your class level configurations
    and writes this schema file to disk for the apache solr server to
    read.  

    You will not normally need to call solr:schema:write directly
    as it will run prior to any solr:start or solr:restart task.
    DESC
    task :write => ['solr:preload_models'] do
      schema_path = "#{SolrPowered.solr_path}/solr/conf/schema.xml"
      schema_file = File.open(schema_path, 'w') do |schema|
        schema.write schema_xml
      end
    end
  end

  desc <<-DESC
  Creates the empty log and da
  DESC
  task :create_dirs do
    unless File.exists?(SolrPowered.log_dir)
      FileUtils.mkdir_p(SolrPowered.log_dir)
    end
    unless File.exists?(SolrPowered.data_dir)
      FileUtils.mkdir_p(SolrPowered.data_dir)
    end
  end

  desc <<-DESC
  Starts a solr server for your application.  A schema file is written to
  disk and the server is started in the background (java 1.5+ is requried).  
  DESC
  task :start => ['solr:schema:write', 'solr:create_dirs'] do

    # make sure the server isn't already running
    if solr_responds?
      $stderr.print "solr:start failure - port #{SolrPowered.port} already "
      $stderr.print "in use, perhaps solr is already running\n"
      next
      exit(1)
    end

    # issue the start command
    Dir.chdir(SolrPowered.solr_path) do
      start = "nohup java -Dsolr.data.dir=#{SolrPowered.data_dir}"
      start << " -DSTOP.PORT=#{SolrPowered.stop_port}"
      start << " -DSTOP.KEY=solr_powered_#{SolrPowered.port}"
      start << " -Djetty.port=#{SolrPowered.port}"
      start << " -Djetty.logs=#{SolrPowered.log_dir}"
      start << " -jar start.jar"
      start << " > #{SolrPowered.log_dir}/stdout.log"
      start << " 2> #{SolrPowered.log_dir}/stderr.log &"
      `#{start}`
    end

    started = false
    timeout = 30
    interval = 0.25
    time = 0

    begin
      if solr_responds?
        started = true 
        break 
      else
        time += interval
        sleep(interval)
      end
    end while time < timeout

    if started
      puts 'solr:start success'
    else
      $stderr.print "solr:start failure - server not responding "
      $stderr.print "after #{timeout} seconds\n"
      exit(1)
    end
  end
  
  desc <<-DESC
  Stops the solr server that was started for this environment.
  If the solr server takes longer than 30 seconds to stop, this task
  timeouts, logs a message to stderr and then exits with a non-zero value
  DESC
  task :stop => ['environment'] do

    unless solr_responds?
      $stderr.print "solr:stop failure - solr doesn't seem to be running\n"
      next # stop this task, nothing to do
    end

    # issue the stop command
    Dir.chdir(SolrPowered.solr_path) do
      stop = "java -DSTOP.PORT=#{SolrPowered.stop_port} "
      stop << "-DSTOP.KEY=solr_powered_#{SolrPowered.port} "
      stop << '-jar start.jar --stop'
      `#{stop}`
    end

    # check periodically, finish the task only when the server
    # is actually stopped, or when we timeout waiting
    stopped = false 
    timeout = 30
    interval = 0.25
    time = 0

    begin
      if solr_responds?
        time += interval # still responding, again later
        sleep(interval)
      else
        stopped = true # the server stopped, lets get out of here
        break
      end
    end while time < timeout

    if stopped
      puts 'solr:stop success'
    else
      # this is bad ...
      $stderr.print 'solr:stop failure - server still responding '
      $stderr.print "after #{timeout} seconds.\n"
      $stderr.flush
      exit(1)
    end
  end

  desc <<-DESC
  Stops, rewrites the solr configuration and then starts the solr server.
  DESC
  task :restart => ['stop', 'start']

  desc <<-DESC
  Drops all records from the solr server and then reindexes all records.
  This happens 1 class at a time.  After all records are indexes, it is
  recomended that you run the solr:optimize task.
  DESC
  task :reindex => ['environment'] do
    # TODO : this needs to be updated so it only does base classes in STI
    # setups OR the final classes
    SolrPowered.indexed_models.each do |klass| 
      puts klass.to_s
      klass.solr_reindex
    end
  end

  desc "Requests an optimize against the solr server"
  task :optimize => ['environment'] do
    SolrPowered.client.optimize
  end

  desc <<-DESC
  Stops solr, removes all index files from disk and rebuilds the index
  DESC
  task :rebuild => ['environment'] do
    if solr_responds?
      Rake::Task['solr:stop'].invoke
      solr_was_running = true
    end
    Rake::Task['solr:clean'].invoke
    Rake::Task['solr:start'].invoke
    Rake::Task['solr:reindex'].invoke
    Rake::Task['solr:optimize'].invoke if solr_was_running
  end
  
  desc <<-DESC
  Removes the solr index from disk
  DESC
  task :clean => ['environment'] do
    if solr_responds?
      $stderr.print "solr:clean failure - can't remove index files while solr "
      $stderr.print "is running, try running solr:stop first\n"
      $stderr.flush
      exit(1)
    end
    FileUtils.rm_rf(SolrPowered.data_dir)
  end

end

def solr_responds?
  SolrPowered.client.responds?
end

def field_string attr
    %Q{    <field name="#{attr[:name]}" type="#{attr[:type]}" multi_valued="#{attr[:multi_valued]}" required="#{attr[:required]}" indexed="#{attr[:indexed]}" stored="#{attr[:stored]}"/>}
end

def copy_field_string src, dest
  %Q{  <copyField source="#{src}" dest="#{dest}"/>}
end

def schema_xml
  # locate the schema template, check the application config
  # first, and if not found, we will use ours
  template_path = "#{RAILS_ROOT}/config/solr_powered/schema.xml.erb"
  unless File.exists?(template_path)
    template_path = SolrPowered::PLUGIN_PATH + "/config/schema.xml.erb"
  end

  fields = {}
  copy_fields = {}

  SolrPowered.indexes.each_value do |field|
    fields[field[:name]] = field_string(field)
    if field[:copy_to]
      copy_fields[:field[:name]] == copy_field_string(field[:name], field[:copy_to])
    end
  end

  fields = fields.keys.sort.collect{|name| fields[name] }
  copy_fields = copy_fields.keys.sort.collect{|name| copy_fields[name] }

  ERB.new(File.read(template_path)).result(binding())

end
