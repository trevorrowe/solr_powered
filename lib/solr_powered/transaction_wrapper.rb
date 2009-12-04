module SolrPowered::TransactionWrapper
  def transaction *args
    super(*args) do 
      ::SolrPowered.batch(:transaction => true) do
        yield
      end
    end
  end
end
