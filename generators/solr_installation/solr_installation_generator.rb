class SolrInstallationGenerator < Rails::Generator::Base

  def manifest
    record do |m|

      dest_prefix = 'solr'
      m.directory dest_prefix

      # TODO : get rid of the example/non-necessary files from this manifest
      [
        'README.txt',
        'etc',
        'etc/jetty.xml',
        'etc/webdefault.xml',
        'lib',
        'lib/jetty-6.1.3.jar',
        'lib/jetty-util-6.1.3.jar',
        'lib/jsp-2.1',
        'lib/jsp-2.1/ant-1.6.5.jar',
        'lib/jsp-2.1/core-3.1.1.jar',
        'lib/jsp-2.1/jsp-2.1.jar',
        'lib/jsp-2.1/jsp-api-2.1.jar',
        'lib/servlet-api-2.5-6.1.3.jar',
        'logs',
        'solr',
        'solr/README.txt',
        'solr/bin',
        'solr/bin/abc',
        'solr/bin/abo',
        'solr/bin/backup',
        'solr/bin/backupcleaner',
        'solr/bin/commit',
        'solr/bin/optimize',
        'solr/bin/readercycle',
        'solr/bin/rsyncd-disable',
        'solr/bin/rsyncd-enable',
        'solr/bin/rsyncd-start',
        'solr/bin/rsyncd-stop',
        'solr/bin/scripts-util',
        'solr/bin/snapcleaner',
        'solr/bin/snapinstaller',
        'solr/bin/snappuller',
        'solr/bin/snappuller-disable',
        'solr/bin/snappuller-enable',
        'solr/bin/snapshooter',
        'solr/conf',
        'solr/conf/admin-extra.html',
        'solr/conf/elevate.xml',
        'solr/conf/protwords.txt',
        'solr/conf/schema.xml',
        'solr/conf/scripts.conf',
        'solr/conf/solrconfig.xml',
        'solr/conf/spellings.txt',
        'solr/conf/stopwords.txt',
        'solr/conf/synonyms.txt',
        'solr/conf/xslt',
        'solr/conf/xslt/example.xsl',
        'solr/conf/xslt/example_atom.xsl',
        'solr/conf/xslt/example_rss.xsl',
        'solr/conf/xslt/luke.xsl',
        'solr/data',
        'solr/lib',
        'start.jar',
        'webapps',
        'webapps/solr.war',
        'work',
      ].each do |path|

        src = path
        dest = File.join(dest_prefix, path)

        if File.basename(path) =~ /\./ and path != 'lib/jsp-2.1'
          m.file src, dest
        else
          m.directory dest
        end

      end

    end
  end

end
