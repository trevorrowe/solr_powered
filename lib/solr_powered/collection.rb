class SolrPowered::Collection < Array

  # will_paginate compat. methods
  attr_reader :current_page, :per_page, :total_entries, :total_pages

  # solr specific methods
  attr_accessor :response, :facets, :crumbs

  def initialize documents, current_page, per_page, total_entries
    self.replace(documents)
    @current_page = current_page
    @per_page = per_page
    self.total_entries = total_entries
  end

  def out_of_bounds?
    current_page > total_pages
  end

  def offset
    (current_page - 1) * per_page
  end

  def previous_page
    current_page > 1 ? (current_page - 1) : nil
  end

  def next_page
    current_page < total_pages ? (current_page + 1) : nil
  end

  def total_entries=(number)
    @total_entries = number.to_i
    @total_pages = (@total_entries / per_page.to_f).ceil
  end

  def inspect
    "#<#{self.class} current_page:#{current_page} per_page:#{per_page} total_entries:#{total_entries} total_pages:#{total_pages}>"
  end

end
