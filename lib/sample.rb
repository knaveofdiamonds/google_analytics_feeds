require File.dirname(__FILE__) + "/google_analytics_feeds" 

class LoggingRowHandler < GoogleAnalyticsFeeds::RowHandler
  def row(r)
    puts r.inspect
  end

  def end_rows
    puts "Done!"
  end
end

File.open("/home/roland/gaout2.xml") do |fh|
  GoogleAnalyticsFeeds.parse_data_rows(fh, LoggingRowHandler)
end
