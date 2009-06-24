ActiveRecord::Base.send(:extend, SolrPowered::ClassMethods)
ActiveRecord::Base.send(:include, SolrPowered::InstanceMethods)

# This plugin attempts to preload all models.  It does this so we can:
#
# * know what models are solr_powered?
# * know what models are observed via solr_assoc
#
# With this knowledge we can auto-magically keep indexed associations
# current when the observed fields are modified.
SolrPowered.preload_models
