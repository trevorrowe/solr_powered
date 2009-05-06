TODO:

  logging ...

    * move the request log to the SolrPowered.log_dir

    * find out if stdout is ever used by solr
      (stderr.log is populated stdout.log is not)

  other

    * configurable default_search_field on a per class level

    * make the static configuration methods flexible enough to be
      reset back to nil (use the *args approach to grabbing params)

    * add more faceting methods (radio button group, checkbox list, 
      drop down select, etc)

    * lots more documentation

    * write tests

REFACTOR

  * rename indexes to fields in the configuraiton macros, to be consistant
    with the solr nomenclature

BUGS

  * solr_powered quits working after a script/console reload!

