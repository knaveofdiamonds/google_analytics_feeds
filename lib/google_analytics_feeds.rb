require 'ox'
require 'addressable/uri'
require 'stringio'
require 'faraday'

# @api public
module GoogleAnalyticsFeeds
  # Raised if login fails.
  #
  # @api public
  class AuthenticationError < StandardError ; end
  
  # Raised if there is an HTTP-level problem retrieving reports.
  #
  # @api public
  class HttpError < StandardError ; end

  # A Google Analytics session, used to retrieve reports.
  # @api public
  class Session
    # @api private
    CLIENT_LOGIN_URI = "https://www.google.com/accounts/ClientLogin"

    # Creates a new session.
    #
    # Optionally pass a Faraday connection, otherwise uses the default
    # Faraday connection.
    def initialize(connection=Faraday.default_connection)
      @connection = connection
    end

    # Log in to Google Analytics with username and password
    #
    # This should be done before attempting to fetch any reports.
    def login(username, password)
      return @token if @token
      response = @connection.post(CLIENT_LOGIN_URI,
                                  'Email'       => username,
                                  'Passwd'      => password,
                                  'accountType' => 'HOSTED_OR_GOOGLE',
                                  'service'     => 'analytics',
                                  'source'      => 'ruby-google-analytics-feeds')

      if response.success?
        @token = response.body.match(/^Auth=(.*)$/)[1]
      else
        raise AuthenticationError
      end
    end

    # Retrieve a report from Google Analytics.
    #
    # Rows are yielded to a RowHandler, provided either as a class,
    # instance or a block.
    def fetch_report(report, handler=nil, &block)
      handler  = block if handler.nil?
      response = report.retrieve(@token, @connection)

      if response.success?
        DataFeedParser.new(handler).parse_rows(StringIO.new(response.body))
      else
        raise HttpError.new
      end
    end
  end

  # A SAX-style row handler.
  #
  # Extend this class and override the methods you care about to
  # handle data feed row data.
  #
  # @abstract
  # @api public
  class RowHandler
    # Called before any row is parsed.
    #
    # By default, does nothing.
    def start_rows
    end

    # Called when each row is parsed.
    #
    # By default, does nothing.
    #
    # @param row Hash
    def row(row)
    end

    # Called after all rows have been parsed.
    #
    # By default, does nothing.
    def end_rows
    end
  end
  
  # @api private
  module Naming
    # Returns a ruby-friendly symbol from a google analytics name.
    #
    # For example:
    #
    #     name_to_symbol("ga:visitorType") # => :visitor_type
    def name_to_symbol(name)
      name.sub(/^ga\:/,'').gsub(/(.)([A-Z])/,'\1_\2').downcase.to_sym
    end
    
    # Returns a google analytics name from a ruby symbol.
    #
    # For example:
    #
    #     symbol_to_name(:visitor_type) # => "ga:visitorType"
    def symbol_to_name(sym)
      parts = sym.to_s.split("_").map(&:capitalize)
      parts[0].downcase!
      "ga:" + parts.join('')
    end
  end

  # Parses rows from the GA feed via SAX. Clients shouldn't have to
  # use this - use a RowHandler instead.
  #
  # @api private
  class RowParser < ::Ox::Sax
    include Naming

    def initialize(handler)
      @handler = handler
    end

    def start_element(element)
      case element

      when :entry
        @row = {}
      when :"dxp:dimension", :"dxp:metric"
        @property = {}
      end
    end

    def attr(name, value)
      if @property
        @property[name] = value
      end
    end

    def end_element(element)
      case element
      when :entry
        handle_complete_row
        @row = nil
      when :"dxp:dimension", :"dxp:metric"
        handle_complete_property
        @property = nil
      end
    end
    
    private

    def handle_complete_row
      @handler.row(@row)
    end

    def handle_complete_property
      if @row
        value = @property[:value]
        if @property[:type] == "integer"
          value = Integer(value)
        end
        name = name_to_symbol(@property[:name])
        @row[name] = value
      end
    end
  end

  # Construct filters for a DataFeed.
  # 
  # @api private
  class FilterBuilder
    include Naming

    def initialize
      @filters = []
    end

    def build(&block)
      instance_eval(&block)
      @filters.join(';')
    end

    # TODO: remove duplication

    def eql(name, value)
      filter(name, value, '==')
    end

    def not_eql(name, value)
      filter(name, value, '!=')
    end

    def contains(n, v)
      filter(n, v, '=@')
    end

    def not_contains(n, v)
      filter(n, v, '!@')
    end

    def gt(n, v)
      filter(n, v, '>')
    end

    def gte(n, v)
      filter(n, v, '>=')
    end

    def lt(n, v)
      filter(n, v, '<')
    end

    def lte(n, v)
      filter(n, v, '<=')
    end
        
    def match(n, v)
      filter(n, v, '=~')
    end

    def not_match(n, v)
      filter(n, v, '!~')
    end

    private

    def filter(name, value, operation)
      @filters << [symbol_to_name(name), operation, value.to_s].join('')
    end
  end

  # @api public
  class DataFeed
    include Naming
    
    BASE_URI = "https://www.googleapis.com/analytics/v2.4/data"

    def initialize
      @params = {}
    end

    # Sets the profile id from which this report should be based.
    #
    # @return [GoogleAnalyticsFeeds::DataFeed] a cloned DataFeed.
    def profile(id)
      clone_and_set {|params|
        params['ids'] = symbol_to_name(id)
      }
    end

    # Sets the metrics for a query.
    #
    # A query must have at least 1 metric for GA to consider it
    # valid. GA also imposes a maximum (as of writing 10 metrics) per
    # query.
    #
    # @param names [*Symbol] the ruby-style names of the dimensions.
    # @return [GoogleAnalyticsFeeds::DataFeed] a cloned DataFeed.
    def metrics(*vals)
      clone_and_set {|params|
        params['metrics'] = vals.map {|v| symbol_to_name(v) }.join(',')
      }
    end

    # Sets the dimensions for a query.
    #
    # A query doesn't have to have any dimensions; Google Analytics
    # limits you to 7 dimensions per-query at time of writing.
    #
    # @param names [*Symbol] the ruby-style names of the dimensions.
    # @return [GoogleAnalyticsFeeds::DataFeed] a cloned DataFeed.
    def dimensions(*names)
      clone_and_set {|params|
        params['dimensions'] = names.map {|v| symbol_to_name(v) }.join(',')
      }
    end

    # Sets the start and end date for retrieved results
    # @return [GoogleAnalyticsFeeds::DataFeed] a cloned DataFeed.
    def dates(start_date, end_date)
      clone_and_set {|params|
        params['start-date'] = start_date.strftime("%Y-%m-%d")
        params['end-date'] = end_date.strftime("%Y-%m-%d")
      }
    end

    # Sets the start index for retrieved results
    # @return [GoogleAnalyticsFeeds::DataFeed]
    def start_index(i)
      clone_and_set {|params|
        params['start-index'] = i.to_s
      }
    end

    # Sets the maximum number of results retrieved.
    #
    # Google Analytics has its own maximum as well.
    # @return [GoogleAnalyticsFeeds::DataFeed]
    def max_results(i)
      clone_and_set {|params|
        params['max-results'] = i.to_s
      }
    end

    # Filter the result set, based on the results of a block.
    #
    # All the block methods follow the form operator(name,
    # value). Supported operators include: eql, not_eql, lt, lte, gt,
    # gte, contains, not_contains, match and not_match - hopefully all
    # self-explainatory.
    #
    # Example:
    #
    #    query.
    #      filter {
    #        eql(:dimension, "value")
    #        gte(:metric, 3)
    #      }
    # 
    # @return [GoogleAnalyticsFeeds::DataFeed]
    def filters(&block)
      clone_and_set {|params|
        params['filters'] = FilterBuilder.new.build(&block)
      }
    end

    # Use a dynamic advanced segment.
    #
    # Block methods follow the same style as for filters. Named
    # advanced segments are not yet supported.
    # 
    # @return [GoogleAnalyticsFeeds::DataFeed]
    def segment(&block)
      clone_and_set {|params|
        params['segment'] = "dynamic::" + FilterBuilder.new.build(&block)
      }
    end

    # Sorts the result set by a column.
    #
    # Direction can be :asc or :desc.
    def sort(column, direction)
      clone_and_set {|params|
        c = symbol_to_name(column)
        params['sort'] = (direction == :desc ? "-#{c}" : c)
      }
    end

    # Returns the URI string needed to retrieve this report.
    def uri
      uri = Addressable::URI.parse(BASE_URI)
      uri.query_values = @params
      uri.to_s.gsub("%40", "@")
    end

    alias :to_s :uri

    # @api private
    def retrieve(session_token, connection)
      connection.get(uri) do |request|
        request.headers['Authorization'] = 
          "GoogleLogin auth=#{session_token}"
      end
    end

    # @api private
    def clone
      obj = super
      obj.instance_variable_set(:@params, @params.clone)
      obj
    end

    protected

    attr_reader :params

    private

    def clone_and_set
      obj = clone
      yield obj.params
      obj
    end
  end

  # @api private
  class DataFeedParser
    def initialize(handler)
      if handler.kind_of?(Proc)
        @handler = Class.new(RowHandler, &handler).new
      elsif handler.kind_of?(Class)
        @handler = handler.new
      else
        @handler = handler
      end
    end

    # Parse rows from an IO object.
    def parse_rows(io)
      @handler.start_rows
      Ox.sax_parse(RowParser.new(@handler), io)
      @handler.end_rows
    end
  end
end
