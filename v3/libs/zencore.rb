module Zencore

  DEBUG = ENV["ZENLOG_DEBUG"] or 1;

  def debug(*message)
    return unless DEBUG
    print message.join(" ");
  end



end
