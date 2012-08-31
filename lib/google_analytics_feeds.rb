require 'ox'
require 'addressable/uri'
require 'stringio'
require 'faraday'

module GoogleAnalyticsFeeds
  class AuthenticationError < StandardError ; end
  class HttpError < StandardError ; end

  class Session
    CLIENT_LOGIN_URI = "https://www.google.com/accounts/ClientLogin"

    def initialize(connection=Faraday.default_connection)
      @connection = connection
    end

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
  class RowHandler
    def start_rows
    end

    def row(row)
    end

    def end_rows
    end
  end
  
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

  class DataFeed
    include Naming
    
    BASE_URI = "https://www.googleapis.com/analytics/v2.4/data"

    def initialize
      @params = {}
    end

    def profile(id)
      clone_and_set {|params|
        params['ids'] = symbol_to_name(id)
      }
    end

    def metrics(*vals)
      clone_and_set {|params|
        params['metrics'] = vals.map {|v| symbol_to_name(v) }.join(',')
      }
    end

    def dimensions(*vals)
      clone_and_set {|params|
        params['dimensions'] = vals.map {|v| symbol_to_name(v) }.join(',')
      }
    end

    def dates(start_date, end_date)
      clone_and_set {|params|
        params['start-date'] = start_date.strftime("%Y-%m-%d")
        params['end-date'] = end_date.strftime("%Y-%m-%d")
      }
    end

    def start_index(i)
      clone_and_set {|params|
        params['start-index'] = i.to_s
      }
    end

    def max_results(i)
      clone_and_set {|params|
        params['max-results'] = i.to_s
      }
    end

    def filters(&block)
      builder = 
      clone_and_set {|params|
        params['filters'] = FilterBuilder.new.build(&block)
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

    def uri
      uri = Addressable::URI.parse(BASE_URI)
      uri.query_values = @params
      uri.to_s.gsub("%40", "~")
    end

    alias :to_s :uri

    def retrieve(session_token, connection)
      connection.get(uri) do |request|
        request.headers['Authorization'] = 
          "GoogleLogin auth=#{session_token}"
      end
    end

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
